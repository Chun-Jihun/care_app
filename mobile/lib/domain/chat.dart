import 'ai.dart';

enum ChatRetention {
  session('session', '이번 앱 사용 동안만', null),
  week('7d', '7일', 7),
  month('30d', '30일', 30),
  forever('forever', '직접 삭제할 때까지', null);

  const ChatRetention(this.code, this.label, this.days);
  final String code, label;
  final int? days;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.patientId,
    required this.text,
    required this.createdAt,
    this.reply,
  });
  final String id, patientId, text;
  final DateTime createdAt;
  final AiReply? reply;
  ChatMessage withReply(AiReply value) => ChatMessage(
    id: id,
    patientId: patientId,
    text: text,
    createdAt: createdAt,
    reply: value,
  );
}
