import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../application/visit_audio_buffer.dart';
import '../domain/ai.dart';
import '../domain/drafts.dart';
import '../domain/records.dart';
import '../domain/visit_recording.dart';
import '../l10n/app_strings.dart';
import 'ai_settings.dart';
import 'common.dart';
import 'draft_page.dart';
import 'draft_support.dart';
import 'editors/entry_editor.dart';

enum _AudioWork { idle, starting, recording, stopping, playing, transcribing }

class VisitRecordingPage extends StatefulWidget {
  const VisitRecordingPage(this.c, this.pid, {super.key});

  final CareController c;
  final String pid;

  @override
  State<VisitRecordingPage> createState() => _VisitRecordingPageState();
}

class _VisitRecordingPageState extends State<VisitRecordingPage>
    with WidgetsBindingObserver {
  late final _device = widget.c.visitAudio!();
  late final int _session;
  final _clock = Stopwatch();
  StreamSubscription<Uint8List>? _input;
  VisitAudioBuffer? _buffer;
  Timer? _ticker;
  var _work = _AudioWork.idle;
  var _operation = 0;
  int _processed = 0, _total = 0;
  Object? _error;
  bool _interrupted = false;

  bool get _idle => _work == _AudioWork.idle;
  bool _current(int operation) {
    if (!mounted ||
        operation != _operation ||
        widget.c.selectedId != widget.pid) {
      return false;
    }
    try {
      widget.c.requireSession(_session);
      return true;
    } on CareError {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    // Capture before requesting permission or making any asynchronous call.
    _session = widget.c.captureSession();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (_work == _AudioWork.recording) {
        unawaited(_stop(interrupted: true));
      } else if (!_idle) {
        _cancel();
      }
    }
  }

  Future<void> _start() async {
    final operation = ++_operation;
    setState(() {
      _work = _AudioWork.starting;
      _error = null;
      _interrupted = false;
    });
    try {
      final agreed = await confirm(
        context,
        context.tr('진료 녹음을 시작할까요?'),
        context.tr('환자와 의료진에게 녹음 목적을 알리고 동의를 확인해 주세요. 녹음은 기기에 암호화해 보관해요.'),
        action: context.tr('동의를 확인하고 녹음'),
      );
      if (!agreed || !_current(operation)) return;
      if (!await _device.requestPermission()) {
        throw const AiException(AiFailure.microphoneDenied);
      }
      if (!_current(operation)) return;
      final recording = widget.c.visitRecordings.begin(widget.pid);
      _buffer = VisitAudioBuffer((pcm) {
        widget.c.requireSession(_session);
        widget.c.visitRecordings.append(widget.pid, recording.id, pcm);
      });
      await _device.keepScreenOn(true);
      if (!_current(operation)) return;
      final stream = await _device.start(
        () => unawaited(_stop(interrupted: true)),
      );
      if (!_current(operation)) return;
      setState(() => _work = _AudioWork.recording);
      _clock
        ..reset()
        ..start();
      _input = stream.listen(
        (bytes) {
          if (!_current(operation)) {
            unawaited(_stop(interrupted: true));
            return;
          }
          try {
            _buffer!.add(bytes);
            if (_buffer!.full) unawaited(_stop());
          } on Object catch (error) {
            unawaited(_stop(failure: error));
          }
        },
        onError: (Object error) => unawaited(_stop(failure: error)),
        onDone: () => unawaited(_stop(interrupted: true)),
      );
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_clock.elapsed.inSeconds >= VisitRecording.maxSeconds) {
          unawaited(_stop());
        } else if (mounted) {
          setState(() {});
        }
      });
    } on Object catch (error) {
      if (_current(operation)) _error = error;
    } finally {
      if (_work == _AudioWork.starting) {
        await _releaseCapture();
        if (mounted) setState(() => _work = _AudioWork.idle);
      }
    }
  }

  Future<void> _releaseCapture() async {
    try {
      await _input?.cancel();
      _input = null;
      await _device.stop();
    } on Object {
      // The device can already be stopped after an interruption.
    } finally {
      await _ignore(() => _device.keepScreenOn(false));
      _buffer?.finish(saveTail: false);
      _buffer = null;
    }
  }

  Future<void> _stop({bool interrupted = false, Object? failure}) async {
    if (_work != _AudioWork.recording) return;
    _work = _AudioWork.stopping;
    _ticker?.cancel();
    _clock.stop();
    _error = failure;
    _interrupted = interrupted;
    try {
      _buffer?.finish(saveTail: failure == null && _current(_operation));
    } on Object catch (error) {
      _error = error;
    }
    if (mounted) setState(() {});
    await _releaseCapture();
    if (mounted) setState(() => _work = _AudioWork.idle);
  }

  Future<void> _play(VisitRecording recording) async {
    final operation = ++_operation;
    setState(() {
      _work = _AudioWork.playing;
      _error = null;
    });
    try {
      await _device.startPlayback();
      var offset = 0;
      while (_current(operation)) {
        final pcm = widget.c.visitRecordings.read(
          widget.pid,
          recording.id,
          offset,
        );
        if (pcm == null) break;
        try {
          var sent = 0;
          while (sent < pcm.length && _current(operation)) {
            final count = await _device.writePlayback(pcm, sent);
            if (count == 0) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            sent += count;
          }
          offset += pcm.length;
        } finally {
          pcm.fillRange(0, pcm.length, 0);
        }
      }
      while (_current(operation) && !await _device.playbackDrained()) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    } on Object catch (error) {
      if (_current(operation)) _error = error;
    } finally {
      await _ignore(_device.stopPlayback);
      if (mounted) setState(() => _work = _AudioWork.idle);
    }
  }

  Future<void> _transcribe(VisitRecording recording) async {
    final operation = ++_operation;
    setState(() {
      _work = _AudioWork.transcribing;
      _error = null;
      _processed = 0;
      _total = recording.byteCount;
    });
    final segments = <({int seconds, String text})>[];
    final skipped = context.tr('이 구간은 인식하지 못했어요.');
    var recognized = false;
    try {
      await widget.c.ai.withTranscriber(widget.pid, widget.c.language, (
        decode,
      ) async {
        while (_current(operation) && _processed < _total) {
          final start = _processed;
          final samples = Float32List(VisitRecording.sampleRate * 30);
          var length = 0;
          try {
            for (var i = 0; i < 30 && _processed < _total; i++) {
              final pcm = widget.c.visitRecordings.read(
                widget.pid,
                recording.id,
                _processed,
              )!;
              try {
                final data = ByteData.sublistView(pcm);
                for (var j = 0; j < pcm.length; j += 2) {
                  samples[length++] = data.getInt16(j, Endian.little) / 32768;
                }
                _processed += pcm.length;
              } finally {
                pcm.fillRange(0, pcm.length, 0);
              }
            }
            final result = await decode(
              Float32List.sublistView(samples, 0, length),
            );
            if (!_current(operation)) return;
            recognized = true;
            segments.add((
              seconds: start ~/ VisitRecording.bytesPerSecond,
              text: result,
            ));
          } on AiException catch (error) {
            if (error.code != AiFailure.noSpeech) rethrow;
            if (!_current(operation)) return;
            segments.add((
              seconds: start ~/ VisitRecording.bytesPerSecond,
              text: skipped,
            ));
          } finally {
            samples.fillRange(0, samples.length, 0);
          }
          if (_current(operation)) setState(() {});
        }
      });
      if (!mounted || !_current(operation)) return;
      if (!recognized) throw const AiException(AiFailure.noSpeech);
      final parts = _transcriptParts(recording.startedAt, segments);
      if (parts.length == 1) {
        setState(() => _work = _AudioWork.idle);
        await editEntry(
          context,
          widget.c,
          EntryKind.medicalContact,
          initialNote: parts.single.note,
          initialAt: parts.single.at,
        );
        return;
      }
      if (!await chooseDraftRetention(context, widget.c, onlyIfUnset: true) ||
          !mounted ||
          !_current(operation)) {
        return;
      }
      final ids = await widget.c.drafts.addEntries(widget.pid, parts);
      if (!mounted || !_current(operation)) return;
      setState(() => _work = _AudioWork.idle);
      await pushPage(
        context,
        MaterialPageRoute<void>(
          builder: (_) => DraftPage(widget.c, transcriptDraftIds: ids),
        ),
      );
    } on Object catch (error) {
      if (_current(operation)) _error = error;
    } finally {
      if (mounted) setState(() => _work = _AudioWork.idle);
    }
  }

  List<EntryDraftPayload> _transcriptParts(
    DateTime recordedAt,
    List<({int seconds, String text})> segments,
  ) {
    final parts = <EntryDraftPayload>[];
    final note = StringBuffer();
    var startSeconds = 0;
    void finishPart() {
      parts.add(
        EntryDraftPayload(
          kind: EntryKind.medicalContact,
          note: note.toString().trimRight(),
          at: recordedAt.add(Duration(seconds: startSeconds)),
        ),
      );
      note.clear();
    }

    for (final segment in segments) {
      final prefix = '[${_time(segment.seconds)}] ';
      var start = 0;
      do {
        var end = min(
          segment.text.length,
          start + entryNoteLimit - prefix.length,
        );
        if (end < segment.text.length &&
            (segment.text.codeUnitAt(end - 1) & 0xFC00) == 0xD800) {
          // A supplementary character uses two UTF-16 code units.
          end--;
        }
        final line = '$prefix${segment.text.substring(start, end)}';
        if (note.isNotEmpty && note.length + 1 + line.length > entryNoteLimit) {
          finishPart();
        }
        if (note.isEmpty) {
          startSeconds = segment.seconds;
        } else {
          note.write('\n');
        }
        note.write(line);
        start = end;
      } while (start < segment.text.length);
    }
    finishPart();
    return parts;
  }

  void _cancel() {
    _operation++;
    if (_work == _AudioWork.transcribing) widget.c.ai.cancel();
    if (_work == _AudioWork.playing) unawaited(_ignore(_device.stopPlayback));
  }

  Future<void> _delete(VisitRecording recording) async {
    if (!await confirm(
          context,
          context.tr('진료 녹음을 삭제할까요?'),
          context.tr('이 음성 원본을 삭제해요. 따로 저장한 진료 기록은 남아요.'),
          action: context.tr('삭제'),
        ) ||
        !mounted) {
      return;
    }
    await attempt(context, () async {
      widget.c.requireSession(_session);
      widget.c.visitRecordings.delete(widget.pid, recording.id);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel();
    _ticker?.cancel();
    unawaited(_releaseCapture().whenComplete(() => _ignore(_device.dispose)));
    super.dispose();
  }

  Future<void> _ignore(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      /* Best effort during interruption. */
    }
  }

  static String _time(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final recordings = _idle && _current(_operation)
        ? widget.c.visitRecordings.list(widget.pid)
        : const <VisitRecording>[];
    return PopScope(
      canPop: _idle,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && _work == _AudioWork.recording) unawaited(_stop());
        if (!popped && _work != _AudioWork.stopping) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(context.tr('진료 녹음'))),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(context.tr('최대 30분 동안 녹음해요. 이 화면을 벗어나거나 기기를 잠그면 녹음이 중단돼요.')),
              const SizedBox(height: 12),
              if (_work == _AudioWork.recording) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.tr('녹음 중 · {0}', [_time(_clock.elapsed.inSeconds)]),
                  ),
                ),
                FilledButton.icon(
                  onPressed: () => _stop(),
                  icon: const Icon(Icons.stop),
                  label: Text(context.tr('녹음 마치기')),
                ),
              ] else if (_idle)
                FilledButton.icon(
                  onPressed: widget.c.busy ? null : _start,
                  icon: const Icon(Icons.mic_none),
                  label: Text(context.tr('녹음 시작')),
                ),
              if (_work == _AudioWork.playing ||
                  _work == _AudioWork.transcribing)
                OutlinedButton(
                  onPressed: _cancel,
                  child: Text(context.tr('처리 취소')),
                ),
              if (_work == _AudioWork.transcribing)
                LinearProgressIndicator(
                  value: _total == 0 ? null : _processed / _total,
                ),
              if (_interrupted)
                Text(context.tr('녹음이 중단됐어요. 저장된 구간은 아래에서 확인할 수 있어요.')),
              if (_error != null) Text(errorText(context, _error!)),
              if (_idle &&
                  _error is AiException &&
                  (_error as AiException).code == AiFailure.unavailable)
                TextButton(
                  onPressed: () => openAiSettings(context, widget.c),
                  child: Text(context.tr('AI·근거자료 관리')),
                ),
              if (_idle)
                for (final recording in recordings)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${dateText(context, recording.startedAt)} · ${_time(recording.duration.inSeconds)}',
                          ),
                          Text(
                            context.tr(
                              recording.kept
                                  ? '음성 원본 보관 중'
                                  : '녹음 초안 · 보관하거나 삭제해 주세요.',
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: () => _play(recording),
                                child: Text(context.tr('녹음 듣기')),
                              ),
                              TextButton(
                                onPressed: () => _transcribe(recording),
                                child: Text(context.tr('전사하고 검토하기')),
                              ),
                              if (!recording.kept)
                                TextButton(
                                  onPressed: () => attempt(context, () async {
                                    widget.c.visitRecordings.keep(
                                      widget.pid,
                                      recording.id,
                                    );
                                    if (mounted) setState(() {});
                                  }),
                                  child: Text(context.tr('음성 원본 보관')),
                                ),
                              TextButton(
                                onPressed: () => _delete(recording),
                                child: Text(context.tr('삭제')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              Text(
                context.tr(
                  '음성 원본은 선택 백업에 포함되지 않아요. 전사한 내용은 확인하고 저장해야 진료 기록이 돼요.',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
