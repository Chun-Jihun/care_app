import '../../domain/records.dart';
import '../../domain/chat.dart';
import '../sqlite_session.dart';

final class SqliteChat {
  SqliteChat(this._store);
  final SqliteSession _store;

  ChatRetention? chatRetention(String pid) {
    _store.patient(pid);
    final value = _store.connection.select(
      'SELECT retention FROM chat_policy WHERE patient_id=?',
      [pid],
    ).firstOrNull?['retention'];
    return value == null
        ? null
        : ChatRetention.values.firstWhere((r) => r.code == value);
  }

  void setChatRetention(String pid, ChatRetention policy, {DateTime? now}) {
    _store.patient(pid);
    pruneChats(now: now);
    _store.transaction(() {
      _store.connection.execute(
        'INSERT INTO chat_policy VALUES(?,?) ON CONFLICT(patient_id) DO UPDATE SET retention=excluded.retention',
        [pid, policy.code],
      );
      if (policy == ChatRetention.session) {
        _store.connection.execute(
          'DELETE FROM chat_message WHERE patient_id=?',
          [pid],
        );
      } else if (policy.days == null) {
        _store.connection.execute(
          'UPDATE chat_message SET expires_at=NULL WHERE patient_id=?',
          [pid],
        );
      } else {
        _store.connection.execute(
          'UPDATE chat_message SET expires_at=created_at+? WHERE patient_id=?',
          [Duration(days: policy.days!).inMilliseconds, pid],
        );
      }
    });
    pruneChats(now: now);
  }

  void pruneChats({DateTime? now}) => _store.connection.execute(
    'DELETE FROM chat_message WHERE expires_at IS NOT NULL AND expires_at<=?',
    [(now ?? DateTime.now()).millisecondsSinceEpoch],
  );

  List<ChatMessage> chatMessages(String pid, {DateTime? now}) {
    _store.patient(pid);
    return _store.connection
        .select(
          'SELECT * FROM chat_message WHERE patient_id=? AND (expires_at IS NULL OR expires_at>?) ORDER BY created_at,id',
          [pid, (now ?? DateTime.now()).millisecondsSinceEpoch],
        )
        .map(
          (r) => ChatMessage(
            id: r['id'] as String,
            patientId: pid,
            text: r['text'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              r['created_at'] as int,
            ),
          ),
        )
        .toList();
  }

  ChatMessage addChatMessage(String pid, String text, {DateTime? now}) {
    final policy = chatRetention(pid);
    if (policy == null || policy == ChatRetention.session) {
      throw CareError(CareErrorCode.persistedChatRetentionRequired);
    }
    if (text.trim().isEmpty || text.length > 20000) {
      throw CareError(CareErrorCode.invalidQuestionLength);
    }
    final at = now ?? DateTime.now(), id = RecordIds.next();
    _store.connection.execute('INSERT INTO chat_message VALUES(?,?,?,?,?)', [
      id,
      pid,
      text.trim(),
      at.millisecondsSinceEpoch,
      policy.days == null
          ? null
          : at.add(Duration(days: policy.days!)).millisecondsSinceEpoch,
    ]);
    return ChatMessage(
      id: id,
      patientId: pid,
      text: text.trim(),
      createdAt: at,
    );
  }

  void deleteChatMessage(String pid, String id) {
    _store.scoped('chat_message', pid, id);
    _store.connection.execute(
      'DELETE FROM chat_message WHERE patient_id=? AND id=?',
      [pid, id],
    );
  }

  void clearChatMessages(String pid) {
    _store.patient(pid);
    _store.connection.execute('DELETE FROM chat_message WHERE patient_id=?', [
      pid,
    ]);
  }
}
