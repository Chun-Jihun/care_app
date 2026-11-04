import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/ui_preferences.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import 'home_customization_page.dart';

class DisplaySettingsPage extends StatelessWidget {
  const DisplaySettingsPage(this.c, {super.key});
  final CareController c;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final value = c.uiPreferences;
      Widget option(UiOption key, String title, String description) =>
          SwitchListTile(
            key: ValueKey('ui-${key.name}'),
            title: Text(context.tr(title)),
            subtitle: Text(context.tr(description)),
            value: value.enabled(key),
            onChanged: c.busy
                ? null
                : (on) => attempt(
                    context,
                    () =>
                        c.setUiPreferences(c.uiPreferences.withOption(key, on)),
                  ),
          );
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('화면·접근성 설정'))),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                context.tr(
                  '설정은 이 기기에 저장되고 잠금 화면에도 적용돼요. 기기의 더 큰 글자·동작 줄이기 설정은 계속 존중합니다.',
                ),
              ),
              Section(context.tr('글자와 터치')),
              option(
                UiOption.largeText,
                '큰 글자',
                '기본 글자를 키워요. 기기에 더 큰 글자를 설정했다면 그 크기를 유지해요.',
              ),
              option(UiOption.boldText, '굵은 글자', '본문과 버튼 글자를 더 굵게 표시해요.'),
              option(
                UiOption.highContrast,
                '고대비 화면',
                '글자와 입력란·선택 표시를 더 뚜렷하게 보여줘요.',
              ),
              option(
                UiOption.largeControls,
                '큰 버튼',
                '주요 버튼의 최소 터치 영역을 더 크게 해요.',
              ),
              Section(context.tr('동작과 성능')),
              option(
                UiOption.animations,
                '부드러운 화면 애니메이션',
                '탭 전환과 상세 항목 펼치기를 부드럽게 보여줘요. 동작 줄이기·저사양·기기 접근성 설정이 우선합니다.',
              ),
              option(UiOption.reduceMotion, '동작 효과 줄이기', '화면 전환과 터치 효과를 줄여요.'),
              option(
                UiOption.lowGraphics,
                '저사양 모드',
                '전환 효과·그림자·사진 미리보기를 줄여요. 기록과 원본 사진은 그대로 보관해요.',
              ),
              option(
                UiOption.photoPreviews,
                '사진 미리보기',
                '첨부 목록에 작은 사진을 표시해요. 저사양 모드에서는 생략하며 원본은 눌러서 볼 수 있어요.',
              ),
              Section(context.tr('홈 표시')),
              ListTile(
                title: Text(context.tr('홈 화면 편집')),
                subtitle: Text(context.tr('표시 항목·순서·빠른 기록 버튼 선택')),
                trailing: const Icon(Icons.chevron_right),
                onTap: c.busy
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => HomeCustomizationPage(c),
                        ),
                      ),
              ),
              option(
                UiOption.recentRecords,
                '최근 기록 표시',
                '홈에 최근 기록을 보여줘요. 일기에서는 항상 확인할 수 있어요.',
              ),
              option(
                UiOption.dailySummary,
                '오늘 기록 합계 표시',
                '입력한 수분량과 복용함 기록 건수를 홈에 보여줘요.',
              ),
              option(
                UiOption.caregiverShortcut,
                '간병인 상태 바로가기',
                '홈에서 돌보는 나의 상태를 기록하고 확인해요. 환자 기록과 따로 보관합니다.',
              ),
              option(
                UiOption.chatShortcut,
                '기록 도우미 바로가기',
                '홈에 기록 조회 대화창으로 가는 카드를 보여줘요.',
              ),
              Section(context.tr('입력 도움')),
              option(
                UiOption.inputSuggestions,
                '최근 입력 바로 선택',
                '같은 수첩의 음식·활동 이름을 직접 선택해 입력해요. 복약 상태와 관찰 결과는 복사하지 않아요.',
              ),
              OutlinedButton(
                onPressed: c.busy
                    ? null
                    : () => attempt(
                        context,
                        () =>
                            c.setUiPreferences(c.uiPreferences.resetDisplay()),
                      ),
                child: Text(context.tr('화면 설정 기본값으로')),
              ),
            ],
          ),
        ),
      );
    },
  );
}
