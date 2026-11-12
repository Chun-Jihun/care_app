import 'dart:typed_data';

import '../../domain/ai.dart';
import '../../domain/notebook_context.dart';
import '../../domain/record_lookup.dart';
import '../../l10n/app_strings.dart';
import '../ai_query_policy.dart';
import '../record_lookup_parser.dart';
import '../context_tasks.dart';
import '../session_access.dart';
import 'chat_service.dart';
import '../medical_answer_service.dart';
import '../knowledge_search.dart';

/// Coordinates scope and retention. Inference has no repository access.
final class AiService {
  AiService(
    this._scope,
    this._tasks,
    this._chat,
    this._runtime, {
    this.medical,
  });
  final MedicalAnswerService? medical;
  final SessionAccess _scope;
  final ContextTasks _tasks;
  final ChatService _chat;
  final LocalAiRuntime _runtime;
  bool _asking = false;
  ({
    int epoch,
    int revision,
    String pid,
    String messageId,
    RecordLookup lookup,
  })?
  _previous;
  Future<AiModelStatus> status() => _runtime.status();
  Future<void> removeModels() async {
    final epoch = _scope.capture();
    await _runtime.removeModels();
    _scope.check(epoch);
  }

  Future<void> install(void Function(double) progress) async {
    final epoch = _scope.capture();
    final path = await _scope.external(_runtime.pickBundle);
    _scope.check(epoch);
    if (path == null) return;
    await _runtime.installBundle(path, progress);
    _scope.check(epoch);
  }

  void cancel() {
    _previous = null;
    _runtime.cancel();
  }

  Future<void> dispose() => _runtime.dispose();

  Future<void> ask(
    String pid,
    String question,
    AppLanguage language, {
    Future<void> Function()? onUrgent,
  }) async {
    _scope.requirePatient(pid);
    if (_asking) throw const AiException(AiFailure.busy);
    if (question.trim().isEmpty || question.length > 20000) {
      throw const AiException(AiFailure.invalidInput);
    }
    final epoch = _scope.capture();
    _asking = true;
    try {
      final revision = _chat.revision;
      final guard = AiQueryPolicy.guard(question);
      if (guard == AiReplyKind.urgent && onUrgent != null) {
        await onUrgent();
        _scope.check(epoch);
        if (_chat.revision != revision || _chat.retention(pid) == null) return;
      }
      final prior = _previous;
      final previous =
          prior?.epoch == epoch &&
              prior?.revision == revision &&
              prior?.pid == pid &&
              _chat.messages(pid, limit: 1).lastOrNull?.id == prior?.messageId
          ? prior!.lookup
          : null;
      _previous = null;
      final message = await _chat.append(pid, question);
      _scope.check(epoch);
      // Background cleanup can end a chat while its question is being saved,
      // even when the notebook stays open because app lock is disabled.
      if (_chat.revision != revision) return;
      AiReply reply;
      final lookup = guard == null
          ? RecordLookupParser.parse(
              question,
              now: DateTime.now(),
              previous: previous,
            )
          : null;
      final preflight = AiQueryPolicy.preflight(question);
      if (guard == AiReplyKind.urgent || guard == AiReplyKind.notebookScope) {
        reply = AiReply(guard!);
      } else if (medical != null &&
          (guard == AiReplyKind.medicalHold ||
              (lookup == null &&
                  KnowledgeSearch.concepts(question).isNotEmpty))) {
        final patient = _scope.repository.patients().firstWhere(
          (p) => p.id == pid,
        );
        var masked = question;
        for (final identity in [patient.alias, patient.contact]) {
          if (identity.trim().isNotEmpty) {
            masked = masked.replaceAll(identity, '[private]');
          }
        }
        final task = _tasks.create(ContextSelection(patientId: pid));
        reply = await task.run((_) async {
          final answer = await medical!.answer(masked);
          _scope.check(epoch);
          final result = AiReply(
            answer.hold == null
                ? AiReplyKind.evidence
                : AiReplyKind.medicalHold,
            citations: answer.citations,
            evidenceHold: answer.hold,
            model: answer.hold == null
                ? 'qwen35-2b-sft-v1/evidence-select-v1'
                : '',
          );
          // Persisted replies share the legacy 8192-character bound. Escaped
          // source text can be larger than its visible character count.
          return result.encode().length <= 8192
              ? result
              : AiReply(AiReplyKind.medicalHold);
        });
      } else if (guard != null) {
        reply = AiReply(guard);
      } else if (lookup != null) {
        reply = _lookupReply(pid, lookup);
      } else if (RecordLookupParser.hasPeriodExpression(question)) {
        reply = AiReply(AiReplyKind.clarify);
      } else if (preflight != null) {
        reply = AiReply(preflight);
      } else if (question.length > 1200) {
        reply = AiReply(AiReplyKind.clarify);
      } else {
        // Only the question is given to the model. Identity is not needed for lookup.
        final patient = _scope.repository.patients().firstWhere(
          (p) => p.id == pid,
        );
        var masked = question;
        for (final identity in [patient.alias, patient.contact]) {
          if (identity.trim().isNotEmpty) {
            masked = masked.replaceAll(identity, '[private]');
          }
        }
        final task = _tasks.create(ContextSelection(patientId: pid));
        try {
          reply = await task.run((_) async {
            final raw = await _runtime.extractQuery(masked, language.code);
            _scope.check(epoch);
            final filter = AiQueryPolicy.parse(raw, masked);
            if (filter == null) return AiReply(AiReplyKind.clarify);
            return _lookupReply(
              pid,
              filter.lookup(AppStrings(language)),
              model: 'qwen35-2b-sft-v1',
            );
          });
        } on AiException catch (e) {
          if (e.code == AiFailure.cancelled) rethrow;
          reply = AiReply(AiReplyKind.unavailable);
        }
      }
      _scope.check(epoch);
      await _chat.attachReply(pid, message.id, reply, revision);
      if (reply.lookup case final lookup?) {
        _previous = (
          epoch: epoch,
          revision: revision,
          pid: pid,
          messageId: message.id,
          lookup: lookup,
        );
      }
    } finally {
      _asking = false;
    }
  }

  AiReply _lookupReply(String pid, RecordLookup lookup, {String model = ''}) {
    final matches = _scope.repository.entries(pid, lookup: lookup, limit: 9);
    return AiReply(
      matches.isEmpty ? AiReplyKind.noRecords : AiReplyKind.records,
      sources: matches
          .take(8)
          .map((e) => AiReference(e.id, e.version))
          .toList(),
      lookup: lookup,
      hasMore: matches.length > 8,
      model: model,
    );
  }

  Future<OcrDraft> recognize(
    String pid,
    Uint8List image,
    AppLanguage language,
  ) async {
    _scope.requirePatient(pid);
    final task = _tasks.create(ContextSelection(patientId: pid));
    return task.run((_) => _runtime.recognize(image, language.code));
  }

  Future<String> transcribe(
    String pid,
    Float32List samples,
    AppLanguage language,
  ) async {
    _scope.requirePatient(pid);
    final task = _tasks.create(ContextSelection(patientId: pid));
    return task.run((_) => _runtime.transcribe(samples, language.code));
  }

  Future<T> withTranscriber<T>(
    String pid,
    AppLanguage language,
    Future<T> Function(SpeechTranscriber) use,
  ) {
    final task = _tasks.create(ContextSelection(patientId: pid));
    return task.run(
      (reader) => _runtime.withTranscriber(language.code, (decode) {
        void check() {
          if (reader.cancelled) throw const AiException(AiFailure.cancelled);
        }

        check();
        return use((samples) async {
          check();
          try {
            return await decode(samples);
          } finally {
            check();
          }
        });
      }),
    );
  }
}
