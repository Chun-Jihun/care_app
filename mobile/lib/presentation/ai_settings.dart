import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/ai.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

class AiSettings extends StatefulWidget {
  const AiSettings(this.c, {super.key});
  final CareController c;
  @override
  State<AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends State<AiSettings> {
  late Future<AiModelStatus> status = widget.c.ai.status();
  bool working = false;
  bool removing = false;
  bool confirming = false;
  double progress = 0;
  Object? error;
  @override
  void dispose() {
    if (working) widget.c.ai.cancel();
    super.dispose();
  }

  Future<void> install() async {
    if (working || confirming) return;
    setState(() {
      working = true;
      error = null;
      progress = 0;
    });
    try {
      await widget.c.ai.install((v) {
        if (mounted) setState(() => progress = v);
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) {
        setState(() {
          working = false;
          status = widget.c.ai.status();
        });
      }
    }
  }

  Future<void> remove() async {
    if (working || confirming) return;
    final session = widget.c.captureSession();
    setState(() {
      confirming = true;
      error = null;
    });
    try {
      if (!await confirm(
        context,
        context.tr('설치한 AI 모델을 삭제할까요?'),
        context.tr(
          '모델 파일만 삭제합니다. 간병기록과 사진은 유지되며, 사진·음성 인식을 다시 쓰려면 모델을 재설치해야 합니다.',
        ),
      )) {
        return;
      }
      if (!mounted) return;
      widget.c.requireSession(session);
      setState(() {
        confirming = false;
        working = true;
        removing = true;
      });
      await widget.c.ai.removeModels();
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) {
        setState(() {
          working = false;
          removing = false;
          confirming = false;
          status = widget.c.ai.status();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('기기 AI'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              '한국어 기간별 기록 조회는 모델 없이 사용할 수 있어요. 사진 글자 읽기·음성 입력과 추가 질문 해석에는 제공된 .careai 모델 파일이 필요합니다.',
            ),
          ),
          FutureBuilder<AiModelStatus>(
            future: status,
            builder: (context, snapshot) {
              final s = snapshot.data;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr(
                      s?.installed == true
                          ? '모델 설치됨'
                          : s?.supported == false
                          ? '이 기기는 AI 실행을 지원하지 않습니다.'
                          : '모델 설치 필요',
                    ),
                  ),
                  if (s?.installed == true && s!.version.isNotEmpty)
                    Text(context.tr('모델 버전: {0}', [s.version])),
                  if ((s?.bytes ?? 0) > 0) ...[
                    Text(
                      context.tr('모델 용량: 약 {0} GB', [
                        (s!.bytes / 1000000000).toStringAsFixed(2),
                      ]),
                    ),
                    Text(context.tr('설치 파일과 임시 복사본을 위해 추가 저장 공간이 필요합니다.')),
                  ],
                  if (s?.supported != false)
                    OutlinedButton.icon(
                      onPressed: working || confirming ? null : install,
                      icon: const Icon(Icons.folder_open),
                      label: Text(context.tr('모델 파일 선택')),
                    ),
                  if (s?.installed == true)
                    TextButton.icon(
                      onPressed: working || confirming ? null : remove,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(context.tr('AI 모델 삭제')),
                    ),
                ],
              );
            },
          ),
          if (working) ...[
            LinearProgressIndicator(
              value: !removing && progress > 0 ? progress : null,
            ),
            if (removing)
              Text(context.tr('모델 삭제 중…'))
            else ...[
              Text(context.tr('모델 설치 중 · {0}% ', [(progress * 100).floor()])),
              TextButton(
                onPressed: widget.c.ai.cancel,
                child: Text(context.tr('취소')),
              ),
            ],
          ],
          if (error != null) Text(errorText(context, error!)),
          TextButton(
            onPressed: () => showLicensePage(context: context),
            child: Text(context.tr('오픈소스 라이선스')),
          ),
        ],
      ),
    ),
  );
}
