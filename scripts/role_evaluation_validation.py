"""Bounded JSON extraction and component response schema checks."""
from __future__ import annotations

import json
import re
from typing import Any, Mapping

try:
    from scripts.role_evaluation_contracts import (
        HarnessError,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from role_evaluation_contracts import (
        HarnessError,
    )


def _first_balanced_object(text: str) -> str | None:
    start = text.find("{")
    while start >= 0:
        depth = 0
        in_string = False
        escaped = False
        for index in range(start, len(text)):
            character = text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == '"':
                    in_string = False
                continue
            if character == '"':
                in_string = True
            elif character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return text[start : index + 1]
        start = text.find("{", start + 1)
    return None

def parse_json_response(raw_text: str) -> dict[str, Any]:
    if not isinstance(raw_text, str) or not raw_text.strip():
        raise HarnessError("모델 응답이 비어 있습니다.")
    fenced = re.search(r"```(?:json)?\s*(.*?)\s*```", raw_text, re.DOTALL | re.IGNORECASE)
    candidate = fenced.group(1) if fenced else raw_text.strip()
    try:
        value = json.loads(candidate)
    except json.JSONDecodeError:
        balanced = _first_balanced_object(candidate)
        if balanced is None:
            raise HarnessError("모델 응답에서 JSON object를 찾을 수 없습니다.")
        try:
            value = json.loads(balanced)
        except json.JSONDecodeError as exc:
            raise HarnessError(f"모델 JSON object 형식이 잘못되었습니다: {exc}") from exc
    if not isinstance(value, dict):
        raise HarnessError("모델 응답 JSON은 object여야 합니다.")
    return value

def _schema_errors(value: Any, schema: Mapping[str, Any], path: str = "$") -> list[str]:
    errors: list[str] = []
    expected_type = schema.get("type")
    type_matches = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
    }
    if isinstance(expected_type, str) and not type_matches.get(expected_type, False):
        return [f"{path}: expected {expected_type}"]
    enum = schema.get("enum")
    if isinstance(enum, list) and value not in enum:
        errors.append(f"{path}: value is not in enum")
    minimum = schema.get("minimum")
    if isinstance(minimum, (int, float)) and isinstance(value, (int, float)):
        if value < minimum:
            errors.append(f"{path}: value is below minimum")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        if isinstance(required, list):
            for field_name in required:
                if field_name not in value:
                    errors.append(f"{path}.{field_name}: required field is missing")
        if schema.get("additionalProperties") is False and isinstance(properties, dict):
            for field_name in value:
                if field_name not in properties:
                    errors.append(f"{path}.{field_name}: additional field is forbidden")
        if isinstance(properties, dict):
            for field_name, field_value in value.items():
                child_schema = properties.get(field_name)
                if isinstance(child_schema, dict):
                    errors.extend(
                        _schema_errors(field_value, child_schema, f"{path}.{field_name}")
                    )
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for index, item in enumerate(value):
            errors.extend(_schema_errors(item, schema["items"], f"{path}[{index}]"))
    return errors
