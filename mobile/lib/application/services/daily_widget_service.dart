import '../../domain/daily_widget.dart';
import '../ports.dart';

/// Serializes native publication so a late write cannot undo a privacy opt-out.
final class DailyWidgetService {
  DailyWidgetService(this._platform);
  final PlatformServices _platform;
  Future<void> _tail = Future.value();
  int _revision = 0;
  Future<void> update(DailyWidgetSnapshot? snapshot) {
    final revision = ++_revision;
    final result = _tail.then((_) async {
      if (snapshot != null && revision != _revision) return;
      await _platform.updateDailyWidget(snapshot);
    });
    _tail = result.catchError((Object _) {});
    return result;
  }
}
