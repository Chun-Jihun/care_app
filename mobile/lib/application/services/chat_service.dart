import '../../domain/chat.dart';
import '../../domain/records.dart';
import '../session_access.dart';

final class ChatService {
  ChatService(this._scope);
  final SessionAccess _scope;
  final _sessionMessages = <String, List<ChatMessage>>{};
  void clearSession() => _sessionMessages.clear();
  void retainPatients(Set<String> ids) =>
      _sessionMessages.removeWhere((pid, _) => !ids.contains(pid));
  ChatRetention? retention(String pid) {
    _scope.requirePatient(pid);
    return _scope.repository.chatRetention(pid);
  }

  List<ChatMessage> messages(String pid) {
    _scope.requirePatient(pid);
    return List.unmodifiable([
      ..._scope.repository.chatMessages(pid),
      ...?_sessionMessages[pid],
    ]);
  }

  Future<void> setRetention(String pid, ChatRetention value) =>
      _scope.write(pid, ChangeImpact.chat, (repository) {
        repository.setChatRetention(pid, value);
        _sessionMessages.remove(pid);
      });
  Future<void> add(String pid, String text) => _scope.write(
    pid,
    ChangeImpact.chat,
    (repository) {
      final policy = repository.chatRetention(pid);
      if (policy == null) throw CareError(CareErrorCode.chatRetentionRequired);
      if (text.trim().isEmpty || text.length > 20000) {
        throw CareError(CareErrorCode.invalidQuestionLength);
      }
      if (policy == ChatRetention.session) {
        (_sessionMessages[pid] ??= []).add(
          ChatMessage(
            id: _scope.newId(),
            patientId: pid,
            text: text.trim(),
            createdAt: DateTime.now(),
          ),
        );
      } else {
        repository.addChatMessage(pid, text);
      }
    },
  );
  Future<void> delete(String pid, String id) =>
      _scope.write(pid, ChangeImpact.chat, (repository) {
        if (_sessionMessages[pid]?.any((m) => m.id == id) ?? false) {
          _sessionMessages[pid]!.removeWhere((m) => m.id == id);
        } else {
          repository.deleteChatMessage(pid, id);
        }
      });
  Future<void> clear(String pid) =>
      _scope.write(pid, ChangeImpact.chat, (repository) {
        repository.clearChatMessages(pid);
        _sessionMessages.remove(pid);
      });
}
