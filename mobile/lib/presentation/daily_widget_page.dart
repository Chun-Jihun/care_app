import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/ui_preferences.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

class DailyWidgetPage extends StatelessWidget {
  const DailyWidgetPage(this.c, {super.key});
  final CareController c;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked) return const SizedBox.shrink();
      final value = c.uiPreferences;
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('휴대전화 홈 위젯'))),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                context.tr(
                  '오늘 할 일·복용함 기록 건수·다음 확인 시각을 휴대전화 홈에서 볼 수 있어요. 위젯을 누르면 앱이 열립니다.',
                ),
              ),
              Text(
                context.tr('현재 선택한 수첩: {0}', [
                  context.strings.patient(c.patient),
                ]),
              ),
              Text(
                context.tr(
                  '위젯은 마지막 갱신 시점의 요약입니다. 앱을 열거나 기록을 바꾸면 갱신하고, 실제 복용이나 할 일 완료를 자동으로 판단하지 않아요.',
                ),
              ),
              if (!c.widgetAvailable)
                Text(context.tr('이 기기나 빌드에서는 홈 위젯을 사용할 수 없습니다.')),
              SwitchListTile(
                key: const ValueKey('widget-enabled'),
                title: Text(context.tr('홈 위젯 요약 사용')),
                subtitle: Text(
                  context.tr(
                    '앱 잠금과 별개로 선택한 요약을 홈 화면에 표시해요. 사용을 끄면 저장된 위젯 요약을 지웁니다.',
                  ),
                ),
                value: value.enabled(UiOption.dailyWidget),
                onChanged: c.busy || !c.widgetAvailable
                    ? null
                    : (on) => attempt(
                        context,
                        () => c.setUiPreferences(
                          c.uiPreferences.withOption(UiOption.dailyWidget, on),
                        ),
                      ),
              ),
              SwitchListTile(
                key: const ValueKey('widget-details'),
                title: Text(context.tr('위젯에 할 일 제목·약 이름 표시')),
                subtitle: Text(
                  context.tr(
                    '기본은 건수와 시각만 보여요. 켜면 다른 사람이 홈 화면에서 제목과 약 이름을 볼 수 있어요.',
                  ),
                ),
                value: value.enabled(UiOption.widgetDetails),
                onChanged:
                    c.busy ||
                        !c.widgetAvailable ||
                        !value.enabled(UiOption.dailyWidget)
                    ? null
                    : (on) async {
                        if (on &&
                            !await confirm(
                              context,
                              context.tr('위젯에 상세 이름을 표시할까요?'),
                              context.tr(
                                '할 일 제목과 약 이름이 앱 밖의 홈 화면에 표시됩니다. 환자 별칭·메모·복용 지시는 내보내지 않아요.',
                              ),
                              action: context.tr('상세 이름 표시'),
                            )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await attempt(
                          context,
                          () => c.setUiPreferences(
                            c.uiPreferences.withOption(
                              UiOption.widgetDetails,
                              on,
                            ),
                          ),
                        );
                      },
              ),
              if (c.widgetUpdateFailed)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.tr(
                      '위젯 요약을 갱신하거나 지우지 못했어요. 앱에서 내용을 확인하고 다시 시도해 주세요.',
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              OutlinedButton.icon(
                onPressed:
                    c.busy ||
                        !c.widgetAvailable ||
                        !value.enabled(UiOption.dailyWidget)
                    ? null
                    : () => attempt(context, c.refreshDailyWidget),
                icon: const Icon(Icons.refresh),
                label: Text(context.tr('위젯 요약 지금 갱신')),
              ),
              OutlinedButton.icon(
                onPressed:
                    c.busy ||
                        !c.widgetAvailable ||
                        !value.enabled(UiOption.dailyWidget)
                    ? null
                    : () => attempt(context, () async {
                        await c.requestDailyWidgetPin();
                      }),
                icon: const Icon(Icons.widgets_outlined),
                label: Text(context.tr('홈에 위젯 추가 요청')),
              ),
              Text(
                context.tr(
                  '추가 창이 나오지 않으면 휴대전화 홈의 빈 곳을 길게 누르고 위젯 목록에서 간병수첩을 선택해 주세요. 아이폰에서는 이 방법으로 추가합니다.',
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
