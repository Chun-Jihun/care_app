"""Offline replay and lock-verified local model runtimes."""
from __future__ import annotations

import hashlib
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import platform
import time
from typing import Any, Mapping, Sequence

try:
    from scripts.ds_agent_model_contracts import (
        ModelGeneration,
        ModelRunnerError,
        ROLE_SCHEMAS,
    )
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    from ds_agent_model_contracts import (
        ModelGeneration,
        ModelRunnerError,
        ROLE_SCHEMAS,
    )


class ReplayRoleBackend:
    """Offline backend for replaying previously captured role JSON outputs."""

    def __init__(self, rows: Sequence[Mapping[str, Any]], *, source_sha256: str) -> None:
        self._responses: dict[tuple[str, str, int], ModelGeneration] = {}
        for row in rows:
            item_id = row.get("item_id")
            role_id = row.get("role_id")
            call_index = row.get("call_index")
            if (
                not isinstance(item_id, str)
                or not item_id
                or role_id not in ROLE_SCHEMAS
                or isinstance(call_index, bool)
                or not isinstance(call_index, int)
                or call_index < 1
            ):
                raise ModelRunnerError(
                    "replay rows require item_id, A1--A5 role_id and positive call_index"
                )
            key = (item_id, str(role_id), call_index)
            raw_text = row.get("raw_text")
            if not isinstance(raw_text, str) or key in self._responses:
                raise ModelRunnerError("replay rows require unique item_id/role_id/call_index")
            usage = row.get("usage", {})
            self._responses[key] = ModelGeneration(
                raw_text=raw_text,
                usage=dict(usage) if isinstance(usage, Mapping) else {},
            )
        self._source_sha256 = source_sha256

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "replay_role_outputs",
            "source_sha256": self._source_sha256,
            "network_access": False,
        }

    def generate(self, request: Mapping[str, Any]) -> ModelGeneration:
        key = (
            str(request.get("item_id")),
            str(request.get("role_id")),
            int(request.get("call_index", 0)),
        )
        try:
            return self._responses[key]
        except KeyError as exc:
            raise ModelRunnerError(f"replay response not found: {key}") from exc

def _load_runtime_profile(path: Path, profile_id: str) -> tuple[dict[str, Any], str]:
    try:
        raw = path.read_bytes()
        document = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ModelRunnerError(f"cannot read runtime profile: {path}") from exc
    profiles = document.get("profiles") if isinstance(document, dict) else None
    if not isinstance(profiles, list):
        raise ModelRunnerError("runtime profile document is invalid")
    matches = [value for value in profiles if isinstance(value, dict) and value.get("id") == profile_id]
    if len(matches) != 1:
        raise ModelRunnerError(f"runtime profile ID must match exactly once: {profile_id}")
    defaults = document.get("defaults", {})
    if not isinstance(defaults, Mapping):
        raise ModelRunnerError("runtime profile defaults must be an object")

    def merge(base: Mapping[str, Any], override: Mapping[str, Any]) -> dict[str, Any]:
        result = dict(base)
        for key, value in override.items():
            if isinstance(value, Mapping) and isinstance(result.get(key), Mapping):
                result[key] = merge(result[key], value)  # type: ignore[arg-type]
            else:
                result[key] = value
        return result

    profile_value = merge(defaults, matches[0])
    if profile_value.get("decision_status") != "accepted_for_initial_desktop_evaluation":
        raise ModelRunnerError("runtime profile is not accepted")
    policy = profile_value.get("policy")
    if not isinstance(policy, dict) or not (
        policy.get("local_files_only") is True
        and policy.get("network_access") is False
        and policy.get("trust_remote_code") is False
        and policy.get("cpu_or_disk_offload") is False
        and policy.get("automatic_precision_fallback") is False
    ):
        raise ModelRunnerError("runtime profile does not fail closed")
    return profile_value, hashlib.sha256(raw).hexdigest()

def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def _verify_locked_model(root: Path, profile: Mapping[str, Any]) -> tuple[Path, str]:
    model = profile.get("model")
    if not isinstance(model, Mapping):
        raise ModelRunnerError("runtime profile model metadata is invalid")
    lock_path = (root / Path(str(model.get("model_lock_path", "")))).resolve()
    if not lock_path.is_relative_to(root) or not lock_path.is_file():
        raise ModelRunnerError("model lock is missing or unsafe")
    actual_lock_hash = _file_sha256(lock_path)
    if actual_lock_hash != model.get("model_lock_sha256"):
        raise ModelRunnerError("model lock hash does not match the runtime profile")
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ModelRunnerError("model lock cannot be read") from exc
    candidates = [
        value
        for value in lock.get("models", [])
        if isinstance(value, Mapping) and value.get("id") == model.get("asset_id")
    ] if isinstance(lock, Mapping) else []
    if len(candidates) != 1:
        raise ModelRunnerError("runtime model must match exactly one model lock entry")
    locked = candidates[0]
    for profile_field, lock_field in (
        ("repository_id", "repository_id"),
        ("revision", "revision"),
        ("local_path", "local_path"),
    ):
        if model.get(profile_field) != locked.get(lock_field):
            raise ModelRunnerError(f"model lock identity mismatch: {profile_field}")
    model_path = (root / Path(str(model["local_path"]))).resolve()
    if not model_path.is_relative_to(root) or not model_path.is_dir():
        raise ModelRunnerError("locked local model path is missing or unsafe")
    files = locked.get("files")
    if not isinstance(files, list) or not files:
        raise ModelRunnerError("model lock file inventory is empty")
    seen: set[str] = set()
    total_bytes = 0
    for file_entry in files:
        if not isinstance(file_entry, Mapping) or not isinstance(file_entry.get("path"), str):
            raise ModelRunnerError("model lock file entry is invalid")
        relative = Path(str(file_entry["path"]))
        if relative.is_absolute() or ".." in relative.parts or relative.as_posix() in seen:
            raise ModelRunnerError("model lock contains an unsafe or duplicate path")
        seen.add(relative.as_posix())
        asset = (model_path / relative).resolve()
        if not asset.is_relative_to(model_path) or not asset.is_file():
            raise ModelRunnerError(f"locked model file is missing: {relative.as_posix()}")
        size = asset.stat().st_size
        if size != file_entry.get("bytes"):
            raise ModelRunnerError(f"locked model file size changed: {relative.as_posix()}")
        if _file_sha256(asset) != file_entry.get("sha256"):
            raise ModelRunnerError(f"locked model file hash changed: {relative.as_posix()}")
        total_bytes += size
    integrity = locked.get("integrity")
    if not isinstance(integrity, Mapping) or (
        integrity.get("file_count") != len(files)
        or integrity.get("total_bytes") != total_bytes
    ):
        raise ModelRunnerError("model lock aggregate integrity metadata is invalid")
    excluded_directories = set(str(value) for value in integrity.get("excluded_directory_names", []))
    excluded_files = set(str(value) for value in integrity.get("excluded_file_names", []))
    actual_files = {
        path.relative_to(model_path).as_posix()
        for path in model_path.rglob("*")
        if path.is_file()
        and not any(part in excluded_directories for part in path.relative_to(model_path).parts[:-1])
        and path.name not in excluded_files
    }
    if actual_files != seen:
        raise ModelRunnerError("model directory inventory differs from the model lock")
    return model_path, actual_lock_hash

class LockedTransformersNf4Backend:
    """Fully-local, lock-verified NF4 backend for an allowlisted model profile."""

    def __init__(
        self,
        workspace_root: Path,
        runtime_profile_path: Path,
        *,
        profile_id: str,
        generation_profile: str = "primary_scored",
        seed: int | None = None,
    ) -> None:
        root = workspace_root.resolve()
        profile_path = runtime_profile_path.resolve()
        if not profile_path.is_relative_to(root):
            raise ModelRunnerError("runtime profile must be inside the workspace")
        profile_value, profile_hash = _load_runtime_profile(profile_path, profile_id)
        runtime = profile_value["runtime"]
        quant = profile_value["quantization"]
        generation_profiles = profile_value["generation"]
        if generation_profile not in generation_profiles or not isinstance(
            generation_profiles[generation_profile], dict
        ):
            raise ModelRunnerError(f"unsupported generation profile: {generation_profile}")
        generation = dict(generation_profiles[generation_profile])
        if generation_profile == "supplier_recommended_secondary":
            seeds = generation.get("seed_set", [])
            if seed not in seeds:
                raise ModelRunnerError("supplier sampling requires one pre-registered seed")
        elif seed is not None:
            raise ModelRunnerError("deterministic generation profiles do not accept a seed")
        if platform.system() != "Windows" or platform.machine().lower() not in {
            "amd64",
            "x86_64",
        }:
            raise ModelRunnerError("selected runtime requires Windows x86-64")
        if ".".join(platform.python_version_tuple()[:2]) != runtime["python"]:
            raise ModelRunnerError(
                f"Python {runtime['python']} is required; found {platform.python_version()}"
            )
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        try:
            import torch  # type: ignore[import-not-found]
            from transformers import (  # type: ignore[import-not-found]
                AutoModelForCausalLM,
                AutoModelForMultimodalLM,
                AutoProcessor,
                AutoTokenizer,
                BitsAndBytesConfig,
                Qwen3_5ForConditionalGeneration,
            )
        except ImportError as exc:
            raise ModelRunnerError("selected Transformers NF4 runtime packages are not installed") from exc
        try:
            installed = {
                name: importlib.metadata.version(name)
                for name in (
                    "torch",
                    "torchvision",
                    "transformers",
                    "accelerate",
                    "bitsandbytes",
                    "pillow",
                )
            }
        except importlib.metadata.PackageNotFoundError as exc:
            raise ModelRunnerError(
                f"selected runtime package is missing: {exc.name}"
            ) from exc
        for name, required in runtime["packages"].items():
            if installed.get(name) != required:
                raise ModelRunnerError(
                    f"runtime package mismatch: {name}={installed.get(name)} != {required}"
                )
        loader = profile_value.get("loader")
        if not isinstance(loader, Mapping):
            # Backward-compatible interpretation of the immutable M1 profile.
            loader = {
                "frontend_class": "AutoProcessor",
                "model_class": "Qwen3_5ForConditionalGeneration",
                "output_adapter": "plain_json",
                "frontend_kwargs": {},
            }
        frontend_name = loader.get("frontend_class")
        model_class_name = loader.get("model_class")
        frontends = {
            "AutoProcessor": AutoProcessor,
            "AutoTokenizer": AutoTokenizer,
        }
        model_classes = {
            "AutoModelForCausalLM": AutoModelForCausalLM,
            "AutoModelForMultimodalLM": AutoModelForMultimodalLM,
            "Qwen3_5ForConditionalGeneration": Qwen3_5ForConditionalGeneration,
        }
        if frontend_name not in frontends or model_class_name not in model_classes:
            raise ModelRunnerError("runtime profile loader class is not allowlisted")
        if model_class_name == "Qwen3_5ForConditionalGeneration":
            if runtime.get("linear_attention_kernel") != "pytorch_reference":
                raise ModelRunnerError("linear-attention kernel choice is not fixed")
            if any(
                importlib.util.find_spec(name) is not None
                for name in ("fla", "causal_conv1d")
            ):
                raise ModelRunnerError(
                    "optional linear-attention kernels are installed but not allowed by this profile"
                )
        if not torch.cuda.is_available() or not torch.cuda.is_bf16_supported():
            raise ModelRunnerError("CUDA and native BF16 support are required")
        model_path, model_lock_hash = _verify_locked_model(root, profile_value)
        config_path = model_path / "config.json"
        if _file_sha256(config_path) != profile_value["model"]["config_sha256"]:
            raise ModelRunnerError("model config hash does not match the runtime profile")
        quantization_config = BitsAndBytesConfig(
            load_in_4bit=quant["weight_bits"] == 4,
            bnb_4bit_quant_type=quant["quant_type"],
            bnb_4bit_compute_dtype=torch.bfloat16,
            bnb_4bit_quant_storage=torch.uint8,
            bnb_4bit_use_double_quant=quant["double_quant"],
        )
        frontend_kwargs = loader.get("frontend_kwargs", {})
        if not isinstance(frontend_kwargs, Mapping):
            raise ModelRunnerError("runtime frontend kwargs must be an object")
        forbidden_frontend_kwargs = {"trust_remote_code", "local_files_only"}.intersection(
            frontend_kwargs
        )
        if forbidden_frontend_kwargs:
            raise ModelRunnerError("runtime frontend kwargs override a security policy")
        model_kwargs: dict[str, Any] = {
            "local_files_only": True,
            "trust_remote_code": False,
            "quantization_config": quantization_config,
            "dtype": torch.bfloat16,
            "device_map": runtime["device_map"],
        }
        if runtime.get("attention_implementation"):
            model_kwargs["attn_implementation"] = runtime["attention_implementation"]
        try:
            self._frontend = frontends[str(frontend_name)].from_pretrained(
                str(model_path),
                local_files_only=True,
                trust_remote_code=False,
                **dict(frontend_kwargs),
            )
            self._model = model_classes[str(model_class_name)].from_pretrained(
                str(model_path), **model_kwargs
            )
        except Exception as exc:
            raise ModelRunnerError(
                f"locked NF4 load failed without fallback: {type(exc).__name__}: {exc}"
            ) from exc
        self._model.eval()
        device_map = getattr(self._model, "hf_device_map", {})
        if isinstance(device_map, Mapping) and any(
            not str(device).startswith("cuda") and str(device) != "0"
            for device in device_map.values()
        ):
            raise ModelRunnerError("CPU or disk offload is forbidden by the runtime profile")
        parameter_devices = {str(parameter.device) for parameter in self._model.parameters()}
        if not parameter_devices or any(
            not device.startswith("cuda:0") for device in parameter_devices
        ):
            raise ModelRunnerError("all model parameters must be on cuda:0")
        self._torch = torch
        self._model_path = model_path
        self._profile_id = profile_id
        self._profile_hash = profile_hash
        self._model_lock_hash = model_lock_hash
        self._model_revision = str(profile_value["model"]["revision"])
        self._generation_name = generation_profile
        self._generation = generation
        self._seed = seed
        self._installed = installed
        self._frontend_name = str(frontend_name)
        self._model_class_name = str(model_class_name)
        self._output_adapter = str(loader.get("output_adapter", "plain_json"))
        if self._output_adapter not in {
            "plain_json",
            "strip_closed_think_prefix",
            "strip_medgemma_thought_prefix",
        }:
            raise ModelRunnerError("runtime output adapter is not allowlisted")
        self._message_adapter = str(loader.get("message_adapter", "plain"))
        if self._message_adapter not in {
            "plain",
            "merge_system_into_first_user",
            "merge_system_and_adjacent_users",
        }:
            raise ModelRunnerError("runtime message adapter is not allowlisted")
        chat_template_kwargs = generation_profiles.get("chat_template_kwargs", {})
        if not isinstance(chat_template_kwargs, Mapping):
            raise ModelRunnerError("chat template kwargs must be an object")
        self._chat_template_kwargs = dict(chat_template_kwargs)
        self._tokenize_add_special_tokens = bool(
            loader.get("tokenize_add_special_tokens", False)
        )
        properties = torch.cuda.get_device_properties(0)
        self._gpu = {
            "name": torch.cuda.get_device_name(0),
            "vram_mib": int(properties.total_memory // (1024 * 1024)),
            "compute_capability": f"{properties.major}.{properties.minor}",
        }

    @property
    def metadata(self) -> Mapping[str, Any]:
        return {
            "backend": "locked_transformers_bitsandbytes_nf4",
            "runtime_profile_id": self._profile_id,
            "runtime_profile_sha256": self._profile_hash,
            "model_lock_sha256": self._model_lock_hash,
            "model_revision": self._model_revision,
            "generation_profile": self._generation_name,
            "seed": self._seed,
            "packages": dict(self._installed),
            "gpu": dict(self._gpu),
            "model_path": self._model_path.as_posix(),
            "frontend_class": self._frontend_name,
            "model_class": self._model_class_name,
            "output_adapter": self._output_adapter,
            "message_adapter": self._message_adapter,
            "network_access": False,
            "local_files_only": True,
            "trust_remote_code": False,
        }

    def generate(self, request: Mapping[str, Any]) -> ModelGeneration:
        messages = request.get("messages")
        if not isinstance(messages, list):
            raise ModelRunnerError("backend request messages must be an array")
        adapted_messages = list(messages)
        if self._message_adapter in {
            "merge_system_into_first_user",
            "merge_system_and_adjacent_users",
        }:
            system_parts = [
                str(message.get("content"))
                for message in messages
                if isinstance(message, Mapping) and message.get("role") == "system"
            ]
            adapted_messages = [
                dict(message)
                for message in messages
                if isinstance(message, Mapping) and message.get("role") != "system"
            ]
            first_user = next(
                (
                    message
                    for message in adapted_messages
                    if message.get("role") == "user"
                    and isinstance(message.get("content"), str)
                ),
                None,
            )
            if first_user is None:
                raise ModelRunnerError("message adapter requires a text user message")
            if system_parts:
                first_user["content"] = (
                    "System constraints:\n"
                    + "\n".join(system_parts)
                    + "\n\nUser request:\n"
                    + str(first_user["content"])
                )
            if self._message_adapter == "merge_system_and_adjacent_users":
                merged_messages: list[dict[str, Any]] = []
                for message in adapted_messages:
                    if (
                        merged_messages
                        and message.get("role") == "user"
                        and merged_messages[-1].get("role") == "user"
                        and isinstance(message.get("content"), str)
                        and isinstance(merged_messages[-1].get("content"), str)
                    ):
                        merged_messages[-1]["content"] = (
                            str(merged_messages[-1]["content"])
                            + "\n\nAdditional format correction:\n"
                            + str(message["content"])
                        )
                    else:
                        merged_messages.append(dict(message))
                adapted_messages = merged_messages
        prompt = self._frontend.apply_chat_template(
            adapted_messages,
            tokenize=False,
            add_generation_prompt=True,
            **self._chat_template_kwargs,
        )
        if self._frontend_name == "AutoProcessor":
            inputs = self._frontend(text=[prompt], return_tensors="pt")
        else:
            inputs = self._frontend(
                [prompt],
                add_special_tokens=self._tokenize_add_special_tokens,
                return_tensors="pt",
            )
        input_tokens = int(inputs["input_ids"].shape[1])
        max_input = int(self._generation["max_input_tokens"])
        if input_tokens > max_input:
            raise ModelRunnerError(
                f"input context exceeds profile budget: {input_tokens} > {max_input}"
            )
        inputs = {key: value.to("cuda:0") for key, value in inputs.items()}
        kwargs: dict[str, Any] = {
            "max_new_tokens": int(self._generation["max_new_tokens"]),
            "do_sample": bool(self._generation["do_sample"]),
        }
        if kwargs["do_sample"]:
            for key in ("temperature", "top_p", "top_k", "min_p", "repetition_penalty"):
                if key in self._generation:
                    kwargs[key] = self._generation[key]
            assert self._seed is not None
            self._torch.manual_seed(self._seed)
            self._torch.cuda.manual_seed_all(self._seed)
        if "eos_token_id" in self._generation:
            kwargs["eos_token_id"] = int(self._generation["eos_token_id"])
        self._torch.cuda.reset_peak_memory_stats(0)
        started = time.perf_counter()
        with self._torch.inference_mode():
            generated = self._model.generate(**inputs, **kwargs)
        generation_seconds = time.perf_counter() - started
        output_tokens = int(generated.shape[1] - input_tokens)
        decoded = self._frontend.batch_decode(
            generated[:, input_tokens:], skip_special_tokens=True
        )[0]
        original_output_sha256 = hashlib.sha256(decoded.encode("utf-8")).hexdigest()
        output_adapter_applied = False
        if self._output_adapter == "strip_closed_think_prefix":
            stripped = decoded.lstrip()
            if stripped.startswith("<think>") and "</think>" in stripped:
                decoded = stripped.split("</think>", 1)[1].lstrip()
                output_adapter_applied = True
        elif self._output_adapter == "strip_medgemma_thought_prefix":
            if "<unused95>" in decoded:
                decoded = decoded.split("<unused95>", 1)[1].lstrip()
                output_adapter_applied = True
        return ModelGeneration(
            raw_text=decoded,
            usage={
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "peak_vram_bytes": int(self._torch.cuda.max_memory_allocated(0)),
                "generation_wall_time_ms": round(generation_seconds * 1000, 3),
                "output_tokens_per_second": (
                    round(output_tokens / generation_seconds, 6)
                    if generation_seconds > 0
                    else None
                ),
                "unprocessed_output_sha256": original_output_sha256,
                "output_adapter_applied": output_adapter_applied,
            },
        )

class Qwen35Nf4Backend(LockedTransformersNf4Backend):
    """Backward-compatible wrapper for the original immutable Qwen3.5 profile."""

    def __init__(
        self,
        workspace_root: Path,
        runtime_profile_path: Path,
        *,
        profile_id: str = "RT-M1-HF-BNB-NF4-WIN-001",
        generation_profile: str = "primary_scored",
        seed: int | None = None,
    ) -> None:
        super().__init__(
            workspace_root,
            runtime_profile_path,
            profile_id=profile_id,
            generation_profile=generation_profile,
            seed=seed,
        )
