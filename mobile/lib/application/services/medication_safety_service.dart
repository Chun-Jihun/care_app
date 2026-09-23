import '../../domain/drug_safety.dart';
import '../../domain/records.dart';
import '../drug_safety_rules.dart';
import '../session_access.dart';

final class MedicationSafetyService {
  MedicationSafetyService(this._scope, this._catalog);
  final SessionAccess _scope;
  final Future<DrugCatalog> Function()? _catalog;

  Future<DrugProducts> search(String pid, String query) async {
    _scope.requirePatient(pid);
    final epoch = _scope.capture();
    final catalog = await _catalog?.call();
    final result = catalog == null
        ? DrugProducts(const DrugCatalogInfo(DrugDataState.missing), [])
        : await catalog.search(query);
    _scope.check(epoch);
    _scope.requirePatient(pid);
    return result;
  }

  Future<void> confirm(
    String pid,
    Medication medication,
    DrugProduct? product,
    String releaseId,
  ) async {
    _scope.requirePatient(pid);
    final epoch = _scope.capture();
    MedicationProduct? confirmation;
    if (product != null) {
      final result = await search(pid, product.code);
      if (result.info.releaseId != releaseId ||
          result.truncated ||
          result.products.length != 1 ||
          result.products.single.code != product.code ||
          result.products.single.name != product.name ||
          result.products.single.manufacturer != product.manufacturer) {
        throw const FormatException(
          'Product must be confirmed from the current catalog',
        );
      }
      confirmation = MedicationProduct(
        product.code,
        product.name,
        releaseId,
        DateTime.now(),
      );
    }
    _scope.check(epoch);
    await _scope.write(
      pid,
      ChangeImpact.medications,
      (repository) => repository.confirmMedicationProduct(
        pid,
        medication.id,
        medication.version,
        confirmation,
      ),
    );
  }

  Future<DrugSafetyReport> check(
    String pid, {
    void Function()? checkCancelled,
  }) async {
    _scope.requirePatient(pid);
    final epoch = _scope.capture();
    String fingerprint() => _scope.repository
        .medications(pid)
        .map(
          (m) =>
              '${m.id}:${m.version}:${m.product?.code}:${m.product?.releaseId}',
        )
        .join('|');
    final before = fingerprint();
    void check() {
      checkCancelled?.call();
      _scope.check(epoch);
      _scope.requirePatient(pid);
      if (fingerprint() != before) {
        throw CareError(CareErrorCode.medicationConflict);
      }
    }

    final catalog = await _catalog?.call();
    check();
    if (catalog == null) return DrugSafetyReport(DrugCheckState.missing);
    final info = await catalog.status();
    check();
    if (info.state != DrugDataState.ready) {
      return DrugSafetyReport(switch (info.state) {
        DrugDataState.missing => DrugCheckState.missing,
        DrugDataState.stale => DrugCheckState.stale,
        _ => DrugCheckState.unreviewed,
      });
    }
    final meds = _scope.repository.medications(pid);
    if (meds.isEmpty ||
        meds.any(
          (m) => m.product == null || m.product!.releaseId != info.releaseId,
        )) {
      return DrugSafetyReport(DrugCheckState.needsConfirmation);
    }
    if (meds.length > 30) return DrugSafetyReport(DrugCheckState.incomplete);
    final codes = meds.map((m) => m.product!.code).toList();
    final data = await catalog.records(codes.toSet(), info.releaseId);
    check();
    final after = await catalog.status();
    check();
    if (after.state != DrugDataState.ready ||
        after.releaseId != info.releaseId) {
      return DrugSafetyReport(DrugCheckState.incomplete);
    }
    return DrugSafetyRules.match(codes, data);
  }
}
