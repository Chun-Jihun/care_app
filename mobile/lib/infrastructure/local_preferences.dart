import '../application/ports.dart';
import '../domain/ui_preferences.dart';

final class LocalPreferences implements DevicePreferences {
  LocalPreferences(this._secrets);
  final SecretStore _secrets;
  @override
  Future<UiPreferences> load() async =>
      UiPreferences.decode(await _secrets.read('app.ui_preferences'));
  @override
  Future<void> save(UiPreferences value) =>
      _secrets.write('app.ui_preferences', value.encode());
}
