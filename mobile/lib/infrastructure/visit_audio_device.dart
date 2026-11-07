import 'dart:async';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../application/visit_audio_device.dart';
import '../domain/visit_recording.dart';

final class AndroidVisitAudioDevice implements VisitAudioDevice {
  static const _channel = MethodChannel('org.carenotebook/visit_audio');
  final _recorder = AudioRecorder();
  StreamSubscription<RecordState>? _states;

  @override
  Future<bool> requestPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start(void Function() interrupted) async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: VisitRecording.sampleRate,
        numChannels: 1,
      ),
    );
    _states = _recorder.onStateChanged().listen((state) {
      if (state != RecordState.record) interrupted();
    }, onError: (Object _) => interrupted());
    return stream;
  }

  @override
  Future<void> stop() async {
    await _states?.cancel();
    _states = null;
    await _recorder.stop();
  }

  @override
  Future<void> keepScreenOn(bool enabled) =>
      _channel.invokeMethod<void>('keepScreenOn', enabled);

  @override
  Future<void> startPlayback() => _channel.invokeMethod<void>('startPlayback');

  @override
  Future<int> writePlayback(Uint8List bytes, int offset) async =>
      (await _channel.invokeMethod<int>('writePlayback', {
        'pcm': bytes,
        'offset': offset,
      }))!;

  @override
  Future<bool> playbackDrained() async =>
      (await _channel.invokeMethod<bool>('playbackDrained'))!;

  @override
  Future<void> stopPlayback() => _channel.invokeMethod<void>('stopPlayback');

  @override
  Future<void> dispose() async {
    await _states?.cancel();
    await _recorder.dispose();
  }
}
