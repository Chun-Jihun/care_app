import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from zipfile import ZipFile

from scripts import prepare_mobile_ai_native as native


class NativePreparationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.enterContext(patch.object(native, 'ROOT', root))
        self.source = root / 'data/mobile-ai/sources'
        self.source.mkdir(parents=True)
        self.archive = self.source / 'llama-b10903-bin-win-cpu-x64.zip'
        with ZipFile(self.archive, 'w') as archive:
            archive.writestr('llama-quantize.exe', b'synthetic tool')
        self.vad = self.source / 'silero-v6.2.onnx'
        self.expected_vad = b'synthetic vad'
        self.lock = root / 'experiments/mobile_ai_v1/native-sources.lock.json'
        self.lock.parent.mkdir(parents=True)
        self.pins = json.dumps([
            dict(path=path.relative_to(root).as_posix(), url=f'https://example.invalid/{path.name}',
                 bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
            for path, data in ((self.archive, self.archive.read_bytes()), (self.vad, self.expected_vad))
        ])
        self.lock.write_text(self.pins, encoding='utf-8')

    def test_interrupted_download_is_not_published_and_can_retry(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.side_effect = [b'cut', OSError('synthetic connection failure')]
        with patch.object(native, 'urlopen', return_value=response):
            with self.assertRaisesRegex(OSError, 'synthetic connection failure'):
                native.main()
        self.assertEqual(list(self.source.iterdir()), [self.archive])
        self.assertEqual(self.lock.read_text(encoding='utf-8'), self.pins)

        with patch.object(native, 'urlopen', return_value=io.BytesIO(self.expected_vad)):
            native.main()
        self.assertEqual(self.vad.read_bytes(), self.expected_vad)
        self.assertEqual(self.lock.read_text(encoding='utf-8'), self.pins)

    def test_bad_cached_file_and_bad_response_cannot_change_the_pin(self):
        corrupt = b'x' * len(self.expected_vad)
        self.vad.write_bytes(corrupt)
        for invalid in (b'cut', corrupt, self.expected_vad + b'extra'):
            with self.subTest(response=invalid), patch.object(
                native, 'urlopen', return_value=io.BytesIO(invalid)
            ):
                with self.assertRaisesRegex(ValueError, 'silero-v6.2.onnx'):
                    native.main()
                self.assertEqual(self.vad.read_bytes(), corrupt)
                self.assertEqual(self.lock.read_text(encoding='utf-8'), self.pins)
                self.assertCountEqual(self.source.iterdir(), [self.vad, self.archive])

        with patch.object(native, 'urlopen', return_value=io.BytesIO(self.expected_vad)) as download:
            native.main()
            download.assert_called_once()
        self.assertEqual(self.vad.read_bytes(), self.expected_vad)
        with patch.object(native, 'urlopen', side_effect=AssertionError('network forbidden')):
            native.main()
        self.assertEqual(self.lock.read_text(encoding='utf-8'), self.pins)
