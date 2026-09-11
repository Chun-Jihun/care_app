"""Ablation only: copy values from host-scoped records instead of generated prose."""
import json

from scripts.ai_baseline_metrics import validate_chat_output


def render_record_facts(raw: str, records: list[dict]) -> str:
    """Does not change selected IDs/status or decide whether they match the question.

    Invalid schemas and foreign IDs remain failures. This is a measured diagnostic,
    not a deployed safety gate and not a medical validation rule.
    """
    by_id = {record['id']:record for record in records}
    if len(by_id) != len(records):
        raise ValueError('ambiguous source record IDs')
    value, score = validate_chat_output(raw,set(by_id))
    if not score['schema_valid'] or score['unauthorized_id']:
        return raw
    if value['status'] == 'record_answer':
        value['facts'] = [by_id[key]['value'] for key in value['record_ids']]
    return json.dumps(value,ensure_ascii=False)
