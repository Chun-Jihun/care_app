import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/ai.dart';
import '../../domain/errors.dart';
import '../../domain/medical_evidence.dart';
import '../platform_services.dart';
import 'model_store.dart';
import 'chat_engine.dart';
import 'ocr_engine.dart';
import 'speech_engine.dart';

final class DeviceAiRuntime implements LocalAiRuntime, EvidenceSelector {
  // The pinned iOS Sherpa framework hides OrtGetApiBase. Keep AI disabled
  // there until an OCR C-API bridge is linked and verified on a Mac/device.
  bool get _supported =>
      Abi.current() == Abi.androidArm64 ||
      (kDebugMode && Abi.current() == Abi.androidX64);
  Future<ModelStore>? _storeFuture;
  final _chat = LocalChatEngine();
  bool _busy = false, _disposed = false;
  int _generation = 0;
  Completer<void>? _cancelSignal;
  String? _pickedPath;
  Future<ModelStore> get _store => _storeFuture ??= _prepare();
  Future<ModelStore> _prepare() async {
    final root = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'ai_models'),
    );
    await root.create(recursive: true);
    if (Platform.isIOS) {
      await const MethodChannel('org.carenotebook/privacy')
          .invokeMethod<void>('protectDirectory', {'path': root.path});
    }
    final data = await rootBundle.load('assets/ai/manifest.json');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return ModelStore(root, bytes);
  }

  @override
  Future<AiModelStatus> status() async {
    if (!_supported) {
      return const AiModelStatus(supported: false);
    }
    try {
      final store = await _store;
      return AiModelStatus(
        installed: await store.installed(),
        version: store.manifest['version'] as String,
        bytes: store.payloadBytes,
      );
    } on Object {
      return const AiModelStatus();
    }
  }

  @override
  Future<String?> pickBundle() async {
    if (_busy || _pickedPath != null) throw const AiException(AiFailure.busy);
    final epoch = _generation;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final store = await _store;
      _check(epoch);
      try {
        _pickedPath = await DevicePlatformServices.pickBoundedDocument(
          maxBytes: store.bundleBytes,
          installBytes: store.payloadBytes,
        );
      } on PlatformException catch (error) {
        throw AiException(
          error.code == 'documentTooLarge'
              ? AiFailure.modelInvalid
              : AiFailure.failed,
        );
      }
    } else {
      _pickedPath = (await FilePicker.pickFile())?.path;
    }
    if (_disposed || epoch != _generation) {
      await _clearPickedCache();
      throw const AiException(AiFailure.cancelled);
    }
    return _pickedPath;
  }

  Future<void> _clearPickedCache() async {
    final path = _pickedPath;
    _pickedPath = null;
    if (path != null) await DevicePlatformServices.discardPickedDocument(path);
  }

  @override
  Future<void> installBundle(
    String path,
    void Function(double) progress,
  ) async {
    final picked = _pickedPath == path;
    if (picked) _pickedPath = null;
    if (_disposed || !_supported || _busy) {
      if (picked) await DevicePlatformServices.discardPickedDocument(path);
      throw AiException(_busy ? AiFailure.busy : AiFailure.unavailable);
    }
    return _run((epoch) async {
      try {
        await (await _store).install(path, progress, () => _check(epoch));
      } finally {
        if (picked) await DevicePlatformServices.discardPickedDocument(path);
      }
    }, timeout: const Duration(minutes: 10));
  }

  @override
  Future<void> removeModels() => _run((epoch) async {
    final store = await _store;
    _check(epoch);
    await store.remove();
  }, timeout: const Duration(minutes: 10));
  void _check(int epoch) {
    if (_disposed || epoch != _generation) {
      throw const AiException(AiFailure.cancelled);
    }
  }

  Future<T> _run<T>(
    Future<T> Function(int) action, {
    Duration? timeout = const Duration(seconds: 90),
  }) async {
    if (_disposed || !_supported) {
      throw const AiException(AiFailure.unavailable);
    }
    if (_busy) throw const AiException(AiFailure.busy);
    _busy = true;
    final epoch = _generation;
    final signal = Completer<void>();
    _cancelSignal = signal;
    // Busy remains true until the native work releases resources, even if the
    // UI times out. Killing an isolate during FFI would leak its native model.
    final work = Future<T>(() => action(epoch)).whenComplete(() {
      _busy = false;
      if (identical(_cancelSignal, signal)) _cancelSignal = null;
    });
    try {
      final outcome = Future.any<T>([
        work,
        signal.future.then<T>(
          (_) => throw const AiException(AiFailure.cancelled),
        ),
      ]);
      final value = await (timeout == null
          ? outcome
          : outcome.timeout(
              timeout,
              onTimeout: () {
                cancel();
                throw const AiException(AiFailure.cancelled);
              },
            ));
      _check(epoch);
      return value;
    } on AiException {
      rethrow;
    } on CareError {
      rethrow;
    } on Object {
      throw const AiException(AiFailure.failed);
    }
  }

  Future<ModelStore> _ready(int epoch, List<String> names) async {
    final store = await _store;
    await store.verify(names: names);
    _check(epoch);
    return store;
  }

  @override
  Future<String> extractQuery(String question, String language) => _run((
    epoch,
  ) async {
    final store = await _ready(epoch, ['chat/model.gguf', 'chat/prompt.json']);
    return _chat.extract(
      store.path('chat/model.gguf'),
      store.path('chat/prompt.json'),
      question,
    );
  });
  @override
  Future<String> selectEvidence(
    String question,
    List<ReviewedPassage> passages,
  ) => _run((epoch) async {
    final store = await _ready(epoch, ['chat/model.gguf']);
    return _chat.selectEvidence(
      store.path('chat/model.gguf'),
      question,
      passages,
    );
  });

  @override
  Future<OcrDraft> recognize(Uint8List image, String language) =>
      _run((epoch) async {
        final kind = language == 'ko' ? 'ko' : 'multi';
        final store = await _ready(epoch, [
          'ocr/detector.onnx',
          'ocr/$kind.onnx',
          'ocr/$kind.json',
        ]);
        final detector = store.path('ocr/detector.onnx'),
            recognizer = store.path('ocr/$kind.onnx'),
            dictionary = store.path('ocr/$kind.json');
        return runOcrWorker(detector, recognizer, dictionary, image);
      });
  @override
  Future<String> transcribe(Float32List samples, String language) => _run(
    (epoch) => _useSpeechWorker(epoch, language, (decode) => decode(samples)),
  );

  @override
  Future<T> withTranscriber<T>(
    String language,
    Future<T> Function(SpeechTranscriber) use,
  ) => _run((epoch) => _useSpeechWorker(epoch, language, use), timeout: null);

  Future<T> _useSpeechWorker<T>(
    int epoch,
    String language,
    Future<T> Function(SpeechTranscriber) use,
  ) async {
    final store = await _speechStep(
      epoch,
      () => _ready(epoch, [
        'speech/encoder.onnx',
        'speech/decoder.onnx',
        'speech/tokens.txt',
        'speech/vad.onnx',
      ]),
    );
    final paths = {
      'encoder': store.path('speech/encoder.onnx'),
      'decoder': store.path('speech/decoder.onnx'),
      'tokens': store.path('speech/tokens.txt'),
      'vad': store.path('speech/vad.onnx'),
    };
    return runSpeechWorker(
      paths,
      language,
      (decode) => use((samples) => _speechStep(epoch, () => decode(samples))),
    );
  }

  Future<T> _speechStep<T>(int epoch, Future<T> Function() step) async {
    _check(epoch);
    // Time out the caller while letting the isolate finish its native call.
    final timer = Timer(const Duration(seconds: 90), () {
      if (epoch == _generation) cancel();
    });
    try {
      return await step();
    } finally {
      timer.cancel();
      _check(epoch);
    }
  }

  @override
  void cancel() {
    _generation++;
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    _chat.cancel();
    if (!_busy) unawaited(_clearPickedCache());
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    cancel();
  }
}

// Top-level boundaries keep isolate closures from capturing the runtime's
// completers, platform channels or other unsendable parent-scope objects.
Future<OcrDraft> runOcrWorker(
  String detector,
  String recognizer,
  String dictionary,
  Uint8List image,
) => Isolate.run(() => recognizeLocal(detector, recognizer, dictionary, image));
