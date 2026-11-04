import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../domain/ui_preferences.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

String homeSectionTitle(HomeSection section) => switch (section) {
  HomeSection.quickRecords => '빠른 기록',
  HomeSection.tasks => '할 일',
  HomeSection.medications => '오늘의 복약',
  HomeSection.photo => '사진으로 기록',
  HomeSection.caregiver => '돌보는 나의 상태',
  HomeSection.chat => '간병 도우미 대화',
  HomeSection.contacts => '연락이 필요할 때',
  HomeSection.recent => '최근 기록',
  HomeSection.totals => '차곡차곡, 오늘의 기록',
};

class HomeCustomizationPage extends StatelessWidget {
  const HomeCustomizationPage(this.c, {super.key});
  final CareController c;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final preferences = c.uiPreferences, order = preferences.homeOrder;
      void save(UiPreferences next) =>
          attempt(context, () => c.setUiPreferences(next));
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('홈 화면 편집'))),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                context.tr(
                  '표시할 항목과 순서를 고르세요. 숨겨도 기록은 지워지지 않으며 아래 탭과 기록하기에서 사용할 수 있어요.',
                ),
              ),
              for (final (index, section) in order.indexed)
                Card(
                  key: ValueKey('home-${section.name}'),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: Text(context.tr(homeSectionTitle(section))),
                        value: preferences.enabled(section.option),
                        onChanged: c.busy
                            ? null
                            : (value) => save(
                                c.uiPreferences.withOption(
                                  section.option,
                                  value,
                                ),
                              ),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: c.busy || index == 0
                                ? null
                                : () => save(
                                    c.uiPreferences.moveHomeSection(
                                      section,
                                      -1,
                                    ),
                                  ),
                            icon: const Icon(Icons.arrow_upward),
                            label: Text(
                              context.tr('{0} 위로', [
                                context.tr(homeSectionTitle(section)),
                              ]),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: c.busy || index == order.length - 1
                                ? null
                                : () => save(
                                    c.uiPreferences.moveHomeSection(section, 1),
                                  ),
                            icon: const Icon(Icons.arrow_downward),
                            label: Text(
                              context.tr('{0} 아래로', [
                                context.tr(homeSectionTitle(section)),
                              ]),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              Section(context.tr('빠른 기록 버튼 선택')),
              for (final kind in EntryKind.values)
                CheckboxListTile(
                  key: ValueKey('quick-${kind.name}'),
                  title: Text(context.tr(kind.label)),
                  value: preferences.quickKinds.contains(kind),
                  onChanged: c.busy
                      ? null
                      : (value) => save(
                          c.uiPreferences.withQuickKind(kind, value == true),
                        ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
