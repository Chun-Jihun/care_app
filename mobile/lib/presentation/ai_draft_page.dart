import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../application/input_field_suggestions.dart';
import '../domain/ai.dart';
import '../domain/records.dart';
import '../domain/reviewed_input.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import 'ai_field_choices.dart';

Future<String?> reviewAiInput(
  BuildContext context,
  CareController c,
  String pid, {
  Uint8List? photo,
}) async => (await reviewRecordInput(context, c, pid, photo: photo))?.text;

Future<ReviewedInput?> reviewRecordInput(
  BuildContext context,
  CareController c,
  String pid, {
  Uint8List? photo,
  EntryKind? kind,
  Map<String, String> currentFields = const {},
}) => pushPage(
  context,
  MaterialPageRoute<ReviewedInput>(
    builder: (_) => AiDraftPage(
      c,
      pid,
      photo: photo,
      recordKind: kind,
      currentFields: currentFields,
    ),
  ),
);

class AiDraftPage extends StatefulWidget {
  AiDraftPage(
    this.c,
    this.pid, {
    this.photo,
    this.recordKind,
    Map<String, String> currentFields = const {},
    super.key,
  }) : currentFields = Map.unmodifiable(currentFields);
  final CareController c;
  final String pid;
  final Uint8List? photo;
  final EntryKind? recordKind;
  final Map<String, String> currentFields;
  @override
  State<AiDraftPage> createState() => _AiDraftPageState();
}

class _AiDraftPageState extends State<AiDraftPage> with WidgetsBindingObserver {
  final text = TextEditingController();
  final memo = TextEditingController();
  String recognizedText = '';
  final selectedFields = <String, String>{};
  MicrophoneCapture? recorder;
  Timer? timer;
  bool working = false, recording = false, ready = false;
  int seconds = 0;
  int operation = 0;
  Object? error;
  late final int session;
  @override
  void initState() {
    super.initState();
    session = widget.c.captureSession();
    WidgetsBinding.instance.addObserver(this);
  }

  bool get valid {
    if (!mounted || widget.c.selectedId != widget.pid) return false;
    try {
      widget.c.requireSession(session);
      return true;
    } on Object {
      return false;
    }
  }

  bool current(int token) => valid && token == operation;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      operation++;
      timer?.cancel();
      final active = recorder;
      recorder = null;
      if (active != null) unawaited(active.dispose());
      if (working) widget.c.ai.cancel();
      if (mounted && (working || recording)) {
        setState(() {
          working = false;
          recording = false;
          error = const AiException(AiFailure.cancelled);
        });
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final active = recorder;
    if (active != null) unawaited(active.dispose());
    if (working) widget.c.ai.cancel();
    text.dispose();
    memo.dispose();
    super.dispose();
  }

  Future<void> start() async {
    if (working || recording) return;
    final token = ++operation;
    var full = false;
    setState(() {
      working = true;
      error = null;
    });
    try {
      if (!(await widget.c.ai.status()).installed) {
        throw const AiException(AiFailure.unavailable);
      }
      if (!current(token)) return;
      if (widget.photo != null) {
        final draft = await widget.c.ai.recognize(
          widget.pid,
          widget.photo!,
          widget.c.language,
        );
        if (!current(token)) return;
        if (draft.lines.isEmpty) throw const AiException(AiFailure.noSpeech);
        setState(() {
          recognizedText = draft.text;
          text.text = recognizedText;
          ready = true;
        });
      } else {
        final factory = widget.c.microphone;
        if (factory == null) throw const AiException(AiFailure.unavailable);
        final active = factory();
        recorder = active;
        await active.start(() {
          full = true;
          if (current(token) && !working) unawaited(stop());
        });
        if (!current(token)) {
          await active.dispose();
          if (identical(recorder, active)) recorder = null;
          return;
        }
        setState(() {
          recording = true;
          seconds = 0;
        });
        timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!current(token)) {
            unawaited(active.dispose());
            timer?.cancel();
            return;
          }
          setState(() => seconds++);
          if (seconds >= 30) unawaited(stop());
        });
      }
    } catch (e) {
      if (current(token)) {
        final active = recorder;
        recorder = null;
        if (active != null) await active.dispose();
        if (current(token)) setState(() => error = e);
      }
    } finally {
      if (current(token)) {
        setState(() => working = false);
        if (full && recording) unawaited(stop());
      }
    }
  }

  Future<void> stop() async {
    if (!recording || working || recorder == null) return;
    final token = ++operation;
    timer?.cancel();
    setState(() {
      recording = false;
      working = true;
    });
    final active = recorder!;
    recorder = null;
    Float32List? samples;
    try {
      samples = await active.stop();
      await active.dispose();
      if (!current(token)) return;
      final result = await widget.c.ai.transcribe(
        widget.pid,
        samples,
        widget.c.language,
      );
      if (current(token)) {
        final combined = appendReviewedInput(text.text, result);
        final original = appendReviewedInput(recognizedText, result);
        setState(() {
          text.text = combined;
          recognizedText = original;
          ready = true;
        });
      }
    } catch (e) {
      if (current(token)) setState(() => error = e);
    } finally {
      await active.dispose();
      samples?.fillRange(0, samples.length, 0);
      if (current(token)) setState(() => working = false);
    }
  }

  String reviewedText(BuildContext context) {
    if (memo.text.trim().isEmpty) return text.text;
    return '${text.text}\n\n${context.tr('추가 메모')}:\n${memo.text.trim()}';
  }

  Map<String, String> fieldCandidates(BuildContext context) =>
      widget.recordKind == null
      ? const {}
      : InputFieldSuggestions.parse(
          text.text,
          widget.recordKind!,
          context.strings,
        );

  Map<String, String> confirmedFields(BuildContext context) {
    final candidates = fieldCandidates(context);
    return {
      for (final entry in selectedFields.entries)
        if (candidates[entry.key] == entry.value &&
            (widget.currentFields[entry.key] ?? '').trim().isEmpty)
          entry.key: entry.value,
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.tr(widget.photo == null ? '음성으로 입력' : '사진에서 글자 읽기')),
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            context.tr(
              '인식 결과는 틀릴 수 있어요. 이름·숫자·단위를 확인하고 수정해 주세요. 반영 후에도 기록 저장은 직접 눌러야 합니다.',
            ),
          ),
          if (widget.photo != null)
            SizedBox(
              height: 230,
              child: InteractiveViewer(
                maxScale: 8,
                child: Image.memory(widget.photo!),
              ),
            ),
          const SizedBox(height: 16),
          if (recording)
            Text(
              context.tr('녹음 중 · {0}/30초', [seconds]),
              style: const TextStyle(color: Colors.red),
            ),
          if (working) ...[
            const LinearProgressIndicator(),
            Text(context.tr('기기에서 처리 중…')),
          ],
          if ((!ready || widget.photo == null) && !working)
            FilledButton.icon(
              onPressed: recording ? stop : start,
              icon: Icon(
                recording
                    ? Icons.stop
                    : widget.photo == null
                    ? Icons.mic
                    : Icons.document_scanner_outlined,
              ),
              label: Text(
                context.tr(
                  recording
                      ? '녹음 마치기'
                      : widget.photo == null
                      ? ready
                            ? '이어서 녹음'
                            : '녹음 시작'
                      : '글자 읽기',
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(errorText(context, error!)),
            ),
          if (ready) ...[
            ...[
              ExpansionTile(
                key: const ValueKey('ocrOriginal'),
                title: Text(context.tr('수정 전 인식 결과 보기')),
                childrenPadding: const EdgeInsets.all(12),
                children: [SelectableText(recognizedText)],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const ValueKey('aiDraftText'),
              controller: text,
              minLines: 4,
              maxLines: 8,
              maxLength: 20000,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                labelText: context.tr(
                  widget.photo == null ? '확인할 초안' : '인식한 본문 · 수정할 수 있어요',
                ),
              ),
              onChanged: (_) => setState(selectedFields.clear),
            ),
            if (widget.recordKind case final kind?)
              AiFieldChoices(
                kind: kind,
                candidates: fieldCandidates(context),
                currentFields: widget.currentFields,
                selected: selectedFields,
                enabled: !working && !recording,
                onChanged: (key, value, checked) => setState(() {
                  if (checked) {
                    selectedFields[key] = value;
                  } else {
                    selectedFields.remove(key);
                  }
                }),
              ),
            ...[
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('ocrMemo'),
                controller: memo,
                minLines: 2,
                maxLines: 6,
                maxLength: 20000,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: context.tr('덧붙일 메모 (선택)'),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 16),
            if (reviewedText(context).length > 20000)
              Text(
                context.tr('본문과 메모를 합쳐 20,000자까지 반영할 수 있어요.'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            FilledButton(
              onPressed:
                  working ||
                      recording ||
                      text.text.trim().isEmpty ||
                      reviewedText(context).length > 20000
                  ? null
                  : () {
                      if (valid) {
                        Navigator.pop(
                          context,
                          ReviewedInput(
                            reviewedText(context),
                            fields: confirmedFields(context),
                          ),
                        );
                      }
                    },
              child: Text(context.tr('확인한 내용을 입력란에 반영')),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('취소')),
          ),
        ],
      ),
    ),
  );
}
