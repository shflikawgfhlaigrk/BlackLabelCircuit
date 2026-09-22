from __future__ import annotations

import base64
import hashlib
import json
import os
import shlex
import shutil
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from typing import override
except ImportError:  # Python 3.9-3.11
    def override(function):
        return function

from harbor.agents.installed.codex import Codex
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trial.paths import EnvironmentPaths
from harbor.utils.trajectory_utils import format_trajectory_json

from . import __version__
from .benchmark_pipeline import (
    java_home_compat_command,
    merge_atif_trajectories,
    pipeline_prompts,
    structured_result_command,
    swe_verifier_preflight_command,
)


class BlackLabelOperatorAgent(Codex):
    """Harbor adapter that runs the Black Label Operator execution path."""

    SUPPORTS_ATIF = True
    SUPPORTS_RESUME = False
    SUPPORTS_LOAD_NATIVE_TRAJECTORY = False
    SUPPORTS_LOAD_ATIF_TRAJECTORY = False

    _SOURCE_ROOT = Path(__file__).resolve().parents[1]
    _REMOTE_SOURCE = PurePosixPath("/opt/blacklabel-operator")
    _REMOTE_OPERATOR_HOME = PurePosixPath("/tmp/blacklabel-operator")
    _REMOTE_OPERATOR_PORT = 18846
    _OUTPUT_FILENAME = "operator-result.json"
    _CODEX_ARCHIVES = {
        "arm64": {
            "machines": {"aarch64", "arm64"},
            "sha256": "c9f0a6415f58ddef8908d36c38881d273bac417d57b5c7768dd9fbfeb92b6a2d",
            "triple": "aarch64-unknown-linux-musl",
        },
        "x64": {
            "machines": {"amd64", "x86_64"},
            "sha256": "b3bcf2c11693d7c8155de637dd6562ba19d916ba13471a7c8737de55e5328fc6",
            "triple": "x86_64-unknown-linux-musl",
        },
    }

    def __init__(
        self,
        *args: Any,
        codex_version: str | None = None,
        operator_version: str = __version__,
        review_passes: int = 2,
        workspace_consensus: bool | str = False,
        benchmark_suite: str | None = None,
        benchmark_adaptive: bool | str = True,
        benchmark_adaptive_rounds: int = 3,
        **kwargs: Any,
    ) -> None:
        self._operator_version = operator_version
        self._review_passes = int(review_passes)
        self._benchmark_suite = str(benchmark_suite or "")
        self._workspace_consensus = (
            workspace_consensus
            if isinstance(workspace_consensus, bool)
            else str(workspace_consensus).strip().lower() in {"1", "true", "yes", "on"}
        )
        self._benchmark_adaptive = (
            benchmark_adaptive
            if isinstance(benchmark_adaptive, bool)
            else str(benchmark_adaptive).strip().lower() in {"1", "true", "yes", "on"}
        )
        self._benchmark_adaptive_rounds = int(benchmark_adaptive_rounds)
        if not 1 <= self._benchmark_adaptive_rounds <= 3:
            raise ValueError("benchmark_adaptive_rounds must be between 1 and 3")
        pipeline_prompts(
            "validation", self._review_passes, benchmark_suite=self._benchmark_suite
        )
        super().__init__(*args, version=codex_version, **kwargs)

    @staticmethod
    @override
    def name() -> str:
        return "black-label-operator"

    @override
    def version(self) -> str | None:
        return self._operator_version

    @override
    def get_version_command(self) -> str | None:
        return (
            f"PYTHONPATH={self._REMOTE_SOURCE.as_posix()} "
            "python3 -c 'import blacklabel_operator; print(blacklabel_operator.__version__)'"
        )

    @staticmethod
    def _sha256(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def _codex_archive(self, machine: str) -> tuple[Path, str] | None:
        for archive_arch, metadata in self._CODEX_ARCHIVES.items():
            if machine not in metadata["machines"]:
                continue
            archive_dir = Path(
                os.environ.get(
                    "OPERATOR_CODEX_ARCHIVE_DIR",
                    str(
                        Path.home()
                        / ".blacklabel-operator/cache/codex"
                        / str(self._version or "latest")
                    ),
                )
            ).expanduser()
            archive = archive_dir / (
                "codex-%s-linux-%s.tgz" % (self._version, archive_arch)
            )
            if not archive.is_file():
                return None
            if self._sha256(archive) != metadata["sha256"]:
                self.logger.warning("Ignoring Codex archive with invalid SHA-256: %s", archive)
                return None
            return archive, str(metadata["triple"])
        return None

    async def _install_cached_codex(self, environment: BaseEnvironment) -> bool:
        if await self._installed_codex_satisfies_version(environment):
            return True
        machine_result = await environment.exec(command="uname -m", user="root")
        if machine_result.return_code != 0:
            return False
        cached = self._codex_archive((machine_result.stdout or "").strip())
        if cached is None:
            return False
        archive, triple = cached
        remote_archive = "/tmp/blacklabel-codex-%s.tgz" % (self._version or "latest")
        install_root = "/opt/blacklabel-codex-%s" % (self._version or "latest")
        await environment.upload_file(archive, remote_archive)
        await self.exec_as_root(
            environment,
            command=(
                "set -eu; "
                f"mkdir -p {shlex.quote(install_root)}; "
                f"tar -xzf {shlex.quote(remote_archive)} "
                f"-C {shlex.quote(install_root)} --strip-components=2 package/vendor; "
                f"ln -sf {shlex.quote(install_root + '/' + triple + '/bin/codex')} "
                "/usr/local/bin/codex; "
                f"ln -sf {shlex.quote(install_root + '/' + triple + '/bin/codex-code-mode-host')} "
                "/usr/local/bin/codex-code-mode-host; "
                f"ln -sf {shlex.quote(install_root + '/' + triple + '/codex-path/rg')} "
                "/usr/local/bin/rg; "
                "codex --version"
            ),
        )
        return await self._installed_codex_satisfies_version(environment)

    @override
    async def install(self, environment: BaseEnvironment) -> None:
        await self.ensure_system_dependencies(
            environment, ("python3", "curl", "bash", "tar", "git")
        )
        if not await self._install_cached_codex(environment):
            # Install Node and npm independently. NodeSource's nodejs package
            # bundles npm and conflicts with Ubuntu's standalone npm package
            # when apt receives both names in one transaction.
            await self.ensure_system_dependencies(environment, ("ripgrep",))
            await self.ensure_system_dependencies(environment, ("nodejs",))
            await self.ensure_system_dependencies(environment, ("npm",))
            await super().install(environment)
        await self.exec_as_root(environment, command=java_home_compat_command())
        await environment.upload_dir(
            self._SOURCE_ROOT,
            self._REMOTE_SOURCE.as_posix(),
        )
        if self._benchmark_suite == "swe-bench":
            await self.exec_as_root(
                environment,
                command=swe_verifier_preflight_command(),
            )

    def _runtime_env(self, effort: str) -> dict[str, str]:
        return {
            "CODEX_HOME": self._REMOTE_CODEX_HOME.as_posix(),
            "OPERATOR_EFFORT": effort,
            "OPERATOR_HOME": self._REMOTE_OPERATOR_HOME.as_posix(),
            "OPERATOR_MODEL": "gpt-5.6-sol",
            "OPERATOR_POLL_SECONDS": "0.1",
            "OPERATOR_PORT": str(self._REMOTE_OPERATOR_PORT),
            "OPERATOR_PROFILE": "sol",
            "OPERATOR_PROVIDER": "codex",
            "OPERATOR_REPO": self._REMOTE_SOURCE.as_posix(),
            "OPERATOR_TASK_TIMEOUT_SECONDS": "7200",
            "OPERATOR_WORKERS": "1",
            "PYTHONPATH": self._REMOTE_SOURCE.as_posix(),
        }

    async def _prepare_codex_auth(
        self,
        environment: BaseEnvironment,
        env: dict[str, str],
    ) -> str:
        remote_secrets_dir = self._REMOTE_CODEX_SECRETS_DIR.as_posix()
        remote_auth_path = (self._REMOTE_CODEX_SECRETS_DIR / "auth.json").as_posix()
        await self.exec_as_agent(
            environment,
            command=(
                f"mkdir -p {shlex.quote(self._REMOTE_CODEX_HOME.as_posix())} "
                f"{shlex.quote(remote_secrets_dir)} "
                f"{shlex.quote(EnvironmentPaths.agent_dir.as_posix())}"
            ),
            env=env,
        )

        auth_json_path = self._resolve_auth_json_path()
        if auth_json_path:
            await environment.upload_file(auth_json_path, remote_auth_path)
            if environment.default_user is not None:
                await self.exec_as_root(
                    environment,
                    command=(
                        f"chown {environment.default_user} "
                        f"{shlex.quote(remote_auth_path)}"
                    ),
                )
        else:
            env["OPENAI_API_KEY"] = self.model_connection.api_key or ""
            await self.exec_as_agent(
                environment,
                command=(
                    f"printf '%s' \"$OPENAI_API_KEY\" > "
                    f"{shlex.quote(remote_secrets_dir + '/api-key')} && "
                    f"printf '{{\"OPENAI_API_KEY\":\"%s\"}}' "
                    f"\"$OPENAI_API_KEY\" > {shlex.quote(remote_auth_path)}"
                ),
                env=env,
            )

        await self.exec_as_agent(
            environment,
            command=(
                f"ln -sf {shlex.quote(remote_auth_path)} "
                f"{shlex.quote(self._REMOTE_CODEX_HOME.as_posix() + '/auth.json')}"
            ),
            env=env,
        )
        return remote_secrets_dir

    @staticmethod
    def _instruction_write_command(instruction: str, path: str) -> str:
        """Return a shell command that reproduces the UTF-8 instruction exactly."""

        encoded = base64.b64encode(str(instruction).encode("utf-8")).decode("ascii")
        return (
            "python3 -c "
            + shlex.quote(
                "import base64,sys;sys.stdout.buffer.write(base64.b64decode(sys.argv[1]))"
            )
            + " "
            + shlex.quote(encoded)
            + " >"
            + shlex.quote(path)
        )

    async def _run_benchmark_adaptive(
        self,
        instruction: str,
        environment: BaseEnvironment,
        env: dict[str, str],
        agent_dir: str,
        result_path: str,
    ) -> None:
        instruction_path = f"{agent_dir}/official-instruction.txt"
        stderr_path = f"{agent_dir}/operator.stderr.log"
        daemon_log = f"{agent_dir}/operator-daemon.log"
        adaptive_state = f"{agent_dir}/benchmark-adaptive"
        operator_home = f"{agent_dir}/operator-home"
        max_rounds = self._benchmark_adaptive_rounds
        command = f"""
set -euo pipefail
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  . "$HOME/.nvm/nvm.sh"
fi
export OPERATOR_CODEX_BIN="$(command -v codex)"
export OPERATOR_HOME={shlex.quote(operator_home)}
mkdir -p "$OPERATOR_HOME" {shlex.quote(adaptive_state)}
{self._instruction_write_command(instruction, instruction_path)}
python3 -m blacklabel_operator daemon >{shlex.quote(daemon_log)} 2>&1 &
operator_daemon_pid=$!
cleanup() {{
  kill -TERM "$operator_daemon_pid" 2>/dev/null || true
  wait "$operator_daemon_pid" 2>/dev/null || true
}}
trap cleanup EXIT
ready=0
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$OPERATOR_PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  echo "Black Label Operator daemon did not become healthy" >&2
  exit 1
fi
python3 -m blacklabel_operator.benchmark_adaptive \
  --instruction-path {shlex.quote(instruction_path)} \
  --workspace . \
  --state-dir {shlex.quote(adaptive_state)} \
  --result-path {shlex.quote(result_path)} \
  --effort {shlex.quote(str(self._resolved_flags.get('reasoning_effort') or 'high'))} \
  --benchmark-suite {shlex.quote(self._benchmark_suite)} \
  --max-rounds {max_rounds} \
  --read-only-sandbox danger-full-access \
  --timeout 7200 \
  2>{shlex.quote(stderr_path)}
"""
        await self.exec_as_agent(environment, command=command, env=env)

    @override
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        if self.model_name != "gpt-5.6-sol":
            raise ValueError("Black Label Operator benchmarks require gpt-5.6-sol")

        effort = str(self._resolved_flags.get("reasoning_effort") or "high")
        env = self._runtime_env(effort)
        access = self.model_connection
        if access.configured_base_url:
            env["OPENAI_BASE_URL"] = access.configured_base_url

        remote_secrets_dir = await self._prepare_codex_auth(environment, env)
        effective_config = self._build_effective_config(access.configured_base_url)
        await self._upload_effective_config(
            environment,
            effective_config,
            (self._REMOTE_CODEX_HOME / "config.toml").as_posix(),
        )

        agent_dir = EnvironmentPaths.agent_dir.as_posix()
        result_path = f"{agent_dir}/{self._OUTPUT_FILENAME}"
        if self._benchmark_adaptive:
            try:
                await self._run_benchmark_adaptive(
                    instruction, environment, env, agent_dir, result_path
                )
            finally:
                try:
                    await self.exec_as_agent(
                        environment,
                        command=(
                            f"if [ -d {shlex.quote(self._REMOTE_CODEX_HOME.as_posix() + '/sessions')} ]; then "
                            f"cp -R {shlex.quote(self._REMOTE_CODEX_HOME.as_posix() + '/sessions')} "
                            f"{shlex.quote(agent_dir + '/sessions')}; fi; "
                            f"rm -rf {shlex.quote(remote_secrets_dir)}"
                        ),
                        env=env,
                    )
                except Exception:
                    pass
            return
        stderr_path = f"{agent_dir}/operator.stderr.log"
        daemon_log = f"{agent_dir}/operator-daemon.log"
        state_dir = f"{agent_dir}/operator-state"
        pass_commands = []
        pass_paths = []
        pass_stderr_paths = []
        pass_patch_paths = []
        workspace_baseline_command = ""
        if self._workspace_consensus:
            workspace_baseline_command = """
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  git init -q
  git config user.name "Black Label Operator"
  git config user.email "operator@example.invalid"
  git add -A
  git commit --allow-empty -qm operator-baseline
fi
"""
        for index, prompt in enumerate(
            pipeline_prompts(
                instruction,
                self._review_passes,
                benchmark_suite=self._benchmark_suite,
            ),
            start=1,
        ):
            pass_effort = "xhigh" if index == 2 and effort == "high" else effort
            pass_path = f"{agent_dir}/operator-pass-{index}.json"
            pass_stderr = f"{agent_dir}/operator-pass-{index}.stderr.log"
            pass_patch = f"{agent_dir}/operator-pass-{index}.patch"
            pass_paths.append(pass_path)
            pass_stderr_paths.append(pass_stderr)
            pass_patch_paths.append(pass_patch)
            provider_command = (
                "printf %%s %s | python3 -m blacklabel_operator run "
                "--profile sol --model gpt-5.6-sol --effort %s "
                "--sandbox danger-full-access --isolation shared "
                "--max-attempts 1 --cwd . --timeout 7200 --json "
                "2>%s >%s"
                % (
                    shlex.quote(prompt),
                    shlex.quote(pass_effort),
                    shlex.quote(pass_stderr),
                    shlex.quote(pass_path),
                )
            )
            pass_commands.append(
                structured_result_command(provider_command, pass_path)
                + "; "
                "if git rev-parse --verify HEAD >/dev/null 2>&1; then "
                "git diff --binary HEAD -- . >%s; else : >%s; fi"
                % (
                    shlex.quote(pass_patch),
                    shlex.quote(pass_patch),
                )
            )
        quoted_patches = " ".join(
            shlex.quote(path) for path in pass_patch_paths
        )
        aggregate_command = (
            "selected_pass=$(python3 -m blacklabel_operator.benchmark_pipeline "
            "restore-consensus %s); "
            "python3 -m blacklabel_operator.benchmark_pipeline aggregate "
            "--selected-index \"$selected_pass\" %s %s; "
            "cp %s %s"
            % (
                quoted_patches,
                shlex.quote(result_path),
                " ".join(shlex.quote(path) for path in pass_paths),
                shlex.quote(pass_stderr_paths[-1]),
                shlex.quote(stderr_path),
            )
        )
        command = f"""
set -euo pipefail
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  . "$HOME/.nvm/nvm.sh"
fi
export OPERATOR_CODEX_BIN="$(command -v codex)"
rm -rf "$OPERATOR_HOME"
mkdir -p "$OPERATOR_HOME" {shlex.quote(state_dir)}
python3 -m blacklabel_operator daemon >{shlex.quote(daemon_log)} 2>&1 &
operator_daemon_pid=$!
cleanup() {{
  kill -TERM "$operator_daemon_pid" 2>/dev/null || true
  wait "$operator_daemon_pid" 2>/dev/null || true
  cp -R "$OPERATOR_HOME/tasks" {shlex.quote(state_dir)}/ 2>/dev/null || true
  cp "$OPERATOR_HOME"/state.db* {shlex.quote(state_dir)}/ 2>/dev/null || true
}}
trap cleanup EXIT
ready=0
for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$OPERATOR_PORT/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  echo "Black Label Operator daemon did not become healthy" >&2
  exit 1
fi
{workspace_baseline_command}
{chr(10).join(pass_commands)}
{aggregate_command}
"""
        try:
            await self.exec_as_agent(environment, command=command, env=env)
        finally:
            try:
                await self.exec_as_agent(
                    environment,
                    command=(
                        f"if [ -d {shlex.quote(self._REMOTE_CODEX_HOME.as_posix() + '/sessions')} ]; then "
                        f"cp -R {shlex.quote(self._REMOTE_CODEX_HOME.as_posix() + '/sessions')} "
                        f"{shlex.quote(agent_dir + '/sessions')}; fi; "
                        f"rm -rf {shlex.quote(remote_secrets_dir)}"
                    ),
                    env=env,
                )
            except Exception:
                pass

    @override
    def populate_context_post_run(self, context: AgentContext) -> None:
        session_root = self.logs_dir / "sessions"
        trajectories = []
        if session_root.is_dir():
            for session_file in sorted(session_root.rglob("rollout-*.jsonl")):
                try:
                    with tempfile.TemporaryDirectory() as directory:
                        temporary = Path(directory)
                        shutil.copy2(session_file, temporary / session_file.name)
                        trajectory = self._convert_events_to_trajectory(temporary)
                    if trajectory is not None:
                        trajectories.append(trajectory.to_json_dict())
                except Exception:
                    self.logger.exception(
                        "Failed to convert Operator Codex session %s", session_file
                    )
        if trajectories:
            merged = merge_atif_trajectories(
                trajectories,
                agent_name=self.name(),
                agent_version=self.version(),
                model_name=self.model_name,
            )
            trajectory_path = self.logs_dir / "trajectory.json"
            trajectory_path.write_text(
                format_trajectory_json(merged), encoding="utf-8"
            )
            metrics = merged["final_metrics"]
            context.cost_usd = metrics["total_cost_usd"]
            context.n_input_tokens = metrics["total_prompt_tokens"]
            context.n_cache_tokens = metrics["total_cached_tokens"]
            context.n_output_tokens = metrics["total_completion_tokens"]

        path = self.logs_dir / self._OUTPUT_FILENAME
        if not path.is_file():
            return
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        context.n_input_tokens = int(result.get("input_tokens") or 0)
        context.n_cache_tokens = int(result.get("cached_input_tokens") or 0)
        context.n_output_tokens = int(result.get("output_tokens") or 0)
        context.metadata = {
            "operator_profile": result.get("profile"),
            "operator_provider": result.get("provider"),
            "operator_model": result.get("model"),
            "operator_state": result.get("state"),
            "operator_task_id": result.get("id"),
            "operator_pipeline_passes": (result.get("pipeline") or {}).get(
                "total_passes"
            ),
            "operator_adaptive_receipt_sha256": (result.get("pipeline") or {}).get(
                "receipt_sha256"
            ),
            "operator_episode_head_sha256": (result.get("pipeline") or {}).get(
                "episode_head_sha256"
            ),
            "operator_instruction_sha256": result.get("instruction_sha256"),
        }
