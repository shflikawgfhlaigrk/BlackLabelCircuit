import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


PACKAGE_ROOT = Path(__file__).resolve().parent


def _default_repo_root():
    """Return only this distribution's source, never an entire site-packages tree."""
    candidate = PACKAGE_ROOT.parent
    if (candidate / "pyproject.toml").is_file():
        return candidate
    return PACKAGE_ROOT


REPO_ROOT = _default_repo_root()
SUPERVISED_PROCESS_GROUP_ENV = "OPERATOR_SUPERVISED_PROCESS_GROUP"


def should_start_new_session():
    value = os.environ.get(SUPERVISED_PROCESS_GROUP_ENV, "").strip().lower()
    return value not in {"1", "true", "yes", "on"}


def _path_env(name, default):
    return Path(os.environ.get(name, str(default))).expanduser().resolve()


@dataclass(frozen=True)
class Settings:
    home: Path
    repo_root: Path
    codex_bin: Path
    model: str
    effort: str
    sandbox: str
    port: int
    workers: int
    lease_seconds: int
    task_timeout_seconds: int
    poll_seconds: float
    provider: str = "codex"
    profile: str = "sol"
    user_home: Optional[Path] = None
    install_root: Optional[Path] = None
    bin_dir: Optional[Path] = None

    @classmethod
    def load(cls):
        user_home = _path_env("OPERATOR_USER_HOME", Path.home())
        codex = (
            os.environ.get("OPERATOR_CODEX_BIN")
            or os.environ.get("SOL_CODEX_BIN")
            or shutil.which("codex")
        )
        if not codex:
            codex = str(Path.home() / ".local/bin/codex")
        model = os.environ.get("OPERATOR_MODEL") or os.environ.get(
            "SOL_MODEL", "gpt-5.6-sol"
        )
        return cls(
            home=_path_env(
                "OPERATOR_HOME",
                os.environ.get("SOL_HOME", Path.home() / ".blacklabel-operator"),
            ),
            repo_root=_path_env(
                "OPERATOR_RUNTIME_REPO",
                os.environ.get(
                    "OPERATOR_REPO", os.environ.get("SOL_REPO", REPO_ROOT)
                ),
            ),
            codex_bin=Path(codex).expanduser().resolve(),
            model=model,
            effort=os.environ.get(
                "OPERATOR_EFFORT", os.environ.get("SOL_EFFORT", "high")
            ),
            sandbox=os.environ.get(
                "OPERATOR_SANDBOX",
                os.environ.get("SOL_SANDBOX", "workspace-write"),
            ),
            port=int(
                os.environ.get("OPERATOR_PORT", os.environ.get("SOL_PORT", "8846"))
            ),
            workers=max(
                1,
                int(
                    os.environ.get(
                        "OPERATOR_WORKERS", os.environ.get("SOL_WORKERS", "1")
                    )
                ),
            ),
            lease_seconds=max(
                15,
                int(
                    os.environ.get(
                        "OPERATOR_LEASE_SECONDS",
                        os.environ.get("SOL_LEASE_SECONDS", "60"),
                    )
                ),
            ),
            task_timeout_seconds=max(
                30,
                int(
                    os.environ.get(
                        "OPERATOR_TASK_TIMEOUT_SECONDS",
                        os.environ.get("SOL_TASK_TIMEOUT_SECONDS", "7200"),
                    )
                ),
            ),
            poll_seconds=max(
                0.05,
                float(
                    os.environ.get(
                        "OPERATOR_POLL_SECONDS",
                        os.environ.get("SOL_POLL_SECONDS", "0.25"),
                    )
                ),
            ),
            provider=os.environ.get("OPERATOR_PROVIDER", "codex"),
            profile=os.environ.get("OPERATOR_PROFILE", "sol"),
            user_home=user_home,
            install_root=_path_env(
                "OPERATOR_INSTALL_ROOT",
                user_home / ".local/share/blacklabel-operator",
            ),
            bin_dir=_path_env("OPERATOR_BIN_DIR", user_home / ".local/bin"),
        )

    @property
    def resolved_user_home(self):
        return Path(self.user_home or Path.home()).expanduser().resolve()

    @property
    def resolved_install_root(self):
        default = self.resolved_user_home / ".local/share/blacklabel-operator"
        return Path(self.install_root or default).expanduser().resolve()

    @property
    def resolved_bin_dir(self):
        default = self.resolved_user_home / ".local/bin"
        return Path(self.bin_dir or default).expanduser().resolve()

    @property
    def db_path(self):
        return self.home / "state.db"

    @property
    def tasks_dir(self):
        return self.home / "tasks"

    @property
    def logs_dir(self):
        return self.home / "logs"

    @property
    def grok_clients_dir(self):
        return self.home / "grok-clients"

    @property
    def worktrees_dir(self):
        return self.home / "worktrees"

    @property
    def schedules_dir(self):
        return self.home / "schedules"

    @property
    def benchmark_dir(self):
        return self.home / "benchmarks"

    @property
    def health_url(self):
        return "http://127.0.0.1:%d/health" % self.port

    def ensure_dirs(self):
        for path in (
            self.home,
            self.tasks_dir,
            self.logs_dir,
            self.grok_clients_dir,
            self.benchmark_dir,
            self.worktrees_dir,
            self.schedules_dir,
        ):
            path.mkdir(parents=True, exist_ok=True)
        try:
            self.home.chmod(0o700)
        except OSError:
            pass
