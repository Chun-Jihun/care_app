import '../../domain/chat.dart';
import '../../domain/records.dart';
import '../session_access.dart';
import '../../domain/ai.dart';

final class ChatService {
  ChatService(this._scope);
  final SessionAccess _scope;
  final _sessionMessages = <String, List<ChatMessage>>{};
  int _revision = 0;
  int get revision => _revision;
  void clearSession() {
    _revision++;
    _sessionMessages.clear();
  }

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
        _revision++;
        repository.setChatRetention(pid, value);
        _sessionMessages.remove(pid);
      });
  Future<void> add(String pid, String text) async {
    await append(pid, text);
  }

  Future<ChatMessage> append(String pid, String text) => _scope.write(
    pid,
    ChangeImpact.chat,
    (repository) {
      final policy = repository.chatRetention(pid);
      if (policy == null) throw CareError(CareErrorCode.chatRetentionRequired);
      if (text.trim().isEmpty || text.length > 20000) {
        throw CareError(CareErrorCode.invalidQuestionLength);
      }
      if (policy == ChatRetention.session) {
        final message = ChatMessage(
          id: _scope.newId(),
          patientId: pid,
          text: text.trim(),
          createdAt: DateTime.now(),
        );
        (_sessionMessages[pid] ??= []).add(message);
        return message;
      } else {
        return repository.addChatMessage(pid, text);
      }
    },
  );
  Future<void> attachReply(
    String pid,
    String id,
    AiReply reply,
    int revision,
  ) => _scope.write(pid, ChangeImpact.chat, (repository) {
    if (_revision != revision || !messages(pid).any((m) => m.id == id)) return;
    final local = _sessionMessages[pid];
    final index = local?.indexWhere((m) => m.id == id) ?? -1;
    if (index >= 0) {
      local![index] = local[index].withReply(reply);
    } else {
      repository.setChatReply(pid, id, reply);
    }
  });
  Future<void> delete(String pid, String id) =>
      _scope.write(pid, ChangeImpact.chat, (repository) {
        _revision++;
        if (_sessionMessages[pid]?.any((m) => m.id == id) ?? false) {
          _sessionMessages[pid]!.removeWhere((m) => m.id == id);
        } else {
          repository.deleteChatMessage(pid, id);
        }
      });
  Future<void> clear(String pid) =>
      _scope.write(pid, ChangeImpact.chat, (repository) {
        _revision++;
        repository.clearChatMessages(pid);
        _sessionMessages.remove(pid);
      });
}
