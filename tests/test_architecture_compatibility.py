"""Frozen pre-refactor traces and requests use synthetic records only."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import unittest

import test_ds_agent_model_runner as fixture
from scripts import ds_agent_model_runner as runner
from scripts import ds_agent_tool_host as host
from scripts import run_ds_agent_pilot as pilot
from scripts import role_evaluation_harness as harness
from scripts.evaluation_serialization import canonical_bytes
from scripts.run_ds_agent_model import _runner_source_hashes


class ArchitectureCompatibilityTests(unittest.TestCase):
    def test_checkpoint_identity_includes_extracted_runner_implementations(self):
        paths = _runner_source_hashes(Path(__file__).resolve().parents[1])
        for name in [
            'evaluation_serialization', 'ds_agent_model_contracts',
            'ds_agent_role_invocation', 'ds_agent_projections', 'ds_agent_results',
            'ds_agent_episode', 'ds_agent_episode_stages', 'ds_agent_model_backends',
        ]:
            self.assertIn(f'scripts/{name}.py', paths)
            self.assertEqual(len(paths[f'scripts/{name}.py']), 64)

    def test_all_topology_requests_outputs_and_trace_hashes_match_frozen_baseline(self):
        frozen = json.loads((Path(__file__).parent / 'fixtures/architecture_runner_compatibility.json').read_text(encoding='utf-8'))
        for topology in ['T1', 'T2', 'T3']:
            for scenario in ['normal', 'medical', 'blocked', 'repair', 'rewrite', 'safety']:
                with self.subTest(topology=topology, scenario=scenario):
                    medical = scenario == 'medical'
                    a1 = fixture._a1({'patient_id': 'OTHER'}) if scenario == 'blocked' else fixture._a1()
                    a5 = fixture._a5('rewrite_once') if scenario == 'rewrite' else fixture._a5()
                    backend = fixture.ScriptedBackend({
                        'A1': (['{invalid'] if scenario == 'repair' else []) + [fixture._dump(a1)],
                        'A2': [fixture._dump(fixture._a2())],
                        'A3': [fixture._dump(fixture._a3())],
                        'A4': [fixture._dump(fixture._a4(partial=medical))] * 2,
                        'A5': [fixture._dump(a5), fixture._dump(fixture._a5())],
                    })
                    state = fixture._state()
                    if scenario == 'safety':
                        state['safety_gate_result'] = 'stop'
                    result = runner.run_model_episode(
                        run_id='frozen-refactor', split='fixture',
                        episode=fixture._episode(medical=medical), state=state,
                        repository=fixture._repository(), backend=backend, topology_id=topology,
                    )
                    actual = {'result': result, 'requests': backend.calls}
                    self.assertEqual(canonical_bytes(actual), canonical_bytes(frozen[f'{topology}/{scenario}']))
        for name, expected in frozen['contracts'].items():
            value = getattr(harness if name == 'SYSTEM_PROMPTS' else runner, name)
            self.assertEqual(hashlib.sha256(canonical_bytes(value)).hexdigest(), expected, name)

    def test_shared_serialization_preserves_unicode_order_bytes_and_nonfinite_rejection(self):
        expected = '{"a":[true,null,2],"z":"합성 記録"}'.encode('utf-8')
        value = {'z': '합성 記録', 'a': [True, None, 2]}
        for encode in [canonical_bytes, runner._canonical_bytes, host._canonical_bytes, pilot._canonical_bytes]:
            self.assertIs(encode, canonical_bytes)
            self.assertEqual(encode(value), expected)
            with self.assertRaises(ValueError):
                encode({'number': float('nan')})
        # Component artifacts had a different legacy policy; do not silently
        # merge it with the stricter DS-AGENT trace contract.
        self.assertEqual(harness._canonical_bytes({'number': float('nan')}), b'{"number":NaN}')


if __name__ == '__main__':
    unittest.main()
