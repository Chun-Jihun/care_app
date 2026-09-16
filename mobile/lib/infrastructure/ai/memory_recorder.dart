import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../../domain/ai.dart';

/// PCM exists only in a bounded memory buffer. No recorder file path is used.
final class MemoryRecorder implements MicrophoneCapture {
  final _recorder = AudioRecorder();
  final _buffer = Uint8List(16000 * 30 * 2);
  StreamSubscription<Uint8List>? _subscription;
  int _length = 0;
  bool _closed = false;
  bool _failed = false, _notified = false;
  @override
  Future<void> start(void Function() full) async {
    if (!await _recorder.hasPermission()) {
      throw const AiException(AiFailure.microphoneDenied);
    }
    if (_closed) return;
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );
    if (_closed) {
      await _recorder.cancel();
      return;
    }
    _subscription = stream.listen(
      (bytes) {
        final count = bytes.length.clamp(0, _buffer.length - _length);
        _buffer.setRange(_length, _length + count, bytes);
        _length += count;
        if (_length == _buffer.length && !_notified) {
          _notified = true;
          full();
        }
      },
      onError: (Object _) {
        _failed = true;
        if (!_notified) {
          _notified = true;
          full();
        }
      },
    );
  }

  @override
  Future<Float32List> stop() async {
    await _recorder.stop();
    await _subscription?.cancel();
    if (_failed) {
      _buffer.fillRange(0, _buffer.length, 0);
      _length = 0;
      throw const AiException(AiFailure.failed);
    }
    final data = ByteData.sublistView(_buffer),
        samples = Float32List(_length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    _buffer.fillRange(0, _buffer.length, 0);
    _length = 0;
    return samples;
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    try {
      await _subscription?.cancel();
      try {
        await _recorder.cancel();
      } finally {
        await _recorder.dispose();
      }
    } finally {
      _buffer.fillRange(0, _buffer.length, 0);
      _length = 0;
    }
  }
}
