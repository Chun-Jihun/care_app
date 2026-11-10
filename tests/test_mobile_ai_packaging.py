import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from scripts import package_mobile_ai


class MobileAiPackagingTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        exports = self.root / 'data/mobile-ai/exports'
        files = {
            'chat': ['chat-q4km-text.gguf', 'prompt.json'],
            'asr': ['small-encoder.int8.onnx', 'small-decoder.int8.onnx', 'small-tokens.txt'],
            'ocr-ko-v9': ['recognizer.onnx', 'characters.json'],
            'ocr-multi-v1': ['recognizer.onnx', 'characters.json'],
            'ocr-det': ['detector.onnx'],
        }
        for name, leaves in files.items():
            folder = exports / name
            folder.mkdir(parents=True)
            (folder / 'summary.json').write_text('{"status":"completed"}', encoding='utf-8')
            for leaf in leaves:
                (folder / leaf).write_bytes(('synthetic ' + name + leaf).encode())
        source = self.root / 'data/mobile-ai/sources'
        source.mkdir()
        self.vad = source / 'silero-v6.2.onnx'
        self.vad.write_bytes(b'synthetic vad')
        self.asset = self.root / 'mobile/assets/ai/manifest.json'
        self.asset.parent.mkdir(parents=True)
        self.asset.write_bytes(b'prior trusted manifest')
        self.lock = self.root / 'experiments/mobile_ai_v1/model-pack.lock.json'
        self.lock.parent.mkdir(parents=True)
        self.lock.write_bytes(b'prior lock')
        self.lock.with_name('native-sources.lock.json').write_text(json.dumps([{
            'path': self.vad.relative_to(self.root).as_posix(),
            'url': 'https://example.invalid/vad',
            'bytes': self.vad.stat().st_size,
            'sha256': hashlib.sha256(self.vad.read_bytes()).hexdigest(),
        }]), encoding='utf-8')
        self.pack = self.root / 'data/mobile-ai/care-ai-dev-2026-09-11-v2.careai'
        self.addCleanup(patch.stopall)
        patch.object(package_mobile_ai, 'ROOT', self.root).start()

    def test_corrupt_vad_is_rejected_before_publication(self):
        self.vad.write_bytes(b'cut')
        with self.assertRaisesRegex(ValueError, 'VAD source'):
            package_mobile_ai.main()
        self.assertFalse(self.pack.exists())
        self.assertEqual(self.asset.read_bytes(), b'prior trusted manifest')
        self.assertEqual(self.lock.read_bytes(), b'prior lock')

    def test_manifest_failure_preserves_previous_release_and_retry_succeeds(self):
        write = Path.write_bytes

        def fail_manifest(path, data):
            if path.name.startswith('manifest.json'):
                raise OSError('synthetic disk failure')
            return write(path, data)

        with patch.object(Path, 'write_bytes', fail_manifest):
            with self.assertRaises(OSError):
                package_mobile_ai.main()
        self.assertFalse(self.pack.exists())
        self.assertEqual(self.asset.read_bytes(), b'prior trusted manifest')
        self.assertEqual(self.lock.read_bytes(), b'prior lock')
        package_mobile_ai.main()
        raw = self.pack.read_bytes()
        self.assertEqual(raw[:8], b'CAREAI01')
        length = struct.unpack('<I', raw[8:12])[0]
        self.assertEqual(raw[12:12+length], self.asset.read_bytes())
        manifest = json.loads(self.asset.read_bytes())
        offset = 12 + length
        for file in manifest['files']:
            chunk = raw[offset:offset+file['bytes']]
            self.assertEqual(hashlib.sha256(chunk).hexdigest(), file['sha256'])
            offset += file['bytes']
        self.assertEqual(offset, len(raw))
        self.assertFalse(manifest['medical_release_gate_result'])
        before = self.pack.read_bytes(), self.asset.read_bytes(), self.lock.read_bytes()
        with self.assertRaises(FileExistsError):
            package_mobile_ai.main()
        self.assertEqual(before, (self.pack.read_bytes(), self.asset.read_bytes(), self.lock.read_bytes()))

    def test_source_change_during_packaging_is_not_published(self):
        digest = package_mobile_ai.sha256

        def change_after_hash(path):
            value = digest(path)
            if path.name == 'chat-q4km-text.gguf':
                path.write_bytes(b'changed during packaging')
            return value

        with patch.object(package_mobile_ai, 'sha256', change_after_hash):
            with self.assertRaisesRegex(ValueError, 'source changed'):
                package_mobile_ai.main()
        self.assertFalse(self.pack.exists())
        self.assertEqual(self.asset.read_bytes(), b'prior trusted manifest')
        self.assertEqual(self.lock.read_bytes(), b'prior lock')

    def test_copy_failure_can_retry_without_deleting_any_prior_release(self):
        open_path = Path.open
        reads = 0

        def fail_copy(path, mode='r', *args, **kwargs):
            nonlocal reads
            if path.name == 'chat-q4km-text.gguf' and mode == 'rb':
                reads += 1
                if reads == 2:
                    raise OSError('synthetic source read failure')
            return open_path(path, mode, *args, **kwargs)

        with patch.object(Path, 'open', fail_copy):
            with self.assertRaises(OSError):
                package_mobile_ai.main()
        self.assertFalse(self.pack.exists())
        self.assertEqual(self.asset.read_bytes(), b'prior trusted manifest')
        package_mobile_ai.main()
