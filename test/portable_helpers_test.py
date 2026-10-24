import errno
import importlib.util
import pathlib
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('circuit_port', pathlib.Path(__file__).parents[1] / 'lib/convert-kit/circuit_port.py')
port = importlib.util.module_from_spec(spec)
spec.loader.exec_module(port)

class PortableHelpers(unittest.TestCase):
    def test_windows_media_path_is_data_on_stdin(self):
        path = r"C:\Music\Owner's clip.mp3"
        with patch.object(port, '_WIN', True), patch.object(port, '_MAC', False), patch.object(port.subprocess, 'run') as run:
            port.play_sound(path)
        args, kwargs = run.call_args
        self.assertNotIn(path, args[0])
        self.assertEqual(kwargs['input'], path)
        self.assertTrue(kwargs['text'])

    def test_windows_blocking_lock_waits_beyond_ten_attempts(self):
        calls = []
        def locking(*args):
            calls.append(args)
            if len(calls) <= 14:
                raise OSError(errno.EACCES, 'fixture lock is held')
        msvcrt = types.SimpleNamespace(LK_NBLCK=1, LK_UNLCK=2, locking=locking)
        with tempfile.TemporaryFile() as file, patch.object(port, '_WIN', True), patch.dict('sys.modules', {'msvcrt': msvcrt}), patch.object(port.time, 'sleep'):
            port.fcntl_compat.flock(file.fileno(), port.fcntl_compat.LOCK_EX)
        self.assertEqual(len(calls), 15)

    def test_windows_nonblocking_lock_reports_contention_immediately(self):
        def locking(*args): raise OSError(errno.EACCES, 'fixture lock is held')
        msvcrt = types.SimpleNamespace(LK_NBLCK=1, LK_UNLCK=2, locking=locking)
        with tempfile.TemporaryFile() as file, patch.object(port, '_WIN', True), patch.dict('sys.modules', {'msvcrt': msvcrt}), patch.object(port.time, 'sleep') as sleep:
            with self.assertRaises(BlockingIOError):
                port.fcntl_compat.flock(file.fileno(), port.fcntl_compat.LOCK_EX | port.fcntl_compat.LOCK_NB)
            sleep.assert_not_called()

if __name__ == '__main__': unittest.main()
