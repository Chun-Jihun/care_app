"""Small project-owned synthetic inputs; never depend on downloaded model runs."""
import hashlib
import json
from pathlib import Path

from scripts.compile_agent_evaluation_scenarios import compile_scenarios
from scripts.ds_agent_model_runner import ReplayRoleBackend
from scripts.run_ds_agent_model import run_model_bundle
from scripts.report_ds_agent_automated_eval import generate_report


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def declare_outputs(folder: Path, names: list[str], **metadata) -> None:
    write_json(folder / 'manifest.json', dict(metadata, outputs=[{
        'file': name, 'bytes': (folder / name).stat().st_size,
        'sha256': hashlib.sha256((folder / name).read_bytes()).hexdigest(),
        **({'record_count': len((folder / name).read_text(encoding='utf-8').splitlines())}
           if name.endswith('.jsonl') else {}),
    } for name in names]))


def compiled_bundle(root: Path, base: Path) -> Path:
    source = base / 'source'
    event = {
        'schema_version': '1.0', 'source_event_id': 'SYN-EVENT-1',
        'patient_key': 'synthetic_patient', 'occurred_at': '2026-01-03T19:00:00+09:00',
        'entry_type': 'medication_intake', 'medication_display_name': '시험약',
        'drug_link': None, 'intake_status': 'taken', 'reason_code': None,
        'confirmation_status': 'confirmed',
    }
    source.mkdir(parents=True)
    # JSONL is one physical line, unlike the indented JSON manifests.
    (source / 'medication_events.jsonl').write_text(json.dumps(event) + '\n', encoding='utf-8')
    declare_outputs(source, ['medication_events.jsonl'],
        schema_version='1.0', source_id='SYNTHETIC-UNIT-001', source_kind='synthetic',
        source_title='Synthetic unit fixture', source_url='https://example.invalid/unit',
        source_revision='v1', privacy={'direct_identifiers_present': False,
            'patient_keys_pseudonymous': True, 'free_text_excluded': True},
        usage={'evaluation_only': True, 'do_not_train': True, 'mobile_bundle': False},
        license={'status': 'project_owned_synthetic'})
    return compile_scenarios(root, source, base / 'compiled',
        root / 'docs/agent_role_and_tool_contracts.md', development_percent=100,
        validation_percent=0, include_no_knowledge_abstention=True)


def synthetic_report(root: Path, base: Path) -> Path:
    bundle = compiled_bundle(root, base)
    episode = json.loads((bundle / 'development/episodes.jsonl').read_text(encoding='utf-8').splitlines()[0])
    # A malformed model answer exercises the real fail-closed runner and trace
    # verifier. No GPU or medical performance claim is involved.
    backend = ReplayRoleBackend([{'item_id': episode['item_id'], 'role_id': 'A1',
        'call_index': i, 'raw_text': 'invalid synthetic model JSON', 'usage': {}}
        for i in (1, 2, 3)], source_sha256='synthetic-unit-replay')
    run = base / 'run'
    run_model_bundle(root, bundle, run, run_id='SYNTHETIC-UNIT-RUN', backend=backend,
        split='development', limit=1, topology_id='T3')
    report = base / 'ds-report'
    generate_report(root, [run], report, require_complete=False, compiled_bundle_dir=bundle)
    return report


def consolidated_inputs(root: Path, base: Path) -> Path:
    ds = synthetic_report(root, base)
    response, score = base / 'responses', base / 'score'
    response.mkdir(parents=True)
    (response / 'responses.jsonl').write_text('{"status":"ok","usage":{}}\n', encoding='utf-8')
    declare_outputs(response, ['responses.jsonl'], record_count=1, status_counts={'ok': 1})
    write_json(score / 'summary.json', {'scored_responses': 1, 'unscored_responses': 0,
        'scoring_coverage': 1, 'metric_means': {'synthetic_contract': 1}, 'failure_counts': {}})
    declare_outputs(score, ['summary.json'])
    inputs = base / 'inputs.json'
    write_json(inputs, {'ds_agent_report_dir': ds.relative_to(root).as_posix(), 'components': [{
        'id': 'synthetic-contract', 'role': 'A1', 'source': 'project-owned synthetic',
        'response_dir': response.relative_to(root).as_posix(),
        'score_dir': score.relative_to(root).as_posix()}]})
    return inputs
