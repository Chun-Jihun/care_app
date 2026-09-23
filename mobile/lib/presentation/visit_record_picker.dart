import 'dart:async';

import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';
import 'common.dart';

/// Selections belong to this route until the user explicitly applies them.
class VisitRecordPicker extends StatefulWidget {
  const VisitRecordPicker({
    super.key,
    required this.c,
    required this.patientId,
    required this.selected,
  });
  final CareController c;
  final String patientId;
  final Set<String> selected;
  @override
  State<VisitRecordPicker> createState() => _VisitRecordPickerState();
}

class _VisitRecordPickerState extends State<VisitRecordPicker> {
  late final selected = {...widget.selected};
  final search = TextEditingController();
  DateTimeRange? range;
  int limit = 30;
  String query = '';
  Timer? debounce;
  Object? loadedFilter;
  List<CareEntry> matches = const [];
  @override
  void dispose() {
    search.dispose();
    debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final end = range == null
        ? null
        : DateTime(range!.end.year, range!.end.month, range!.end.day + 1);
    final filter = (query, range?.start, end, limit, context.strings.language);
    if (loadedFilter != filter) {
      matches = widget.c.records.entries(
        widget.patientId,
        from: range?.start,
        until: end,
        query: query,
        limit: limit + 1,
        displayText: (e) =>
            '${context.tr(e.kind.label)} ${context.strings.summary(e)}',
      );
      loadedFilter = filter;
    }
    final shown = matches.take(limit).toList();
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('함께 볼 기록'))),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: shown.length + 2,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: search,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: context.tr('기록 검색'),
                          prefixIcon: const Icon(Icons.search),
                        ),
                        onChanged: (value) {
                          debounce?.cancel();
                          debounce = Timer(
                            const Duration(milliseconds: 200),
                            () {
                              if (!mounted) return;
                              setState(() {
                                query = value.trim();
                                limit = 30;
                              });
                            },
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.date_range),
                        label: Text(
                          range == null
                              ? context.tr('전체 기간')
                              : '${dateText(context, range!.start)} ~ ${dateText(context, range!.end)}',
                        ),
                        onPressed: () async {
                          final value = await showDateRangePicker(
                            context: context,
                            useRootNavigator: false,
                            initialDateRange: range,
                            firstDate: DateTime(1900),
                            lastDate: DateTime(2100, 12, 31),
                          );
                          if (mounted && value != null) {
                            setState(() {
                              range = value;
                              limit = 30;
                            });
                          }
                        },
                      ),
                      if (range != null)
                        TextButton(
                          onPressed: () => setState(() {
                            range = null;
                            limit = 30;
                          }),
                          child: Text(context.tr('전체 기간으로 변경')),
                        ),
                      Text(context.tr('검색해도 선택한 기록은 유지됩니다.')),
                      if (matches.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Text(context.tr('조건에 맞는 기록이 없어요.')),
                        ),
                    ],
                  );
                }
                if (index == shown.length + 1) {
                  return matches.length > limit
                      ? OutlinedButton(
                          onPressed: () => setState(() => limit += 30),
                          child: Text(context.tr('기록 더 보기')),
                        )
                      : const SizedBox(height: 12);
                }
                final e = shown[index - 1];
                return CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: selected.contains(e.id),
                  title: Text(
                    '${dateText(context, e.occurredAt)} ${context.tr(e.kind.label)}',
                  ),
                  subtitle: Text(
                    context.strings.summary(e),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      selected.add(e.id);
                    } else {
                      selected.remove(e.id);
                    }
                  }),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: Text(context.tr('선택한 기록 {0}개 적용', [selected.length])),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
