"""Offline component replay, cached retrieval and local Transformers backends."""
from __future__ import annotations

import json
from pathlib import Path
import re
from typing import Any, Mapping

try:
    from scripts.role_evaluation_artifacts import (
        _load_json,
        _nonempty_string,
        _sha256_file,
    )
    from scripts.role_evaluation_contracts import (
        BackendResult,
        HarnessError,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from role_evaluation_artifacts import (
        _load_json,
        _nonempty_string,
        _sha256_file,
    )
    from role_evaluation_contracts import (
        BackendResult,
        HarnessError,
    )


class ReplayBackend:
    """Replay local raw outputs keyed by request ID; never reads case gold."""

    def __init__(self, responses: Mapping[str, str], *, replay_id: str) -> None:
        self._responses = dict(responses)
        self._replay_id = replay_id

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "replay",
            "replay_id": self._replay_id,
            "network_access": False,
        }

    def generate(self, request: Mapping[str, Any]) -> BackendResult:
        request_id = _nonempty_string(request.get("request_id"), "request_id")
        if request_id not in self._responses:
            raise HarnessError(f"replay 응답이 없습니다: {request_id}")
        return BackendResult(raw_text=self._responses[request_id], usage={})

class MirageCachedRetrievalBackend:
    """Read MIRAGE's local ranked IDs/scores without loading the 110GB payloads."""

    def __init__(
        self,
        source_root: Path,
        *,
        corpus: str,
        retriever: str,
        top_k: int,
    ) -> None:
        if top_k <= 0 or top_k > 10_000:
            raise HarnessError("MIRAGE top_k는 1~10000이어야 합니다.")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", corpus) or not re.fullmatch(
            r"[A-Za-z0-9._-]+", retriever
        ):
            raise HarnessError("MIRAGE corpus/retriever 형식이 안전하지 않습니다.")
        self._source_root = source_root.resolve()
        self._corpus = corpus
        self._retriever = retriever
        self._top_k = top_k

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "mirage_cached_retrieval",
            "corpus": self._corpus,
            "retriever": self._retriever,
            "top_k": self._top_k,
            "network_access": False,
            "retrieval_id_mapping_applied": False,
        }

    def generate(self, request: Mapping[str, Any]) -> BackendResult:
        runtime = request.get("runtime")
        if not isinstance(runtime, dict):
            raise HarnessError("A3 request runtime 형식이 잘못되었습니다.")
        subset = _nonempty_string(runtime.get("subset"), "runtime.subset")
        artifact_key = _nonempty_string(
            runtime.get("retrieval_artifact_key"), "runtime.retrieval_artifact_key"
        )
        if not re.fullmatch(r"[A-Za-z0-9._-]+", subset) or not re.fullmatch(
            r"[A-Za-z0-9._-]+", artifact_key
        ):
            raise HarnessError("MIRAGE runtime locator 형식이 안전하지 않습니다.")
        leaf = (
            self._source_root
            / "retrieved_snippets_10k"
            / subset
            / self._corpus
            / self._retriever
        ).resolve()
        if not leaf.is_relative_to(self._source_root):
            raise HarnessError("MIRAGE locator가 source root 밖을 가리킵니다.")
        score_path = leaf / "scores" / f"{artifact_key}.json"
        snippet_path = leaf / "snippets" / f"{artifact_key}.json"
        scores, snippets = _load_json(score_path), _load_json(snippet_path)
        if not isinstance(scores, list) or not isinstance(snippets, list):
            raise HarnessError("MIRAGE score/snippet 파일은 배열이어야 합니다.")
        if len(scores) != len(snippets):
            raise HarnessError("MIRAGE score와 snippet 수가 다릅니다.")
        selected_scores = scores[: self._top_k]
        selected_ids: list[str] = []
        for index, snippet in enumerate(snippets[: self._top_k]):
            if not isinstance(snippet, dict) or not isinstance(snippet.get("id"), str):
                raise HarnessError(f"MIRAGE snippet ID 형식 오류: {snippet_path}:{index}")
            selected_ids.append(snippet["id"])
        raw = json.dumps(
            {
                "ranked_document_ids": selected_ids,
                "ranked_scores": selected_scores,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        )
        return BackendResult(
            raw_text=raw,
            usage={
                "retrieved_count": len(selected_ids),
                "score_file_sha256": _sha256_file(score_path),
                "snippet_file_sha256": _sha256_file(snippet_path),
            },
        )

class TransformersLocalBackend:
    """Optional fully-local Transformers backend; imports dependencies lazily."""

    def __init__(
        self,
        model_path: Path,
        *,
        max_new_tokens: int = 512,
        temperature: float = 0.0,
        device_map: str = "auto",
    ) -> None:
        try:
            import torch  # type: ignore[import-not-found]
            from transformers import (  # type: ignore[import-not-found]
                AutoModelForImageTextToText,
                AutoProcessor,
            )
        except ImportError as exc:
            raise HarnessError(
                "transformers backend에는 torch와 최신 transformers가 필요합니다. "
                "현재 원본 4B 모델은 8GB GPU용 양자화도 아직 준비되지 않았습니다."
            ) from exc
        if max_new_tokens <= 0:
            raise HarnessError("max_new_tokens는 양수여야 합니다.")
        if temperature < 0:
            raise HarnessError("temperature는 0 이상이어야 합니다.")
        self._torch = torch
        self._processor = AutoProcessor.from_pretrained(
            str(model_path), local_files_only=True
        )
        self._model = AutoModelForImageTextToText.from_pretrained(
            str(model_path),
            local_files_only=True,
            torch_dtype="auto",
            device_map=device_map,
        )
        self._model.eval()
        self._model_path = model_path.resolve()
        self._max_new_tokens = max_new_tokens
        self._temperature = temperature
        self._device_map = device_map

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "transformers_local",
            "model_path": self._model_path.as_posix(),
            "config_sha256": _sha256_file(self._model_path / "config.json"),
            "max_new_tokens": self._max_new_tokens,
            "temperature": self._temperature,
            "device_map": self._device_map,
            "network_access": False,
            "local_files_only": True,
        }

    def generate(self, request: Mapping[str, Any]) -> BackendResult:
        messages = request.get("messages")
        if not isinstance(messages, list):
            raise HarnessError("request messages 형식이 잘못되었습니다.")
        prompt = self._processor.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        inputs = self._processor(text=[prompt], return_tensors="pt")
        device = next(self._model.parameters()).device
        inputs = {key: value.to(device) for key, value in inputs.items()}
        generation_kwargs: dict[str, Any] = {
            "max_new_tokens": self._max_new_tokens,
            "do_sample": self._temperature > 0,
        }
        if self._temperature > 0:
            generation_kwargs["temperature"] = self._temperature
        with self._torch.inference_mode():
            generated = self._model.generate(**inputs, **generation_kwargs)
        prompt_length = inputs["input_ids"].shape[1]
        decoded = self._processor.batch_decode(
            generated[:, prompt_length:], skip_special_tokens=True
        )[0]
        return BackendResult(
            raw_text=decoded,
            usage={
                "input_tokens": int(prompt_length),
                "output_tokens": int(generated.shape[1] - prompt_length),
            },
        )
