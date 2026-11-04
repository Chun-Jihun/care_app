"""Explicit integration invocation requires the archived local scenario bundle."""
from pathlib import Path
import unittest
from unittest.mock import patch

from tests import test_ds_agent_model_runner as runner


class ArchivedModelRunnerTests(unittest.TestCase):
    def setUp(self):
        bundle = Path.cwd() / 'data/agent-eval/scenario-candidates/ds-agent-pilot-v1'
        override = patch.object(runner, 'compiled_bundle', lambda root, base: bundle)
        override.start()
        self.addCleanup(override.stop)

    test_bundle = runner.DsAgentModelRunnerTests.test_compiled_bundle_runs_and_writes_hash_only_model_call_artifacts
    test_resume = runner.DsAgentModelRunnerTests.test_checkpoint_resume_reuses_verified_episode_without_model_call
