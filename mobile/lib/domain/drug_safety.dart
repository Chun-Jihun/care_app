import 'knowledge.dart';

enum DrugDataState { missing, unreviewed, stale, ready }

final class DrugCatalogInfo {
  const DrugCatalogInfo(this.state, {this.releaseId = ''});
  final DrugDataState state;
  final String releaseId;
}

final class DrugProduct {
  const DrugProduct(this.code, this.name, this.manufacturer);
  final String code, name, manufacturer;
}

final class DrugProducts {
  DrugProducts(
    this.info,
    Iterable<DrugProduct> products, {
    this.truncated = false,
  }) : products = List.unmodifiable(products);
  final DrugCatalogInfo info;
  final List<DrugProduct> products;
  final bool truncated;
}

/// Device-local user confirmation, invalidated by either medication or release changes.
/// Deliberately excluded from backup: restored medication identity needs confirmation.
final class MedicationProduct {
  const MedicationProduct(
    this.code,
    this.name,
    this.releaseId,
    this.confirmedAt,
  );
  final String code, name, releaseId;
  final DateTime confirmedAt;
}

final class DurRecord {
  DurRecord({
    required this.id,
    required this.packageHash,
    required this.operation,
    required this.source,
    required this.page,
    required this.row,
    required Map<String, String> fields,
  }) : fields = Map.unmodifiable(fields);
  final int id, page, row;
  final String packageHash, operation;
  final KnowledgeSource source;
  final Map<String, String> fields;
  String get item => fields['ITEM_SEQ'] ?? '';
  String get counterpart => fields['MIXTURE_ITEM_SEQ'] ?? '';
}

final class DurRecords {
  DurRecords(Iterable<DurRecord> records, {required this.complete})
    : records = List.unmodifiable(records);
  final List<DurRecord> records;
  final bool complete;
}

abstract interface class DrugCatalog {
  Future<DrugCatalogInfo> status();
  Future<DrugProducts> search(String query);
  Future<DurRecords> records(Set<String> codes, String releaseId);
}

enum DrugCheckState {
  missing,
  unreviewed,
  stale,
  needsConfirmation,
  incomplete,
  checked,
}

/// 'checked' means source records were matched, never a clinical safety verdict.
final class DrugSafetyReport {
  DrugSafetyReport(
    this.state, {
    Iterable<DurRecord> records = const [],
    Iterable<String> repeatedProducts = const [],
  }) : records = List.unmodifiable(records),
       repeatedProducts = List.unmodifiable(repeatedProducts);
  final DrugCheckState state;
  final List<DurRecord> records;
  final List<String> repeatedProducts;
}
