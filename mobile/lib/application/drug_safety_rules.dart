import '../domain/drug_safety.dart';

/// Matches official identifiers only. Does not calculate doses, infer conditions,
/// or decide whether an age/pregnancy/efficacy-group caution applies to a person.
final class DrugSafetyRules {
  static const pairOperation = 'getUsjntTabooInfoList03';
  static const operations = {
    pairOperation,
    'getDurPrdlstInfoList03',
    'getOdsnAtentInfoList03',
    'getSpcifyAgrdeTabooInfoList03',
    'getCpctyAtentInfoList03',
    'getMdctnPdAtentInfoList03',
    'getEfcyDplctInfoList03',
    'getSeobangjeongPartitnAtentInfoList03',
    'getPwnmTabooInfoList03',
  };
  static DrugSafetyReport match(List<String> codes, DurRecords data) {
    if (!data.complete ||
        data.records.any(
          (r) =>
              !operations.contains(r.operation) ||
              !RegExp(r'^\d{9}$').hasMatch(r.item) ||
              (r.operation == pairOperation &&
                  !RegExp(r'^\d{9}$').hasMatch(r.counterpart)),
        )) {
      return DrugSafetyReport(DrugCheckState.incomplete);
    }
    final selected = codes.toSet();
    final seen = <String>{};
    return DrugSafetyReport(
      DrugCheckState.checked,
      repeatedProducts: selected.where(
        (code) => codes.where((c) => c == code).length > 1,
      ),
      records: data.records.where((r) {
        if (!seen.add('${r.packageHash}:${r.id}')) return false;
        if (r.operation == pairOperation) {
          return r.item.isNotEmpty &&
              r.counterpart.isNotEmpty &&
              selected.contains(r.item) &&
              selected.contains(r.counterpart);
        }
        return selected.contains(r.item);
      }),
    );
  }
}
