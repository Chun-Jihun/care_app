import 'sections/today.dart';
import 'sections/medications.dart';
import 'sections/visits.dart';
import '../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
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
                    if (c.drafts.count(c.selectedId) > 0 ||
                        c.drafts.count(null) > 0)
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
                            onPressed: c.dismissNotice,
                          ),
                        ),
                      ),
                    ...switch (tab) {
                      0 => todayContent(context, c, openEntry),
                      1 => journal(),
                      2 => medicationContent(
                        context,
                        c,
                        archived: archived,
                        onArchiveChanged: (value) =>
                            setState(() => archived = value),
                      ),
                      3 => visitContent(context, c),
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

  List<Widget> journal() {
    final entries = c.records.entries(
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
}
