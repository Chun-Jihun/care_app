import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.artifact_publication import staged_release


class ArtifactPublicationTests(unittest.TestCase):
    def test_failed_metadata_backup_does_not_leave_owned_partial_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pack, descriptor = root / 'pack', root / 'descriptor'
            descriptor.write_bytes(b'old')
            open_path = Path.open

            def fail_read(path, mode='r', *args, **kwargs):
                if path == descriptor and mode == 'rb':
                    raise OSError('synthetic backup read failure')
                return open_path(path, mode, *args, **kwargs)

            with patch.object(Path, 'open', fail_read):
                with self.assertRaises(OSError):
                    with staged_release([pack, descriptor], replace=[descriptor]):
                        self.fail('staging must not start')
            self.assertEqual(set(root.iterdir()), {descriptor})
            self.assertEqual(descriptor.read_bytes(), b'old')

    def test_failure_at_each_publish_boundary_restores_bundle_and_allows_retry(self):
        for fail_at in (1, 2, 3):
            with self.subTest(fail_at=fail_at), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                pack, lock, descriptor = [root / name for name in ('pack', 'lock', 'descriptor')]
                lock.write_bytes(b'old lock')
                descriptor.write_bytes(b'old descriptor')
                calls = 0
                link, replace = os.link, os.replace

                def fail(operation):
                    def publish(source, target):
                        nonlocal calls
                        calls += 1
                        if calls == fail_at:
                            raise OSError('synthetic publication failure')
                        operation(source, target)
                    return publish

                with patch('scripts.artifact_publication.os.link', fail(link)), patch(
                    'scripts.artifact_publication.os.replace', fail(replace)
                ):
                    with self.assertRaises(OSError):
                        with staged_release([pack, lock, descriptor], replace=[lock, descriptor]) as staged:
                            for path in staged:
                                staged[path].write_bytes(b'new ' + path.name.encode())
                self.assertFalse(pack.exists())
                self.assertEqual(lock.read_bytes(), b'old lock')
                self.assertEqual(descriptor.read_bytes(), b'old descriptor')
                self.assertEqual(set(root.iterdir()), {lock, descriptor})
                with staged_release([pack, lock, descriptor], replace=[lock, descriptor]) as staged:
                    for path in staged:
                        staged[path].write_bytes(b'new ' + path.name.encode())
                self.assertEqual(descriptor.read_bytes(), b'new descriptor')
