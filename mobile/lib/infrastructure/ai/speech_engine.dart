import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../domain/ai.dart';

/// Runs in a worker isolate; all native resources are freed before completion.
String transcribeLocal(
  Map<String, String> paths,
  Float32List samples,
  String language,
) {
  sherpa.initBindings();
  if (samples.isEmpty ||
      samples.length > 16000 * 30 ||
      samples.any((v) => !v.isFinite || v.abs() > 1)) {
    throw const AiException(AiFailure.invalidInput);
  }
  final vad = sherpa.VoiceActivityDetector(
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
  try {
    vad.acceptWaveform(samples);
    vad.flush();
    if (vad.isEmpty()) throw const AiException(AiFailure.noSpeech);
  } finally {
    vad.free();
  }
  final recognizer = sherpa.OfflineRecognizer(
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
  try {
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
  } finally {
    recognizer.free();
  }
}
