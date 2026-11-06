"""A fresh checkout must preserve the byte identity recorded by model manifests."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = Path('experiments/agent_eval/manifests')


class CheckoutContractTests(unittest.TestCase):
    def test_recorded_json_hashes_survive_windows_and_unix_checkout(self):
        inputs = json.loads((ROOT / MANIFESTS / 'model_comparison_inputs_v1.json').read_text(encoding='utf-8'))
        files = {
            MANIFESTS / 'model_comparison_runtime_profiles_v1.json': inputs['locked_assets']['runtime_profile_sha256'],
            MANIFESTS / 'model_comparison_v1/models.lock.json': inputs['locked_assets']['model_lock_sha256'],
        }
        for autocrlf in ['true', 'false']:
            with self.subTest(autocrlf=autocrlf), tempfile.TemporaryDirectory() as temp:
                repository = Path(temp) / 'source'
                repository.mkdir()
                attributes = ROOT / '.gitattributes'
                if attributes.exists():
                    (repository / '.gitattributes').write_bytes(attributes.read_bytes())
                for path in files:
                    destination = repository / path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes((ROOT / path).read_bytes())
                git = ['git', '-C', str(repository), '-c', f'core.autocrlf={autocrlf}']
                subprocess.run([*git, 'init', '-q'], check=True, capture_output=True)
                subprocess.run([*git, 'add', '.'], check=True, capture_output=True)
                checkout = Path(temp) / 'checkout'
                subprocess.run(
                    [*git, 'checkout-index', '--all', '--force', f'--prefix={checkout.as_posix()}/'],
                    check=True, capture_output=True,
                )
                for path, expected in files.items():
                    self.assertEqual(hashlib.sha256((checkout / path).read_bytes()).hexdigest(), expected, str(path))


if __name__ == '__main__':
    unittest.main()
