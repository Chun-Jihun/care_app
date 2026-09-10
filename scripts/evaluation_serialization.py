"""Stable UTF-8 serialization for finite DS-AGENT trace and manifest data."""
from typing import Any
import json

def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')
