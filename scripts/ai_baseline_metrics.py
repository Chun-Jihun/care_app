"""Task metrics: syntax never substitutes for source/number correctness."""
from __future__ import annotations

from collections import Counter
import json
import re
import unicodedata


def distance(a, b) -> int:
    previous = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        row = [i]
        for j, right in enumerate(b, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (left != right)))
        previous = row
    return previous[-1]


def normalized(text: str) -> str:
    # Preserve decimal points, units and negation; only fold case/whitespace.
    return ' '.join(unicodedata.normalize('NFC', text).lower().split())


def critical_tokens(text: str) -> Counter:
    return Counter(re.findall(r'\d+(?:[.,]\d+)?|(?<![a-z])(?:mg|ml|min|g|l)(?![a-z])', normalized(text)))


def strict_critical_tokens(text: str) -> Counter:
    # A separate diagnostic: never make mL and ML equal by case folding.
    return Counter(re.findall(r'\d+(?:[.,]\d+)?|(?<![a-z])(?:mg|ml|min|g|l)(?![a-z])',
                              unicodedata.normalize('NFC',text),flags=re.IGNORECASE))


def transcript_score(reference: str, prediction: str) -> dict:
    ref, pred = normalized(reference), normalized(prediction)
    a, b = ref.replace(' ', ''), pred.replace(' ', '')
    return {'character_edits': distance(a, b), 'reference_characters': len(a),
            'word_edits': distance(ref.split(), pred.split()), 'reference_words': len(ref.split()),
            'exact': ref == pred,
            'critical_tokens_exact': critical_tokens(ref) == critical_tokens(pred),
            'has_critical_tokens': bool(critical_tokens(ref)),
            'silence_hallucination': not ref and bool(pred)}


def validate_chat_output(raw: str, allowed_ids: set[str]) -> tuple[dict | None, dict]:
    try:
        value = json.loads(raw)
    except (ValueError, TypeError):
        return None, {'json_valid': False, 'schema_valid': False,
                      'unauthorized_id': False, 'failure': 'invalid_json'}
    valid = (isinstance(value, dict) and set(value) == {'status', 'record_ids', 'facts'}
             and isinstance(value['status'], str)
             and value['status'] in {'record_answer', 'no_records', 'needs_evidence'}
             and isinstance(value['record_ids'], list) and isinstance(value['facts'], list)
             and all(isinstance(x, str) for x in value['record_ids'] + value['facts'])
             and len(value['record_ids']) == len(set(value['record_ids'])))
    if not valid:
        return None, {'json_valid': True, 'schema_valid': False,
                      'unauthorized_id': False, 'failure': 'invalid_schema'}
    unauthorized = not set(value['record_ids']).issubset(allowed_ids)
    return value, {'json_valid':True, 'schema_valid':True, 'unauthorized_id':unauthorized,
                   'failure':'unauthorized_id' if unauthorized else None}


def chat_score(raw: str, expected: dict, allowed_ids: set[str]) -> dict:
    value, protocol = validate_chat_output(raw,allowed_ids)
    if value is None:
        return dict(protocol,task_exact=False)
    unauthorized = protocol['unauthorized_id']
    exact = value == expected and not unauthorized
    return {'json_valid': True, 'schema_valid': True, 'task_exact': exact,
            'unauthorized_id': unauthorized, 'status_exact': value['status'] == expected['status'],
            'ids_exact': value['record_ids'] == expected['record_ids'],
            'facts_exact': value['facts'] == expected['facts'],
            'failure': None if exact else ('unauthorized_id' if unauthorized else 'semantic_mismatch')}
