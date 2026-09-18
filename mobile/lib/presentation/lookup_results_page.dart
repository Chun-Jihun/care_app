import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/record_lookup.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'common.dart';
import 'details.dart';

class LookupScopeView extends StatelessWidget {
  const LookupScopeView(this.lookup, {super.key});
  final RecordLookup lookup;
  @override
  Widget build(BuildContext context) {
    String time(int minute) =>
        '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('조회 기간: {0} ~ {1}', [
            RecordLookup.date(lookup.start),
            RecordLookup.date(
              DateTime(lookup.end.year, lookup.end.month, lookup.end.day - 1),
            ),
          ]),
        ),
        if (lookup.fromMinute != 0 || lookup.untilMinute != 1440)
          Text(
            context.tr('조회 시각: {0}', [
              lookup.untilMinute == lookup.fromMinute + 1
                  ? time(lookup.fromMinute)
                  : '${time(lookup.fromMinute)} ~ ${time(lookup.untilMinute - 1)}',
            ]),
          ),
        Text(
          context.tr('조회 항목: {0}', [
            lookup.item.isNotEmpty
                ? lookup.item
                : context.tr(
                    lookup.requiredField == 'water_ml'
                        ? '수분 (mL)'
                        : lookup.kind?.label ?? '전체',
                  ),
          ]),
        ),
        if (lookup.intakeStatus.isNotEmpty)
          Text(
            context.tr('조회 복용 상태: {0}', [
              context.tr(intakeLabels[lookup.intakeStatus]!),
            ]),
          ),
      ],
    );
  }
}

/// Re-runs the same filter against current records; never rewrites old citations.
class LookupResultsPage extends StatefulWidget {
  const LookupResultsPage(this.c, this.pid, this.lookup, {super.key});
  final CareController c;
  final String pid;
  final RecordLookup lookup;
  @override
  State<LookupResultsPage> createState() => _LookupResultsPageState();
}

class _LookupResultsPageState extends State<LookupResultsPage> {
  int limit = 50;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.c,
    builder: (context, _) {
      final c = widget.c;
      if (!c.unlocked || c.selectedId != widget.pid) {
        return const SizedBox.shrink();
      }
      final entries = c.records.lookup(
        widget.pid,
        widget.lookup,
        limit: limit + 1,
      );
      final shown = entries.take(limit).toList();
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('기록 조회 결과'))),
        body: SafeArea(
          child: ListView.builder(
            padding: const EdgeInsets.all(20),
            itemCount: shown.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LookupScopeView(widget.lookup),
                    const SizedBox(height: 12),
                    Text(
                      context.tr(
                        '같은 조건으로 현재 저장된 기록을 조회합니다. 수정·삭제된 내용은 이전 답변과 다를 수 있어요.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      entries.length > limit
                          ? context.tr('{0}건 이상', [limit])
                          : context.tr('{0}건', [entries.length]),
                    ),
                    if (entries.isEmpty)
                      Text(
                        context.tr(
                          '일치하는 기록을 찾지 못했어요. 기록이 없다는 것이 실제로 하지 않았다는 뜻은 아닙니다.',
                        ),
                      ),
                  ],
                );
              }
              if (index == shown.length + 1) {
                return entries.length > limit
                    ? OutlinedButton(
                        onPressed: () => setState(() => limit += 50),
                        child: Text(context.tr('기록 더 보기')),
                      )
                    : const SizedBox(height: 20);
              }
              final entry = shown[index - 1];
              return EntryTile(
                entry,
                onTap: () => pushPage(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => EntryDetails(c, widget.pid, entry.id),
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}
