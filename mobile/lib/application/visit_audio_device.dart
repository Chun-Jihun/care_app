import 'dart:typed_data';

abstract interface class VisitAudioDevice {
  Future<bool> requestPermission();
  Future<Stream<Uint8List>> start(void Function() interrupted);
  Future<void> stop();
  Future<void> keepScreenOn(bool enabled);
  Future<void> startPlayback();
  Future<int> writePlayback(Uint8List bytes, int offset);
  Future<bool> playbackDrained();
  Future<void> stopPlayback();
  Future<void> dispose();
}
