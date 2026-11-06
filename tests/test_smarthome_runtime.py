"""Verify lock recreation after boot and rejection of unsafe existing paths."""
import fcntl
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime', ROOT / 'scripts/ops/prepare-smarthome-runtime.py')
RUNTIME = importlib.util.module_from_spec(spec)
spec.loader.exec_module(RUNTIME)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.uid = os.getuid()

    def test_missing_directories_and_locks_are_created_after_reboot(self):
        RUNTIME.prepare(self.root, self.uid)
        self.assertEqual((self.root / 'manage-smarthome').stat().st_mode & 0o777, 0o700)
        for name, lock in (('manage-smarthome', 'install.lock'), ('manage-media-maintenance', 'daily.lock')):
            path = self.root / name / lock
            self.assertTrue(path.is_file())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_existing_lock_inode_contents_and_held_lock_are_preserved(self):
        RUNTIME.prepare(self.root, self.uid)
        path = self.root / 'manage-media-maintenance/daily.lock'
        path.write_text('preserve')
        inode = path.stat().st_ino
        with path.open('r+') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            RUNTIME.prepare(self.root, self.uid)
            with path.open() as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(path.stat().st_ino, inode)
        self.assertEqual(path.read_text(), 'preserve')

    def test_unsafe_directory_is_rejected_without_changing_permissions(self):
        path = self.root / 'manage-smarthome'
        path.mkdir()
        path.chmod(0o777)
        with self.assertRaises(ValueError):
            RUNTIME.prepare(self.root, self.uid)
        self.assertEqual(path.stat().st_mode & 0o777, 0o777)

    def test_wrong_owner_is_rejected(self):
        path = self.root / 'existing'
        path.mkdir()
        with self.assertRaises(ValueError):
            RUNTIME.ensure_directory(path, 0o700, self.uid + 1)

    def test_symlink_directory_and_lock_are_rejected_without_touching_target(self):
        target = self.root / 'target'
        target.mkdir()
        directory = self.root / 'manage-smarthome'
        directory.symlink_to(target, target_is_directory=True)
        with self.assertRaises(ValueError):
            RUNTIME.prepare(self.root, self.uid)
        directory.unlink()
        directory.mkdir(mode=0o700)
        secret = target / 'secret'
        secret.write_text('unchanged')
        (directory / 'install.lock').symlink_to(secret)
        with self.assertRaises(OSError):
            RUNTIME.prepare(self.root, self.uid)
        self.assertEqual(secret.read_text(), 'unchanged')

    def test_writable_lock_and_fifo_are_rejected_without_blocking(self):
        directory = self.root / 'manage-smarthome'
        directory.mkdir(mode=0o700)
        path = directory / 'install.lock'
        path.write_text('unchanged')
        path.chmod(0o666)
        with self.assertRaises(ValueError):
            RUNTIME.prepare(self.root, self.uid)
        self.assertEqual(path.read_text(), 'unchanged')
        path.unlink()
        os.mkfifo(path, 0o600)
        with self.assertRaises(ValueError):
            RUNTIME.prepare(self.root, self.uid)


if __name__ == '__main__':
    unittest.main()
