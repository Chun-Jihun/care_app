import 'dart:math';
import 'dart:typed_data';

import '../domain/visit_recording.dart';

/// Commits one second of PCM at a time and retains only an unfinished block.
final class VisitAudioBuffer {
  VisitAudioBuffer(this._commit);

  final void Function(Uint8List pcm) _commit;
  final _pcm = Uint8List(VisitRecording.bytesPerSecond);
  int _used = 0, _saved = 0;
  bool _closed = false;

  bool get full => _saved == VisitRecording.maxBytes;

  void add(Uint8List bytes) {
    var offset = 0;
    while (!_closed && !full && offset < bytes.length) {
      final count = min(_pcm.length - _used, bytes.length - offset);
      _pcm.setRange(_used, _used + count, bytes, offset);
      offset += count;
      _used += count;
      if (_used == _pcm.length) _flush(_used);
    }
  }

  void finish({bool saveTail = true}) {
    if (_closed) return;
    _closed = true;
    try {
      final completeSamples = _used & ~1;
      if (saveTail && completeSamples > 0) _flush(completeSamples);
    } finally {
      _pcm.fillRange(0, _pcm.length, 0);
      _used = 0;
    }
  }

  void _flush(int length) {
    _commit(Uint8List.sublistView(_pcm, 0, length));
    _saved += length;
    _used = 0;
  }
}
