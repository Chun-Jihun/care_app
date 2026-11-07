/// A recording belongs to one notebook. Keeping audio does not confirm a note.
final class VisitRecording {
  const VisitRecording(this.id, this.startedAt, this.byteCount, this.kept);

  static const sampleRate = 16000;
  static const bytesPerSecond = sampleRate * 2;
  static const maxSeconds = 30 * 60;
  static const maxBytes = bytesPerSecond * maxSeconds;

  final String id;
  final DateTime startedAt;
  final int byteCount;
  final bool kept;

  Duration get duration =>
      Duration(milliseconds: byteCount * 1000 ~/ bytesPerSecond);
}
