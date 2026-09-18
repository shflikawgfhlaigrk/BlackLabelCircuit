"""circuit_port — the portable helpers Circuit ships with a converted codebase.

Converted Python calls these instead of hard-coding macOS paths and commands.
Each helper does the native thing on macOS, Windows and Linux. Standard library only.
"""
import os
import subprocess
import sys

_WIN = sys.platform == "win32"
_MAC = sys.platform == "darwin"


def _base(mac_dir, win_env, xdg_env, xdg_default):
    if _MAC:
        return os.path.join(os.path.expanduser("~/Library"), mac_dir)
    if _WIN:
        root = os.environ.get(win_env) or os.path.join(os.path.expanduser("~"), "AppData", "Local" if win_env == "LOCALAPPDATA" else "Roaming")
        return root
    return os.environ.get(xdg_env) or os.path.expanduser(xdg_default)


def app_support(name=""):
    """~/Library/Application Support/<name> · %APPDATA%\\<name> · $XDG_DATA_HOME/<name>."""
    return os.path.join(_base("Application Support", "APPDATA", "XDG_DATA_HOME", "~/.local/share"), *name.split("/")) if name else _base("Application Support", "APPDATA", "XDG_DATA_HOME", "~/.local/share")


def caches(name=""):
    """~/Library/Caches/<name> · %LOCALAPPDATA%\\<name>\\Cache · $XDG_CACHE_HOME/<name>."""
    root = _base("Caches", "LOCALAPPDATA", "XDG_CACHE_HOME", "~/.cache")
    if not name:
        return root
    parts = name.split("/")
    return os.path.join(root, parts[0], "Cache", *parts[1:]) if _WIN else os.path.join(root, *parts)


def logs(name=""):
    """~/Library/Logs/<name> · %LOCALAPPDATA%\\<name>\\Logs · $XDG_STATE_HOME/<name>."""
    root = _base("Logs", "LOCALAPPDATA", "XDG_STATE_HOME", "~/.local/state")
    if not name:
        return root
    parts = name.split("/")
    return os.path.join(root, parts[0], "Logs", *parts[1:]) if _WIN else os.path.join(root, *parts)


def open_path(target):
    """Open a file, folder or URL with the default app (macOS `open`)."""
    target = str(target)
    if _WIN:
        os.startfile(target)  # noqa: S606 — the Windows shell "open" verb
        return None
    return subprocess.run(["open" if _MAC else "xdg-open", target], check=False)


def say(text):
    """Speak text (macOS `say`). Windows uses the built-in SAPI voice through PowerShell."""
    text = str(text)
    if _MAC:
        return subprocess.run(["say", text], check=False)
    if _WIN:
        script = "Add-Type -AssemblyName System.Speech; (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak([Console]::In.ReadToEnd())"
        return subprocess.run(["powershell", "-NoProfile", "-Command", script], input=text, text=True, check=False)
    return subprocess.run(["spd-say", text], check=False)


def play_sound(path):
    """Play an audio file and wait for it to finish (macOS `afplay`)."""
    path = str(path)
    if _MAC:
        return subprocess.run(["afplay", path], check=False)
    if _WIN:
        if path.lower().endswith(".wav"):
            import winsound
            winsound.PlaySound(path, winsound.SND_FILENAME)
            return None
        script = ("Add-Type -AssemblyName presentationCore; $p = New-Object System.Windows.Media.MediaPlayer; "
                  "$p.Open([Uri]$args[0]); $p.Play(); Start-Sleep -Milliseconds 300; "
                  "while ($p.NaturalDuration.HasTimeSpan -and $p.Position -lt $p.NaturalDuration.TimeSpan) { Start-Sleep -Milliseconds 100 }")
        return subprocess.run(["powershell", "-NoProfile", "-Command", script, path], check=False)
    return subprocess.run(["paplay", path], check=False)


class _FcntlCompat:
    """`fcntl.flock` with the LOCK_* flags on every OS (msvcrt.locking on Windows)."""

    LOCK_SH, LOCK_EX, LOCK_NB, LOCK_UN = 1, 2, 4, 8

    def flock(self, fd, operation):
        if not _WIN:
            import fcntl as _fcntl
            native = 0
            if operation & self.LOCK_SH:
                native |= _fcntl.LOCK_SH
            if operation & self.LOCK_EX:
                native |= _fcntl.LOCK_EX
            if operation & self.LOCK_NB:
                native |= _fcntl.LOCK_NB
            if operation & self.LOCK_UN:
                native |= _fcntl.LOCK_UN
            return _fcntl.flock(fd, native)
        import msvcrt
        handle = fd if isinstance(fd, int) else fd.fileno()
        here = os.lseek(handle, 0, os.SEEK_CUR)
        os.lseek(handle, 0, os.SEEK_SET)
        try:
            if operation & self.LOCK_UN:
                try:
                    msvcrt.locking(handle, msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass  # unlocking an unlocked byte is not an error for flock
            else:
                # msvcrt has no shared lock: LOCK_SH is taken as exclusive (stricter, never weaker).
                mode = msvcrt.LK_NBLCK if operation & self.LOCK_NB else msvcrt.LK_LOCK
                try:
                    msvcrt.locking(handle, mode, 1)
                except OSError as exc:
                    raise BlockingIOError(exc.errno, "lock held by another process") from exc
        finally:
            os.lseek(handle, here, os.SEEK_SET)
        return None


fcntl_compat = _FcntlCompat()
