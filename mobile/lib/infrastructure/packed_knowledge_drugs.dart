import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../domain/knowledge.dart';

/// v2 storage adapter. All clinical fields remain literal source values.
class PackedKnowledgeDrugs {
  PackedKnowledgeDrugs(this.db, this.blob);
  final Database db;
  final Uint8List Function(int) blob;
  final _values = <int, (List<dynamic>, int)>{};
  int _cachedBytes = 0;
  (int, String, List<dynamic>)? _group;

  Never _fail() =>
      throw const KnowledgePackageException('압축 자료의 구조 또는 조회 연결이 잘못되었습니다.');

  Object? _value(int id) {
    if (id < 1) _fail();
    final group = (id - 1) ~/ 128 + 1;
    final offset = (id - 1) % 128;
    var cached = _values.remove(group);
    if (cached == null) {
      final rows = db.select('SELECT blob_id FROM value_groups WHERE id=?', [
        group,
      ]);
      if (rows.length != 1) _fail();
      final bytes = blob(rows.single['blob_id'] as int);
      final values = jsonDecode(utf8.decode(bytes)) as List;
      if (values.isEmpty || values.length > 128) _fail();
      cached = (values, bytes.length);
      _cachedBytes += bytes.length;
    }
    _values[group] = cached;
    while (_cachedBytes > 4 * 1024 * 1024 && _values.length > 1) {
      _cachedBytes -= _values.remove(_values.keys.first)!.$2;
    }
    if (offset >= cached.$1.length) _fail();
    return cached.$1[offset];
  }

  Map<String, dynamic> record(int id) {
    if (id < 1) _fail();
    var group = _group;
    if (group == null || id < group.$1 || id >= group.$1 + group.$3.length) {
      final rows = db.select(
        '''SELECT first_record,source_id,record_count,blob_id
        FROM record_groups WHERE first_record<=? ORDER BY first_record DESC LIMIT 1''',
        [id],
      );
      if (rows.length != 1) _fail();
      final row = rows.single;
      final first = row['first_record'] as int;
      final count = row['record_count'] as int;
      if (count < 1 || count > 512 || id >= first + count) _fail();
      final records =
          jsonDecode(utf8.decode(blob(row['blob_id'] as int))) as List;
      if (records.length != count) _fail();
      group = _group = (first, row['source_id'] as String, records);
    }
    final row = group.$3[id - group.$1] as List;
    if (row.length != 4 ||
        row.take(3).any((value) => value is! int) ||
        (row[0] as int) < 1 ||
        (row[1] as int) < 0) {
      _fail();
    }
    final keys = _value(row[2] as int) as List;
    final refs = row[3] as List;
    if (keys.any((key) => key is! String) ||
        keys.toSet().length != keys.length ||
        keys.length != refs.length) {
      _fail();
    }
    final result = <String, dynamic>{};
    for (var i = 0; i < keys.length; i++) {
      result[keys[i] as String] = _value(refs[i] as int);
    }
    if (utf8.encode(jsonEncode(result)).length > 16 * 1024 * 1024) _fail();
    return {
      'id': id,
      'source_id': group.$2,
      'page_no': row[0],
      'row_no': row[1],
      'item_seq': '${result['ITEM_SEQ'] ?? result['itemSeq'] ?? ''}',
      'counterpart_seq': '${result['MIXTURE_ITEM_SEQ'] ?? ''}',
      'record': result,
    };
  }

  List<Map<String, Object?>> lookup(String item, int limit) {
    final sizes = db.select(
      'SELECT length(record_ids) AS n FROM drug_lookup WHERE item_seq=?',
      [item],
    );
    if (sizes.isEmpty) return [];
    if ((sizes.single['n'] as int) > 16 * 1024 * 1024) _fail();
    final rows = db.select(
      'SELECT record_ids FROM drug_lookup WHERE item_seq=?',
      [item],
    );
    if (rows.isEmpty) return [];
    if (rows.length != 1) _fail();
    final result = <Map<String, Object?>>[];
    final bytes = rows.single['record_ids'] as Uint8List;
    if (bytes.length > 16 * 1024 * 1024) _fail();
    final selected = <int>[];
    for (final id in _ids(bytes)) {
      if (selected.length < limit) selected.add(id);
    }
    for (final id in selected) {
      final restored = record(id);
      if (restored['item_seq'] != item && restored['counterpart_seq'] != item) {
        _fail();
      }
      result.add({...restored}..remove('record'));
    }
    return result;
  }

  Iterable<int> _ids(Uint8List bytes) sync* {
    var previous = 0, value = 0, shift = 0;
    for (final byte in bytes) {
      value |= (byte & 127) << shift;
      if ((byte & 128) != 0) {
        shift += 7;
        if (shift > 28) _fail();
      } else {
        if (value <= 0 || previous + value > 0x7fffffff) _fail();
        previous += value;
        yield previous;
        value = shift = 0;
      }
    }
    if (shift != 0) _fail();
  }
}
