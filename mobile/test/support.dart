import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:care_notebook/application/care_controller.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:care_notebook/infrastructure/vault_store.dart';
import 'package:care_notebook/infrastructure/platform_services.dart';

// Fixture access is deliberately confined to tests. Production consumers use
// feature services and cannot retrieve storage or device implementations.
final _vaults = Expando<VaultStore>();
final _platforms = Expando<PlatformServices>();
CareController testController(VaultStore vault, PlatformServices platform) {
  final controller = CareController(vault, platform);
  _vaults[controller] = vault;
  _platforms[controller] = platform;
  return controller;
}

VaultStore testVault(CareController controller) => _vaults[controller]!;
CareDatabase testRepository(CareController controller) =>
    testVault(controller).repository as CareDatabase;
PlatformServices testPlatform(CareController controller) =>
    _platforms[controller]!;

void withFixtureSql(
  Directory root,
  MemorySecrets secrets,
  void Function(Database) action,
) {
  final markers =
      Directory('${root.path}/commits')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.commit'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final generation = markers.last.readAsStringSync().trim();
  final keys = jsonDecode(secrets.values['vault.$generation']!) as Map;
  final key = base64Decode(keys['care'] as String)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final connection = sqlite3.open('${root.path}/$generation/care.db');
  try {
    connection.execute('PRAGMA key="x\'$key\'"');
    action(connection);
  } finally {
    connection.close();
  }
}

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  String? rejectKey;
  String? rejectDeleteKey;
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
    if (key == rejectDeleteKey) throw StateError('injected delete failure');
    values.remove(key);
  }
}

class FakePlatform extends PlatformServices {
  int timeZoneCalls = 0;
  @override
  Future<String> timeZone() async {
    timeZoneCalls++;
    return 'Asia/Seoul';
  }

  @override
  Future<Uint8List?> pickPhoto({bool camera = false}) async => null;
  @override
  Future<void> saveBackup(Uint8List data) async {}
  @override
  Future<Uint8List?> pickBackup() async => null;
  @override
  Future<void> dial(String number) async {}
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
