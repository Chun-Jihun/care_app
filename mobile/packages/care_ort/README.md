# One native ONNX Runtime

This local package does **not** bundle a native library or register a Flutter
plugin. `sherpa_onnx` supplies the single ONNX Runtime used by speech and OCR.
The Android binary currently reports 1.28.2. This avoids conflicting Android
shared libraries on Android.

The pinned iOS Sherpa framework does not export `OrtGetApiBase` (verified from
its arm64 symbol table). The app therefore disables AI on iOS for this iteration.
An iOS OCR C-API bridge/framework and a Mac build/device test are required;
`DynamicLibrary.process()` alone cannot access the hidden ORT implementation.

The generated C API bindings come from the MIT-licensed
[`onnxruntime` 1.4.1](https://github.com/gtbluesky/onnxruntime_flutter) Pub archive.
Only the final modifiers required by Dart 3 were added to Struct/Opaque classes; the C API layout is unchanged.
Its source archive digest is recorded in `experiments/mobile_ai_v1/ort-bindings.lock.json`.
The high-level wrapper is local: only single-input/single-output FP32 inference,
bounded output copies, CPU threads, and deterministic native cleanup are exposed.
API 14 is requested through ONNX Runtime's versioned C API; no struct offsets
or runtime-version-specific symbol guesses are used.

When updating sherpa, re-run Android native OCR/speech tests and review iOS exports.
Generated bindings are kept separate from handwritten application code.
