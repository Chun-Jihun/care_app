import 'package:flutter/material.dart';

import '../application/care_controller.dart';
import '../domain/drug_safety.dart';
import '../domain/records.dart';
import '../l10n/app_strings.dart';

class MedicationSafetyPage extends StatefulWidget {
  const MedicationSafetyPage(this.c, this.pid, {super.key});
  final CareController c;
  final String pid;
  @override
  State<MedicationSafetyPage> createState() => _MedicationSafetyPageState();
}

class _MedicationSafetyPageState extends State<MedicationSafetyPage> {
  DrugSafetyReport? _report;
  bool _busy = false, _error = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    widget.c.addListener(_changed);
  }

  void _changed() {
    _generation++;
    if (mounted) {
      setState(() {
        _report = null;
        _busy = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.c.removeListener(_changed);
    super.dispose();
  }

  Future<void> _check() async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = false;
      _report = null;
    });
    try {
      final result = await widget.c.medicationSafety.check(
        widget.pid,
        checkCancelled: () {
          if (!mounted || generation != _generation) {
            throw StateError('Cancelled');
          }
        },
      );
      if (mounted && generation == _generation) {
        setState(() => _report = result);
      }
    } on Object {
      if (mounted && generation == _generation) setState(() => _error = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    if (!c.unlocked || c.selectedId != widget.pid) {
      return const SizedBox.shrink();
    }
    final meds = c.medicationBook.medications(widget.pid);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('약물 주의자료 확인'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              context.tr(
                '조회 결과는 복용 가능 여부를 판단하지 않습니다. 약을 추가하거나 바꾸기 전 의사·약사에게 확인하세요.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              context.tr(
                '약 포장과 제품명·업체·품목코드를 비교해 연결하세요. 약 수정, 자료 변경, 백업 복원 후에는 다시 확인합니다.',
              ),
            ),
            for (final med in meds)
              Card(
                child: ListTile(
                  title: Text(med.name),
                  subtitle: Text(
                    med.product == null
                        ? context.tr('제품 확인 필요')
                        : '${med.product!.name}\n${med.product!.code}',
                  ),
                  isThreeLine: med.product != null,
                  onTap: _busy
                      ? null
                      : () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => _ProductPage(c, widget.pid, med),
                          ),
                        ),
                  trailing: const Icon(Icons.search),
                ),
              ),
            FilledButton(
              onPressed: _busy || meds.isEmpty ? null : _check,
              child: Text(context.tr('현재 약 목록으로 확인')),
            ),
            if (_busy) ...[
              const LinearProgressIndicator(),
              TextButton(
                onPressed: () {
                  _generation++;
                  setState(() => _busy = false);
                },
                child: Text(context.tr('취소')),
              ),
            ],
            if (_error) Text(context.tr('자료와 약 목록을 확인하지 못했습니다. 다시 시도해 주세요.')),
            if (_report case final report?) ...[
              Text(
                context.tr(switch (report.state) {
                  DrugCheckState.missing => '설치된 근거 자료가 없습니다.',
                  DrugCheckState.unreviewed => '개발용 미검수 자료 · 의료 답변 사용 불가',
                  DrugCheckState.stale => '자료의 재확인 기한이 지났습니다. 새 버전을 확인해 주세요.',
                  DrugCheckState.needsConfirmation =>
                    '현재 자료에서 모든 약의 제품을 먼저 확인해 주세요.',
                  DrugCheckState.incomplete =>
                    '전체 주의자료를 확인하지 못했습니다. 안전 여부를 판단할 수 없습니다.',
                  DrugCheckState.checked =>
                    '공식 주의자료의 일치 항목입니다. 개인에게 적용되는지는 의사·약사에게 확인하세요.',
                }),
              ),
              if (report.state == DrugCheckState.checked &&
                  report.records.isEmpty)
                Text(context.tr('일치하는 근거가 없습니다. 안전하다는 뜻은 아닙니다.')),
              for (final code in report.repeatedProducts)
                Text('${context.tr('같은 제품이 약 목록에 여러 번 연결되어 있습니다.')} $code'),
              for (final row in report.records)
                Card(
                  child: ExpansionTile(
                    title: Text(
                      row.fields['TYPE_NAME'] ??
                          row.fields['TYPE_NAME  '] ??
                          context.tr('주의자료 원문'),
                    ),
                    subtitle: Text(
                      [row.fields['ITEM_NAME'], row.fields['MIXTURE_ITEM_NAME']]
                          .whereType<String>()
                          .where((v) => v.isNotEmpty)
                          .join(' · '),
                    ),
                    childrenPadding: const EdgeInsets.all(16),
                    children: [
                      SelectableText(
                        '${row.source.title}\n${row.source.publisher}\n${row.source.url}\n'
                        '${row.operation} · ${row.page}:${row.row}\n'
                        '${context.tr('앱 내부 검수일')}: ${row.source.reviewDate}\n'
                        '${context.tr('자료 변경일')}: ${row.fields['CHANGE_DATE'] ?? ''}',
                      ),
                      const Divider(),
                      // Preserve every field, including conditional exceptions, verbatim.
                      SelectableText(
                        row.fields.entries
                            .map(
                              (e) =>
                                  '${drugFieldLabel(context, e.key)}: ${e.value}',
                            )
                            .join('\n'),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProductPage extends StatefulWidget {
  const _ProductPage(this.c, this.pid, this.medication);
  final CareController c;
  final String pid;
  final Medication medication;
  @override
  State<_ProductPage> createState() => _ProductPageState();
}

class _ProductPageState extends State<_ProductPage> {
  late final _query = TextEditingController(text: widget.medication.name);
  DrugProducts? _result;
  bool _busy = false, _error = false;
  int _generation = 0;
  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_busy) return;
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = false;
      _result = null;
    });
    try {
      final value = await widget.c.medicationSafety.search(
        widget.pid,
        _query.text,
      );
      if (mounted && generation == _generation) setState(() => _result = value);
    } on Object {
      if (mounted && generation == _generation) setState(() => _error = true);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _confirm(DrugProduct? product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('제품 연결 확인')),
        content: Text(
          product == null
              ? context.tr('제품 연결을 해제할까요?')
              : '${product.name}\n${product.manufacturer}\n${product.code}\n\n${context.tr('약 포장에 적힌 제품과 일치하나요?')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('취소')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('확인')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      await widget.c.medicationSafety.confirm(
        widget.pid,
        widget.medication,
        product,
        _result?.info.releaseId ?? '',
      );
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.c,
    builder: (context, _) {
      if (!widget.c.unlocked || widget.c.selectedId != widget.pid) {
        return const SizedBox.shrink();
      }
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('제품 연결 확인'))),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(widget.medication.name),
              Text(context.tr('품목코드는 의약품 제품을 구분하는 번호예요. 이름으로도 찾을 수 있습니다.')),
              TextField(
                controller: _query,
                maxLength: 200,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: context.tr('제품명 또는 품목코드'),
                ),
                onSubmitted: (_) => _search(),
              ),
              FilledButton(
                onPressed: _busy ? null : _search,
                child: Text(context.tr('검색')),
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error) Text(context.tr('자료와 약 목록을 확인하지 못했습니다. 다시 시도해 주세요.')),
              if (_result case final result?) ...[
                if (result.info.state == DrugDataState.unreviewed)
                  Text(context.tr('개발용 미검수 자료 · 의료 답변 사용 불가')),
                if (result.info.state == DrugDataState.stale)
                  Text(context.tr('자료의 재확인 기한이 지났습니다. 새 버전을 확인해 주세요.')),
                if (result.info.state == DrugDataState.missing)
                  Text(context.tr('설치된 근거 자료가 없습니다.')),
                if (result.products.isEmpty)
                  Text(context.tr('일치하는 제품이 없습니다. 이름을 더 정확히 입력해 주세요.')),
                if (result.truncated)
                  Text(context.tr('검색 결과가 많습니다. 제품명이나 품목코드를 더 정확히 입력해 주세요.')),
                for (final product in result.products)
                  Card(
                    child: ListTile(
                      title: Text(product.name),
                      subtitle: Text(
                        '${product.manufacturer}\n${product.code}',
                      ),
                      isThreeLine: true,
                      onTap: _busy ? null : () => _confirm(product),
                    ),
                  ),
              ],
              if (widget.medication.product != null)
                TextButton(
                  onPressed: _busy ? null : () => _confirm(null),
                  child: Text(context.tr('제품 연결 해제')),
                ),
            ],
          ),
        ),
      );
    },
  );
}

// Labels explain source fields; the authoritative values remain verbatim.
const drugFieldLabels = {
  'ITEM_SEQ': '품목코드',
  'ITEM_NAME': '제품명',
  'ENTP_NAME': '업체명',
  'TYPE_NAME': '주의 유형',
  'INGR_NAME': '성분명',
  'MIXTURE_ITEM_NAME': '함께 확인할 제품명',
  'MIXTURE_ITEM_SEQ': '함께 확인할 품목코드',
  'MIXTURE_INGR_NAME': '함께 확인할 성분명',
  'PROHBT_CONTENT': '주의 내용 원문',
  'REMARK': '비고 원문',
  'CHANGE_DATE': '자료 변경일',
  'NOTIFICATION_DATE': '공고일',
};

String drugFieldLabel(BuildContext context, String key) {
  final label = drugFieldLabels[key.trim()];
  return label == null ? key : context.tr(label);
}
