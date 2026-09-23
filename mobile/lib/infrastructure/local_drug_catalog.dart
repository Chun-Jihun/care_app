import '../application/drug_safety_rules.dart';
import '../domain/drug_safety.dart';
import '../domain/knowledge.dart';
import 'knowledge_store.dart';

/// Only the current app-pinned package may be used. No live API or model calls.
final class LocalDrugCatalog implements DrugCatalog {
  LocalDrugCatalog(this.store);
  final KnowledgeStore store;
  @override
  Future<DrugCatalogInfo> status() async {
    final installed = await store.status();
    final release = installed.active;
    if (installed.damaged) throw const FormatException('Damaged drug catalog');
    if (release == null) return const DrugCatalogInfo(DrugDataState.missing);
    return DrugCatalogInfo(
      (release.stale(DateTime.now()) ||
              release.checkedAt.isAfter(DateTime.now()))
          ? DrugDataState.stale
          : release.preview
          ? DrugDataState.unreviewed
          : DrugDataState.ready,
      releaseId: release.id,
    );
  }

  Future<void> _unchanged(String id) async {
    if ((await status()).releaseId != id) {
      throw const FormatException('Drug catalog changed');
    }
  }

  @override
  Future<DrugProducts> search(String query) async {
    final info = await status();
    if (info.state == DrugDataState.missing ||
        info.state == DrugDataState.stale) {
      return DrugProducts(info, []);
    }
    final permits = await store.reader(kind: 'permits');
    if (permits == null) throw const FormatException('Product catalog missing');
    final matches = await permits.findDrugName(query);
    final products = <DrugProduct>[];
    for (final match in matches.candidates) {
      final rows = await permits.lookupDrug(match.code);
      if (rows.length != 1) continue;
      final record = await permits.drugRecord(rows.single['id'] as int);
      if (record['CANCEL_NAME'] != '정상' ||
          '${record['CANCEL_DATE'] ?? ''}'.isNotEmpty) {
        continue;
      }
      products.add(
        DrugProduct(match.code, match.name, '${record['ENTP_NAME'] ?? ''}'),
      );
    }
    await _unchanged(info.releaseId);
    return DrugProducts(info, products, truncated: matches.truncated);
  }

  @override
  Future<DurRecords> records(Set<String> codes, String releaseId) async {
    final info = await status();
    if (info.state != DrugDataState.ready || info.releaseId != releaseId) {
      throw const FormatException('Reviewed current drug catalog required');
    }
    final dur = await store.reader(kind: 'dur');
    final permits = await store.reader(kind: 'permits');
    if (dur == null || permits == null) {
      throw const FormatException('Drug catalog missing');
    }
    final now = DateTime.now();
    bool reviewed(KnowledgeSource source) {
      final date = DateTime.tryParse(source.reviewDate ?? '');
      return date != null &&
          !date.isAfter(now) &&
          source.title.isNotEmpty &&
          source.publisher.isNotEmpty &&
          Uri.tryParse(source.url)?.scheme == 'https';
    }

    final sources = [...await dur.sources(), ...await permits.sources()];
    final operations = await dur.drugOperations();
    if (sources.isEmpty ||
        !sources.every(reviewed) ||
        !operations.containsAll(DrugSafetyRules.operations) ||
        !DrugSafetyRules.operations.containsAll(operations)) {
      return DurRecords([], complete: false);
    }
    final rows = await dur.drugSafetyRows(codes);
    await _unchanged(releaseId);
    return rows;
  }
}
