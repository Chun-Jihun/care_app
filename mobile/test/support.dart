import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/infrastructure/platform_services.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  String? rejectKey;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (key == rejectKey) {
      throw StateError('injected write failure');
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class FakePlatform extends PlatformServices {
  bool permission = true, auth = true, scheduleFails = false;
  List<Reminder> reminders = [];
  @override
  Future<bool> authenticate() async => auth;
  @override
  Future<bool> requestNotifications() async => permission;
  @override
  Future<void> schedule(List<Reminder> next) async {
    if (scheduleFails) {
      throw StateError('injected notification failure');
    }
    reminders = next;
  }
}
