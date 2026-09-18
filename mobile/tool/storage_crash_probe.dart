import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/infrastructure/care_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

// Synthetic fixtures only. Run with `dart run tool/storage_crash_probe.dart`.
// A separate process exits without closing SQLite or committing its changes.
final careKey = Uint8List(32)..fillRange(0, 32, 23);
final identityKey = Uint8List(32)..fillRange(0, 32, 41);
String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
const careText = 'UNCOMMITTED_CARE_SENTINEL';
const identityText = 'UNCOMMITTED_IDENTITY_SENTINEL';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--writer') {
    final sql = sqlite3.open(p.join(args[1], 'care.db'));
    sql.execute('PRAGMA key="x\'${hex(careKey)}\'"');
    sql.execute(
      'ATTACH DATABASE ? AS identity KEY "x\'${hex(identityKey)}\'"',
      [p.join(args[1], 'identity.db')],
    );
    // Force dirty pages out of the tiny cache before the abrupt exit.
    sql.execute(
      'PRAGMA journal_mode=DELETE; PRAGMA identity.journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA identity.synchronous=FULL; PRAGMA cache_size=1; PRAGMA identity.cache_size=1;',
    );
    sql.execute('BEGIN IMMEDIATE');
    sql.execute('UPDATE care_entry SET note=?', [careText * 1000]);
    sql.execute('UPDATE identity.patient_identity SET alias=?', [
      identityText * 1000,
    ]);
    exit(73);
  }
  check(args.isEmpty, 'Unexpected probe arguments');
  final root = Directory.systemTemp.createTempSync('care-storage-crash-');
  CareDatabase open() =>
      CareDatabase.open(root.path, key: careKey, identityKey: identityKey);
  try {
    var db = open();
    final pid = db.createPatient(alias: 'committed identity').id;
    db.saveEntry(
      pid,
      kind: EntryKind.generalNote,
      occurredAt: DateTime(2020),
      note: 'committed care',
    );
    db.close();
    final child = await Process.start(Platform.resolvedExecutable, [
      // Reuse this VM's native-asset mapping. Nested `dart run` would try to
      // replace the SQLCipher DLL while Windows has it loaded in this process.
      ...Platform.executableArguments,
      Platform.script.toFilePath(),
      '--writer',
      root.path,
    ]);
    final output = child.stdout.drain<void>();
    final errors = child.stderr.transform(utf8.decoder).join();
    int code;
    try {
      code = await child.exitCode.timeout(const Duration(seconds: 45));
    } finally {
      child.kill();
    }
    await output;
    final diagnostics = await errors;
    check(code == 73, 'Writer failed to reach abrupt exit: $code $diagnostics');
    for (final name in ['care.db-journal', 'identity.db-journal']) {
      check(
        File(p.join(root.path, name)).existsSync(),
        'Missing rollback journal: $name',
      );
    }
    for (final file in root.listSync().whereType<File>()) {
      final contents = latin1.decode(file.readAsBytesSync());
      for (final sentinel in [
        careText,
        identityText,
        'committed care',
        'committed identity',
      ]) {
        check(!contents.contains(sentinel), 'Plaintext in DB or journal');
      }
    }
    db = open();
    try {
      check(
        db.entries(pid).single.note == 'committed care',
        'Committed care changed',
      );
      check(
        db.patients().single.alias == 'committed identity',
        'Committed identity changed',
      );
      db.verifyIntegrity();
    } finally {
      db.close();
    }
    stdout.writeln(
      'Storage crash probe passed: both encrypted journals recovered; committed data intact.',
    );
  } finally {
    // Delete only the unique temporary fixture directory created by this run.
    check(
      p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path) &&
          p.basename(root.path).startsWith('care-storage-crash-'),
      'Unsafe fixture cleanup path',
    );
    root.deleteSync(recursive: true);
  }
}
