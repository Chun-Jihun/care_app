import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../infrastructure/care_database.dart';
import 'common.dart';
import 'details.dart';
import 'editors.dart';
import 'settings.dart';
import 'chat_page.dart';
import 'draft_page.dart';

class CareShell extends StatefulWidget {
  const CareShell(this.c, {super.key});
  final CareController c;
  @override
  State<CareShell> createState() => _CareShellState();
}

class _CareShellState extends State<CareShell> {
  int tab = 0;
  EntryKind? filter;
  DateTime? day;
  String query = '';
  bool archived = false;
  final search = TextEditingController();
  Timer? searchTimer;
  int journalLimit = 50;
  CareController get c => widget.c;
  @override
  void dispose() {
    search.dispose();
    searchTimer?.cancel();
    super.dispose();
  }

  void openEntry(CareEntry entry) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => EntryDetails(c, entry.patientId, entry.id),
    ),
  );
  Future<void> chooseKind() async {
    final kind = await showModalBottomSheet<EntryKind>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('어떤 기록을 남길까요?'),
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: EntryKind.values
                    .map(
                      (k) => ActionChip(
                        avatar: Icon(kindIcon(k), size: 18),
                        label: Text(context.tr(k.label)),
                        onPressed: () => Navigator.pop(ctx, k),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
    if (kind != null && mounted) {
      await editEntry(context, c, kind);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      if (!c.unlocked) {
        return const SizedBox.shrink();
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(
            context.tr('간병수첩'),
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -1),
          ),
          actions: [
            IconButton(
              tooltip: context.tr('간병 도우미 대화'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => ChatPage(c)),
              ),
              icon: const Icon(Icons.chat_bubble_outline, size: 21),
            ),
            PopupMenuButton<String>(
              tooltip: context.tr('수첩 전환'),
              onSelected: (id) => attempt(context, () async {
                await c.selectPatient(id);
                if (!mounted) return;
                searchTimer?.cancel();
                setState(() {
                  journalLimit = 50;
                  search.clear();
                  query = '';
                  filter = null;
                  day = null;
                });
              }),
              itemBuilder: (_) => c.patients
                  .map(
                    (p) => PopupMenuItem(
                      value: p.id,
                      child: Text(context.strings.patient(p)),
                    ),
                  )
                  .toList(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline, size: 18),
                    const SizedBox(width: 5),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Text(
                        context.strings.patient(c.patient),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    const Icon(Icons.expand_more, size: 18),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: context.tr('잠그기'),
              onPressed: c.lock,
              icon: const Icon(Icons.lock_outline, size: 20),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Padding(
            // Keep the primary action in its own area so it cannot cover a
            // task checkbox, delete button or the final row while scrolling.
            padding: EdgeInsets.only(bottom: tab == 4 ? 0 : 80),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  key: ValueKey('$tab-${c.selectedId}'),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    if (c.db.draftCount(c.selectedId) > 0 ||
                        c.db.draftCount(null) > 0)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.edit_note, color: forest),
                          title: Text(context.tr('작성 중인 초안이 있어요')),
                          subtitle: Text(context.tr('확인하고 이어서 작성하기')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => DraftPage(c),
                            ),
                          ),
                        ),
                      ),
                    if (c.notice != null)
                      Card(
                        color: const Color(0xFFFFF1DB),
                        child: ListTile(
                          title: Text(context.tr(c.notice!)),
                          trailing: IconButton(
                            tooltip: context.tr('안내 닫기'),
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => c.notice = null),
                          ),
                        ),
                      ),
                    ...switch (tab) {
                      0 => today(),
                      1 => journal(),
                      2 => meds(),
                      3 => visits(),
                      _ => settingsContent(context, c),
                    },
                  ],
                ),
              ),
            ),
          ),
        ),
        floatingActionButton: tab == 4
            ? null
            : FloatingActionButton.extended(
                onPressed: () => switch (tab) {
                  2 => editMedication(context, c),
                  3 => editVisit(context, c),
                  _ => chooseKind(),
                },
                icon: const Icon(Icons.add),
                label: Text(
                  tab == 2
                      ? context.tr('약 추가')
                      : tab == 3
                      ? context.tr('진료 준비')
                      : context.tr('기록하기'),
                ),
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (value) => setState(() => tab = value),
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.grid_view_outlined),
              selectedIcon: Icon(Icons.grid_view_rounded),
              label: context.tr('오늘'),
            ),
            NavigationDestination(
              icon: Icon(Icons.auto_stories_outlined),
              selectedIcon: Icon(Icons.auto_stories),
              label: context.tr('일기'),
            ),
            NavigationDestination(
              icon: Icon(Icons.medication_outlined),
              selectedIcon: Icon(Icons.medication),
              label: context.tr('약'),
            ),
            NavigationDestination(
              icon: Icon(Icons.assignment_outlined),
              selectedIcon: Icon(Icons.assignment),
              label: context.tr('진료 준비'),
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: context.tr('설정'),
            ),
          ],
        ),
      );
    },
  );
  List<Widget> today() {
    final now = DateTime.now();
    final entries = c.db.entries(c.selectedId!, day: now);
    final recent = c.db.entries(c.selectedId!, limit: 5);
    final tasks = c.tasks;
    final water = entries
        .where((e) => e.kind == EntryKind.meal)
        .fold<double>(
          0,
          (sum, e) => sum + (double.tryParse(e.fields['water_ml'] ?? '') ?? 0),
        );
    final taken = entries
        .where(
          (e) =>
              e.kind == EntryKind.medicationIntake &&
              e.fields['status'] == 'taken',
        )
        .length;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.strings.day(now),
              style: const TextStyle(color: Color(0xFF68796E)),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr('오늘의 돌봄'),
              style: Theme.of(context).textTheme.headlineLarge
                  ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
            ),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: forest,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.spa_outlined, color: Color(0xFFBDDAB9)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.tr('차곡차곡, 오늘의 기록'),
                    style: TextStyle(color: Color(0xFFD5E8CE)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              entries.isEmpty
                  ? context.tr('작은 변화부터\n편하게 남겨 보세요.')
                  : context.tr('오늘 {0}개의 기록을\n차곡차곡 남겼어요.', [entries.length]),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 25,
                height: 1.4,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: stat(
                    context.tr('수분 기록'),
                    '${water.toStringAsFixed(water % 1 == 0 ? 0 : 1)} mL',
                  ),
                ),
                Container(width: 1, height: 42, color: Colors.white24),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: stat(
                      context.tr('복용함 기록'),
                      context.tr('{0}건', [taken]),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              context.tr('입력된 기록의 합계입니다.'),
              style: TextStyle(color: Color(0xFFD5E8CE), fontSize: 12),
            ),
          ],
        ),
      ),
      Section(context.tr('빠르게 남기기')),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children:
            [
                  EntryKind.meal,
                  EntryKind.medicationIntake,
                  EntryKind.symptom,
                  EntryKind.activity,
                ]
                .map(
                  (k) => ActionChip(
                    avatar: Icon(kindIcon(k), size: 18, color: forest),
                    label: Text(context.tr(k.label)),
                    onPressed: () => editEntry(context, c, k),
                  ),
                )
                .toList(),
      ),
      Section(
        context.tr('할 일'),
        action: context.tr('추가'),
        onAction: () => editTask(context, c),
      ),
      if (tasks.isEmpty)
        EmptyCard(
          context.tr('기억할 일을 적어 두세요'),
          context.tr('진료 일정, 준비물, 생활 속 할 일을 관리할 수 있어요.'),
          icon: Icons.check_circle_outline,
        ),
      ...tasks.map(taskCard),
      Section(context.tr('최근 기록')),
      if (recent.isEmpty)
        EmptyCard(
          context.tr('첫 기록을 기다리고 있어요'),
          context.tr('아래 기록하기를 눌러 식사나 오늘의 상태를 남겨 보세요.'),
        ),
      ...recent.map((e) => EntryTile(e, onTap: () => openEntry(e))),
      Section(context.tr('연락이 필요할 때')),
      contactCard(context, c),
    ];
  }

  Widget stat(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xFFD5E8CE), fontSize: 12),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 23,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
  Widget taskCard(CareTask task) => Card(
    child: ListTile(
      leading: Semantics(
        label: context.tr('{0} 완료', [task.title]),
        child: Checkbox(
          value: task.done,
          onChanged: (v) => attempt(context, () async {
            await c.mutate(() => c.db.completeTask(c.selectedId!, task.id, v!));
          }),
        ),
      ),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: task.done ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text(
        '${dateText(context, task.dueAt)} ${timeText(context, task.dueAt)}${task.reminder ? context.tr(' · 알림') : ''}${task.note.isEmpty ? '' : '\n${task.note}'}',
      ),
      onTap: () => editTask(context, c, task: task),
      trailing: IconButton(
        tooltip: context.tr('할 일 삭제'),
        icon: const Icon(Icons.close, size: 19),
        onPressed: () async {
          if (await confirm(context, context.tr('할 일을 삭제할까요?'), task.title) &&
              mounted) {
            await attempt(context, () async {
              await c.mutate(() => c.db.deleteTask(c.selectedId!, task.id));
            });
          }
        },
      ),
    ),
  );
  List<Widget> journal() {
    final entries = c.db.entries(
      c.selectedId!,
      kind: filter,
      query: query,
      displayText: (entry) =>
          '${context.tr(entry.kind.label)} ${context.strings.summary(entry)}',
      day: day,
      limit: journalLimit + 1,
    );
    return [
      Section(context.tr('돌봄 일기')),
      TextField(
        controller: search,
        autocorrect: false,
        enableIMEPersonalizedLearning: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          hintText: context.tr('이 수첩의 기록 검색'),
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (v) {
          searchTimer?.cancel();
          searchTimer = Timer(const Duration(milliseconds: 250), () {
            if (mounted) {
              setState(() {
                query = v;
                journalLimit = 50;
              });
            }
          });
        },
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          spacing: 8,
          children: [
            ChoiceChip(
              label: Text(context.tr('전체')),
              selected: filter == null,
              onSelected: (_) => setState(() => filter = null),
            ),
            ...EntryKind.values.map(
              (k) => ChoiceChip(
                label: Text(context.tr(k.label)),
                selected: filter == k,
                onSelected: (_) => setState(() => filter = k),
              ),
            ),
          ],
        ),
      ),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [
          TextButton.icon(
            onPressed: () async {
              final date = await showDatePicker(
                context: context,
                useRootNavigator: false,
                initialDate: day ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (date != null && mounted) {
                setState(() => day = date);
              }
            },
            icon: const Icon(Icons.calendar_month, size: 18),
            label: Text(
              day == null ? context.tr('모든 날짜') : dateText(context, day!),
            ),
          ),
          if (day != null)
            IconButton(
              tooltip: context.tr('날짜 필터 해제'),
              onPressed: () => setState(() => day = null),
              icon: const Icon(Icons.close, size: 18),
            ),
          Text(
            entries.length > journalLimit
                ? context.tr('{0}건 이상', [journalLimit])
                : context.tr('{0}건', [entries.length]),
            style: const TextStyle(color: Color(0xFF68796E)),
          ),
        ],
      ),
      if (entries.isEmpty)
        EmptyCard(
          context.tr('표시할 기록이 없어요'),
          context.tr('새 기록을 남기거나 검색 조건을 바꿔 보세요.'),
        ),
      ...entries
          .take(journalLimit)
          .map((e) => EntryTile(e, onTap: () => openEntry(e))),
      if (entries.length > journalLimit)
        OutlinedButton(
          onPressed: () => setState(() => journalLimit += 50),
          child: Text(context.tr('기록 더 보기')),
        ),
    ];
  }

  List<Widget> meds() {
    final meds = c.db.medications(c.selectedId!, includeArchived: archived);
    return [
      Section(context.tr('약과 복약 기록')),
      Text(
        context.tr('처방받은 내용과 실제 복용 상태를 함께 관리해요.'),
        style: TextStyle(color: Color(0xFF68796E), height: 1.5),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(context.tr('보관한 약도 보기')),
        value: archived,
        onChanged: (v) => setState(() => archived = v),
      ),
      if (meds.isEmpty)
        EmptyCard(
          context.tr('약 목록을 만들어 보세요'),
          context.tr('약 이름과 전달받은 지시, 확인할 시각을 직접 적을 수 있어요.'),
          icon: Icons.medication_outlined,
        ),
      ...meds.map(
        (m) => Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.medication_outlined, color: forest),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${m.name}${m.active ? '' : context.tr(' · 보관됨')}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: context.tr('약 상세'),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              MedicationDetails(c, c.selectedId!, m.id),
                        ),
                      ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                if (m.instruction.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(m.instruction),
                  ),
                Text(
                  m.times.isEmpty
                      ? context.tr('정해둔 시각 없음')
                      : m.times.join(' · '),
                  style: const TextStyle(color: forest),
                ),
                if (m.active)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => recordIntake(context, c, m),
                      icon: const Icon(Icons.add_task, size: 18),
                      label: Text(context.tr('실제 복약 기록')),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> visits() => [
    Section(context.tr('진료를 준비해요')),
    Text(
      context.tr('물어볼 질문과 보여줄 기록을 한곳에 모아 두세요.'),
      style: TextStyle(color: Color(0xFF68796E), height: 1.5),
    ),
    const SizedBox(height: 16),
    if (c.visits.isEmpty)
      EmptyCard(
        context.tr('진료실에서 기억하기 쉽도록'),
        context.tr('직접 고른 기록의 원문을 질문 목록과 함께 볼 수 있어요.'),
        icon: Icons.assignment_outlined,
      ),
    ...c.visits.map(
      (v) => Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: const Icon(Icons.assignment_outlined, color: forest),
          title: Text(v.title),
          subtitle: Text(
            v.stale
                ? context.tr('원본이 변경되었어요 · 다시 검토해 주세요')
                : v.questions.isEmpty
                ? context.tr('선택한 기록을 확인하세요')
                : v.questions,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => VisitDetails(c, c.selectedId!, v.id),
            ),
          ),
        ),
      ),
    ),
    Section(context.tr('진료 후 남기기')),
    Card(
      child: ListTile(
        leading: const Icon(Icons.edit_note, color: forest),
        title: Text(context.tr('의료진의 설명과 다음 할 일')),
        subtitle: Text(context.tr('들은 내용을 직접 기록해 두세요.')),
        trailing: const Icon(Icons.add),
        onTap: () => editEntry(context, c, EntryKind.medicalContact),
      ),
    ),
  ];
}
