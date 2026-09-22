"""Cross-platform lifecycle locks for immutable Operator upgrades."""
import errno, os
from contextlib import contextmanager
from pathlib import Path
UPGRADE_MESSAGE = "Operator upgrade is in progress; task admission is closed"
class UpgradeInProgressError(RuntimeError): pass
def lock_path(database_path): return Path(database_path).expanduser().resolve().parent / ".upgrade-admission.lock"
@contextmanager
def _locked(database_path, exclusive, blocking):
    path=lock_path(database_path); path.parent.mkdir(parents=True,exist_ok=True)
    handle=open(path,"a+b"); handle.seek(0); handle.write(b"0"); handle.flush(); handle.seek(0)
    try:
        if os.name == "nt":
            import msvcrt
            mode=(msvcrt.LK_LOCK if blocking else msvcrt.LK_NBLCK)
            try: msvcrt.locking(handle.fileno(),mode,1)
            except OSError as exc: raise UpgradeInProgressError(UPGRADE_MESSAGE) from exc
        else:
            import fcntl
            mode=fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
            if not blocking: mode |= fcntl.LOCK_NB
            try: fcntl.flock(handle.fileno(),mode)
            except OSError as exc:
                if exc.errno in (errno.EACCES,errno.EAGAIN): raise UpgradeInProgressError(UPGRADE_MESSAGE) from exc
                raise
        yield path
    finally:
        try:
            if os.name == "nt":
                import msvcrt
                handle.seek(0); msvcrt.locking(handle.fileno(),msvcrt.LK_UNLCK,1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(),fcntl.LOCK_UN)
        finally: handle.close()
@contextmanager
def admission_lock(database_path):
    with _locked(database_path,False,False) as path: yield path
@contextmanager
def exclusive_upgrade_lock(database_path):
    with _locked(database_path,True,True) as path: yield path
