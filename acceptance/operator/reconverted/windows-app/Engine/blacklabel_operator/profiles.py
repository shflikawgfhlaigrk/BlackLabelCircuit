from dataclasses import asdict, dataclass


SOL_MODEL = "gpt-5.6-sol"


@dataclass(frozen=True)
class ExecutionProfile:
    name: str
    provider: str
    model: str
    effort: str
    sandbox: str
    isolation: str
    max_attempts: int
    require_capabilities: tuple = ()
    disable_customizations: bool = True
    require_verification: bool = False
    adaptive: bool = False
    adaptive_max_rounds: int = 0
    adaptive_max_tokens: int = 0

    def as_dict(self):
        return asdict(self)


PROFILES = {
    "sol": ExecutionProfile(
        name="sol",
        provider="codex",
        model=SOL_MODEL,
        effort="high",
        sandbox="workspace-write",
        isolation="shared",
        max_attempts=2,
        require_capabilities=("json_stream", "resume", "sandbox"),
    ),
    "sol-benchmark": ExecutionProfile(
        name="sol-benchmark",
        provider="codex",
        model=SOL_MODEL,
        effort="low",
        sandbox="workspace-write",
        isolation="worktree",
        max_attempts=1,
        require_capabilities=("json_stream", "resume", "sandbox"),
    ),
    "safe": ExecutionProfile(
        name="safe",
        provider="codex",
        model=SOL_MODEL,
        effort="high",
        sandbox="read-only",
        isolation="shared",
        max_attempts=1,
        require_capabilities=("sandbox",),
    ),
    "build": ExecutionProfile(
        name="build",
        provider="codex",
        model=SOL_MODEL,
        effort="high",
        sandbox="workspace-write",
        isolation="worktree",
        max_attempts=2,
        require_verification=True,
    ),
    "adaptive": ExecutionProfile(
        name="adaptive",
        provider="codex",
        model=SOL_MODEL,
        effort="high",
        sandbox="workspace-write",
        isolation="worktree",
        max_attempts=1,
        require_capabilities=("json_stream", "sandbox"),
        require_verification=True,
        adaptive=True,
        adaptive_max_rounds=2,
        adaptive_max_tokens=300000,
    ),
    "full": ExecutionProfile(
        name="full",
        provider="codex",
        model=SOL_MODEL,
        effort="high",
        sandbox="danger-full-access",
        isolation="shared",
        max_attempts=1,
        disable_customizations=False,
    ),
}


def get_profile(name):
    try:
        return PROFILES[name]
    except KeyError as exc:
        raise ValueError("unknown execution profile: %s" % name) from exc


def resolve_execution(
    profile_name,
    provider=None,
    model=None,
    effort=None,
    sandbox=None,
    isolation=None,
    max_attempts=None,
):
    profile = get_profile(profile_name)
    selected = {
        "profile": profile.name,
        "provider": provider or profile.provider,
        "model": model or profile.model,
        "effort": effort or profile.effort,
        "sandbox": sandbox or profile.sandbox,
        "isolation": isolation or profile.isolation,
        "max_attempts": max_attempts or profile.max_attempts,
        "required_capabilities": list(profile.require_capabilities),
        "disable_customizations": profile.disable_customizations,
        "require_verification": profile.require_verification,
        "adaptive": profile.adaptive,
        "adaptive_max_rounds": profile.adaptive_max_rounds,
        "adaptive_max_tokens": profile.adaptive_max_tokens,
    }
    if profile.name.startswith("sol") or profile.adaptive:
        if selected["provider"] != "codex" or selected["model"] != SOL_MODEL:
            raise ValueError(
                "%s requires provider=codex and model=%s"
                % (profile.name, SOL_MODEL)
            )
    if profile.adaptive and (
        selected["sandbox"] != "workspace-write"
        or selected["isolation"] != "worktree"
        or selected["max_attempts"] != 1
    ):
        raise ValueError(
            "adaptive requires sandbox=workspace-write, isolation=worktree, "
            "and max_attempts=1"
        )
    return selected


def require_explicit_verification(execution, verification):
    if not execution.get("adaptive"):
        return
    commands = list(verification or [])
    if not commands:
        raise ValueError(
            "adaptive profile requires at least one explicit verification command"
        )
    for item in commands:
        command = item if isinstance(item, str) else (
            item.get("command") if isinstance(item, dict) else None
        )
        if not isinstance(command, str) or not command.strip():
            raise ValueError(
                "adaptive verification entries require a non-empty command"
            )
