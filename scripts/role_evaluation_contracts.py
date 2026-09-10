"""Component evaluation metadata, exceptions and backend protocols."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Protocol



SCRIPT_VERSION = "0.2.0"

SCHEMA_VERSION = "1.0"

CONTRACT_VERSION = "0.1.0"

PROMPT_VERSION = "component-projection-v0.1.0"

DEFAULT_CONTRACT_PATH = Path("docs/agent_role_and_tool_contracts.md")

DEFAULT_DATA_LOCK = Path("experiments/agent_eval/manifests/data_sources.lock.json")

ROLES = {"A1", "A2", "A3", "A4", "A5", "KO"}

class HarnessError(RuntimeError):
    """Raised when an evaluation artifact violates the local harness contract."""

class UnsupportedProjection(HarnessError):
    """Raised when an upstream case needs a runtime this projection does not emulate."""

    def __init__(self, reason_code: str, message: str) -> None:
        super().__init__(message)
        self.reason_code = reason_code

@dataclass(frozen=True)
class BackendResult:
    raw_text: str
    usage: dict[str, Any] = field(default_factory=dict)

class LocalBackend(Protocol):
    @property
    def metadata(self) -> Mapping[str, Any]: ...

    def generate(self, request: Mapping[str, Any]) -> BackendResult: ...
