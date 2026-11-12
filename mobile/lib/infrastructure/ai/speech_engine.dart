import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../domain/ai.dart';

Future<T> runSpeechWorker<T>(
  Map<String, String> paths,
  String language,
  Future<T> Function(SpeechTranscriber) use,
) async {
  final responses = ReceivePort();
  final messages = StreamIterator<Object?>(responses);
  SendPort? worker;
  Future<Object> receive() async {
    if (await messages.moveNext() && messages.current != null) {
      return messages.current!;
    }
    worker = null; // The exit notification has already been consumed.
    throw const AiException(AiFailure.failed);
  }

  try {
    await Isolate.spawn(_speechWorker, (
      responses.sendPort,
      paths,
      language,
    ), onExit: responses.sendPort);
    final ready = await receive();
    if (ready is! SendPort) throw const AiException(AiFailure.failed);
    worker = ready;
    return await use((samples) async {
      final result = receive();
      ready.send(samples);
      return switch (await result) {
        String text => text,
        AiFailure failure => throw AiException(failure),
        _ => throw const AiException(AiFailure.failed),
      };
    });
  } finally {
    if (worker case final SendPort port) {
      port.send(null);
      // Do not kill the isolate while native code owns the models.
      await messages.moveNext();
    }
    responses.close();
    await messages.cancel();
  }
}

void _speechWorker((SendPort, Map<String, String>, String) args) async {
  final (responses, paths, language) = args;
  final requests = ReceivePort();
  final speech = _LocalSpeech(paths, language);
  try {
    responses.send(requests.sendPort);
    await for (final samples in requests.cast<Float32List?>()) {
      if (samples == null) break;
      Object result;
      try {
        result = speech.transcribe(samples);
      } on AiException catch (error) {
        result = error.code;
      } on Object {
        result = AiFailure.failed;
      } finally {
        samples.fillRange(0, samples.length, 0);
      }
      responses.send(result);
      if (result == AiFailure.failed) break;
    }
  } finally {
    requests.close();
    speech.dispose();
  }
}

final class _LocalSpeech {
  _LocalSpeech(this.paths, this.language);
  final Map<String, String> paths;
  final String language;
  sherpa.VoiceActivityDetector? _vad;
  sherpa.OfflineRecognizer? _recognizer;

  sherpa.VoiceActivityDetector _openVad() {
    sherpa.initBindings();
    return sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: paths['vad']!,
          threshold: .5,
          minSpeechDuration: .25,
          minSilenceDuration: .5,
          maxSpeechDuration: 30,
        ),
        numThreads: 2,
        debug: false,
      ),
      bufferSizeInSeconds: 31,
    );
  }

  sherpa.OfflineRecognizer _openRecognizer() => sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: paths['encoder']!,
          decoder: paths['decoder']!,
          language: language.startsWith('zh') ? 'zh' : language,
          task: 'transcribe',
        ),
        tokens: paths['tokens']!,
        modelType: 'whisper',
        numThreads: 2,
        debug: false,
      ),
    ),
  );

  String transcribe(Float32List samples) {
    if (samples.isEmpty ||
        samples.length > 16000 * 30 ||
        samples.any((v) => !v.isFinite || v.abs() > 1)) {
      throw const AiException(AiFailure.invalidInput);
    }
    final vad = _vad ??= _openVad();
    try {
      vad.acceptWaveform(samples);
      vad.flush();
      if (vad.isEmpty()) throw const AiException(AiFailure.noSpeech);
    } finally {
      vad.reset();
    }

    final recognizer = _recognizer ??= _openRecognizer();
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      if (text.isEmpty) throw const AiException(AiFailure.noSpeech);
      if (text.length > 20000) throw const AiException(AiFailure.failed);
      return text;
    } finally {
      stream.free();
    }
  }

  void dispose() {
    try {
      _recognizer?.free();
    } finally {
      _vad?.free();
    }
  }
}
