import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/knowledge.dart';
import '../domain/drug_safety.dart';
import 'packed_knowledge_drugs.dart';

const _maxBlock = 16 * 1024 * 1024;
const _unreviewed = {
  'approval_state': 'staged_unreviewed',
  'clinical_review_completed': false,
  'runtime_rag_eligible': false,
  'mobile_bundle': false,
  'do_not_train': true,
};
Never _fail(String message) => throw KnowledgePackageException(message);
String _digest(List<int> bytes) => sha256.convert(bytes).toString();

/// Reads pinned offline packages with strict declared review-state checks.
/// Clinical question/passage authorization is owned by the application catalog.
/// Hashing, queries and decompression run off the Flutter UI isolate.
class LocalKnowledgePackage implements KnowledgeReviewReader {
  LocalKnowledgePackage._(this.directory, this._manifest, this._modified);
  final String directory;
  final Map<String, dynamic> _manifest;
  final DateTime _modified;
  @override
  String get packageHash => _manifest['database_sha256'] as String;
  @override
  String get kind => _manifest['kind'] as String;
  bool get _packed => _manifest['schema'] == 'care-knowledge-preview-v2';
  String get coverageNotice =>
      (_manifest['coverage'] as Map?)?['notice_ko'] as String? ??
      '개발용 미검수 자료입니다. 조회 결과가 없어도 안전을 뜻하지 않습니다.';

  static Future<LocalKnowledgePackage> openForReview(
    String directory, {
    String? expectedHash,
  }) => _open(directory, expectedHash: expectedHash, approved: false);

  /// Call only after authenticating the complete files to the app allowlist.
  /// There is no in-app promotion operation or approval inferred from a hash.
  static Future<LocalKnowledgePackage> openApproved(
    String directory, {
    required String expectedHash,
  }) => _open(directory, expectedHash: expectedHash, approved: true);

  static Future<LocalKnowledgePackage> _open(
    String directory, {
    String? expectedHash,
    required bool approved,
  }) => Isolate.run(() async {
    final states = approved
        ? <String, Object>{
            'approval_state': 'approved',
            'clinical_review_completed': true,
            'runtime_rag_eligible': true,
            'mobile_bundle': true,
            'do_not_train': true,
          }
        : _unreviewed;
    final manifestFile = File(p.join(directory, 'manifest.json'));
    if (await manifestFile.length() > 1024 * 1024) {
      _fail('패키지 정보가 허용 크기를 초과했습니다.');
    }
    final m =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    if (!const [
          'care-knowledge-preview-v1',
          'care-knowledge-preview-v2',
        ].contains(m['schema']) ||
        m['purpose'] !=
            (approved ? 'medical_reference' : 'development_preview') ||
        m['database'] != 'knowledge.sqlite3' ||
        m['codec'] != 'zlib' ||
        m['max_block_bytes'] != _maxBlock ||
        !const ['documents', 'drugs'].contains(m['kind']) ||
        (m['schema'] == 'care-knowledge-preview-v2' &&
            m['packed_layout'] != 'field_values_delta_index_v1') ||
        states.entries.any((e) => m[e.key] != e.value)) {
      _fail('지원하지 않는 패키지 또는 검수 상태입니다.');
    }
    final file = File(p.join(directory, 'knowledge.sqlite3'));
    final before = await file.stat();
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final after = await file.stat();
    if (before.size != m['database_bytes'] ||
        before.modified != after.modified ||
        before.size != after.size ||
        digest != m['database_sha256'] ||
        (expectedHash != null && expectedHash != digest)) {
      _fail('패키지 버전 또는 무결성을 확인할 수 없습니다.');
    }
    final result = LocalKnowledgePackage._(directory, m, after.modified);
    result._read((db) {
      final tables = {
        'metadata',
        'blobs',
        'sources',
        'drug_records',
        'document_pages',
        'page_assets',
        'document_search',
        'document_search_data',
        'document_search_idx',
        'document_search_docsize',
        'document_search_config',
        if (result._packed) ...['value_groups', 'record_groups', 'drug_lookup'],
      };
      final schema = db.select(
        "SELECT name,type FROM sqlite_schema WHERE type IN ('table','trigger','view')",
      );
      if (schema.length != tables.length ||
          schema.any(
            (row) => row['type'] != 'table' || !tables.contains(row['name']),
          )) {
        _fail('허용되지 않은 DB 구조입니다.');
      }
      final metadata = db.select(
        "SELECT value FROM metadata WHERE key='package'",
      );
      if (metadata.length != 1) _fail('패키지 정보가 없습니다.');
      final internal = jsonDecode(
        metadata.single['value'] as String,
      ) as Map<String, dynamic>;
      for (final key in [
        'schema',
        'purpose',
        'codec',
        'kind',
        'max_block_bytes',
        ...states.keys,
      ]) {
        if (internal[key] != m[key]) _fail('패키지 내부 정보가 일치하지 않습니다.');
      }
      for (final entry in internal.entries) {
        if (jsonEncode(_canonical(entry.value)) !=
            jsonEncode(_canonical(m[entry.key]))) {
          _fail('패키지의 지원 범위 또는 내부 정보가 일치하지 않습니다.');
        }
      }
    });
    return result;
  });

  T _read<T>(T Function(Database db) action) {
    final file = File(p.join(directory, 'knowledge.sqlite3'));
    final stat = file.statSync();
    if (stat.size != _manifest['database_bytes'] ||
        stat.modified != _modified) {
      _fail('패키지가 변경되었습니다. 다시 열어 주세요.');
    }
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      db.execute(
        'PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; PRAGMA cache_size=-4096; BEGIN',
      );
      return action(db);
    } finally {
      db.close();
    }
  }

  @override
  Future<List<KnowledgeSource>> sources() => Isolate.run(
    () => _read(
      (db) => [
        for (final row in db.select('SELECT id FROM sources ORDER BY id'))
          _source(db, row['id'] as String),
      ],
    ),
  );

  @override
  Future<List<KnowledgeHit>> searchDocuments(String query) => Isolate.run(
    () => _read((db) {
      // Quote each token so user punctuation cannot become FTS operators.
      final terms = RegExp(r'[\p{L}\p{N}]+', unicode: true)
          .allMatches(query.length > 300 ? query.substring(0, 300) : query)
          .take(12)
          .map((m) => '"${m.group(0)}"')
          .toList();
      if (terms.isEmpty) return <KnowledgeHit>[];
      final rows = db.select(
        '''SELECT p.* FROM document_search f
      JOIN document_pages p ON p.id=f.rowid
      WHERE document_search MATCH ? ORDER BY rank LIMIT 30''',
        [terms.join(' AND ')],
      );
      return [
        for (final row in rows)
          KnowledgeHit(
            _source(db, row['source_id'] as String).title,
            _citation(row),
          ),
      ];
    }),
  );

  KnowledgeCitation _citation(Row row) => KnowledgeCitation(
    packageHash: packageHash,
    sourceId: row['source_id'] as String,
    pageNumber: row['page_no'] as int,
    textHash: row['text_sha256'] as String,
  );

  @override
  Future<KnowledgeDocument> document(String sourceId, int pageNumber) =>
      Isolate.run(
        () => _read((db) {
          final rows = db.select(
            'SELECT * FROM document_pages WHERE source_id=? AND page_no=?',
            [sourceId, pageNumber],
          );
          if (rows.length != 1) _fail('이 버전에서 해당 페이지를 찾을 수 없습니다.');
          final row = rows.single;
          final raw = _blob(db, row['text_blob'] as int);
          if (_digest(raw) != row['text_sha256']) _fail('본문 무결성을 확인할 수 없습니다.');
          final imageId = row['image_blob'] as int?;
          return KnowledgeDocument(
            source: _source(db, sourceId),
            citation: _citation(row),
            text: utf8.decode(raw),
            pageImage: imageId == null ? null : _blob(db, imageId),
            assets: [
              for (final asset in db.select(
                'SELECT * FROM page_assets WHERE page_id=? ORDER BY ordinal',
                [row['id']],
              ))
                KnowledgeAsset(
                  _blob(db, asset['blob_id'] as int),
                  asset['description'] as String,
                ),
            ],
          );
        }),
      );

  @override
  Future<KnowledgeDocument> resolve(KnowledgeCitation citation) async {
    if (citation.packageHash != packageHash) {
      _fail('다른 버전의 근거입니다. 당시의 패키지가 필요합니다.');
    }
    final result = await document(citation.sourceId, citation.pageNumber);
    final excerpt = citation.excerpt;
    final start = citation.excerptStart;
    if (result.citation.textHash != citation.textHash ||
        (excerpt == null && start != null) ||
        (excerpt != null &&
            (excerpt.isEmpty ||
                start == null ||
                start < 0 ||
                start + excerpt.length > result.text.length ||
                result.text.substring(start, start + excerpt.length) !=
                    excerpt))) {
      _fail('인용 구절과 원문이 일치하지 않습니다.');
    }
    return KnowledgeDocument(
      source: result.source,
      citation: citation,
      text: result.text,
      pageImage: result.pageImage,
      assets: result.assets,
    );
  }

  /// Both directions are retained. An empty list is NOT an interaction clearance.
  Future<List<Map<String, Object?>>> lookupDrug(
    String itemSeq, {
    int limit = 20,
  }) => Isolate.run(
    () => _read((db) {
      if (itemSeq.isEmpty || itemSeq.length > 100 || limit < 1 || limit > 100) {
        _fail('조회 범위를 확인해 주세요.');
      }
      if (_packed) {
        return PackedKnowledgeDrugs(
          db,
          (id) => _blob(db, id),
        ).lookup(itemSeq, limit);
      }
      return [
        for (final row in db.select(
          '''SELECT id,source_id,item_seq,counterpart_seq,page_no,row_no
      FROM drug_records WHERE item_seq=? OR counterpart_seq=? ORDER BY id LIMIT ?''',
          [itemSeq, itemSeq, limit],
        ))
          Map<String, Object?>.from(row),
      ];
    }),
  );

  Future<Map<String, dynamic>> drugRecord(int id) => Isolate.run(
    () => _read((db) {
      if (_packed) {
        return PackedKnowledgeDrugs(
              db,
              (ref) => _blob(db, ref),
            ).record(id)['record']
            as Map<String, dynamic>;
      }
      final rows = db.select('SELECT * FROM drug_records WHERE id=?', [id]);
      if (rows.length != 1) _fail('해당 레코드가 없습니다.');
      final row = rows.single;
      final record = <String, dynamic>{};
      var total = 0;
      for (final column in ['left_blob', 'right_blob', 'rest_blob']) {
        final fields =
            jsonDecode(utf8.decode(_blob(db, row[column] as int))) as List;
        for (final field in fields) {
          final parts = field as List;
          if (parts.length != 3 ||
              parts[0] is! String ||
              record.containsKey(parts[0])) {
            _fail('잘못된 레코드 구조입니다.');
          }
          dynamic value = parts[2];
          if (parts[1] == 1) {
            final refs = value as List;
            if (refs.length > 2048) _fail('레코드 크기를 초과했습니다.');
            final bytes = BytesBuilder(copy: false);
            for (final ref in refs) {
              final raw = _blob(db, ref as int);
              total += raw.length;
              if (total > _maxBlock) _fail('레코드 크기를 초과했습니다.');
              bytes.add(raw);
            }
            value = utf8.decode(bytes.takeBytes());
          } else if (parts[1] != 0) {
            _fail('지원하지 않는 레코드 형식입니다.');
          }
          record[parts[0] as String] = value;
        }
      }
      if (_digest(utf8.encode(jsonEncode(_canonical(record)))) !=
          row['record_sha256']) {
        _fail('레코드 원문이 일치하지 않습니다.');
      }
      return record;
    }),
  );

  /// Product identity only; no inference about equivalence, dosage or safety.
  /// Entire normalized names match; partial names return candidates requiring
  /// user selection. Packed records are scanned in order off the UI isolate.
  Future<DrugNameMatches> findDrugName(String query) => Isolate.run(
    () => _read((db) {
      final key = _drugName(query);
      if (key.length < 2 || key.length > 200) {
        return const DrugNameMatches([], false);
      }
      final exact = <String, DrugIdentity>{},
          partial = <String, DrugIdentity>{};
      var exactTruncated = false, partialTruncated = false;
      void consider(Map<String, dynamic> record) {
        final code = '${record['ITEM_SEQ'] ?? record['itemSeq'] ?? ''}';
        final name = '${record['ITEM_NAME'] ?? record['itemName'] ?? ''}';
        if (code.isEmpty || name.isEmpty) return;
        final normalized = _drugName(name);
        final candidate = DrugIdentity(code, name);
        if (code == query.trim() || normalized == key) {
          if (exact.containsKey(code)) return;
          if (exact.length < 21) {
            exact[code] = candidate;
          } else {
            exactTruncated = true;
          }
        } else if (normalized.contains(key)) {
          if (partial.containsKey(code)) return;
          if (partial.length < 21) {
            partial[code] = candidate;
          } else {
            partialTruncated = true;
          }
        }
      }

      if (_packed) {
        final packed = PackedKnowledgeDrugs(db, (id) => _blob(db, id));
        for (final group in db.select(
          'SELECT first_record,record_count FROM record_groups ORDER BY first_record',
        )) {
          final first = group['first_record'] as int;
          final count = group['record_count'] as int;
          if (count < 1 || count > 512) _fail('제품 식별 목록을 확인할 수 없습니다.');
          for (var id = first; id < first + count; id++) {
            consider(packed.record(id)['record'] as Map<String, dynamic>);
          }
        }
      } else {
        for (final row in db.select(
          'SELECT item_seq,item_name FROM drug_records ORDER BY id',
        )) {
          consider({
            'ITEM_SEQ': row['item_seq'],
            'ITEM_NAME': row['item_name'],
          });
        }
      }
      final selected = exact.isNotEmpty ? exact : partial;
      final unique = selected.values.toList();
      return DrugNameMatches(
        unique.take(20).toList(),
        exact.isNotEmpty,
        truncated:
            unique.length > 20 ||
            (exact.isNotEmpty ? exactTruncated : partialTruncated),
      );
    }),
  );

  Never clinicalContext(String question) =>
      _fail('의료 답변에는 승인된 발췌 선택 경로를 사용해야 합니다.');

  /// Bounded full rows in one worker; truncation is explicit and never a clean result.
  Future<DurRecords> drugSafetyRows(Set<String> codes) => Isolate.run(
    () => _read((db) {
      if (!_packed ||
          codes.isEmpty ||
          codes.length > 30 ||
          codes.any((c) => !RegExp(r'^\d{9}$').hasMatch(c))) {
        _fail('지원하지 않는 약물 조회입니다.');
      }
      final packed = PackedKnowledgeDrugs(db, (id) => _blob(db, id));
      final selected = <int>{};
      var complete = true;
      for (final code in codes) {
        final rows = packed.lookup(code, 1001);
        if (rows.length > 1000) complete = false;
        selected.addAll(rows.take(1000).map((r) => r['id'] as int));
        if (selected.length > 3000) return DurRecords([], complete: false);
      }
      final records = <DurRecord>[];
      for (final id in selected) {
        final row = packed.record(id);
        final sourceId = row['source_id'] as String;
        final meta = jsonDecode(
          db.select('SELECT metadata FROM sources WHERE id=?', [
                sourceId,
              ]).single['metadata']
              as String,
        ) as Map;
        records.add(
          DurRecord(
            id: id,
            packageHash: packageHash,
            operation: meta['operation'] as String? ?? '',
            source: _source(db, sourceId),
            page: row['page_no'] as int,
            row: row['row_no'] as int,
            fields: (row['record'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(key, value?.toString() ?? ''),
            ),
          ),
        );
      }
      return DurRecords(records, complete: complete);
    }),
  );

  Future<Set<String>> drugOperations() => Isolate.run(
    () => _read(
      (db) => {
        for (final row in db.select('SELECT metadata FROM sources'))
          (jsonDecode(row['metadata'] as String) as Map)['operation']
                  as String? ??
              '',
      },
    ),
  );
}

String _drugName(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'\s+'), '');

class DrugIdentity {
  const DrugIdentity(this.code, this.name);
  final String code, name;
}

class DrugNameMatches {
  const DrugNameMatches(this.candidates, this.exact, {this.truncated = false});
  final List<DrugIdentity> candidates;
  final bool exact, truncated;
  DrugIdentity? get identified =>
      exact && !truncated && candidates.length == 1 ? candidates.single : null;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

KnowledgeSource _source(Database db, String id) {
  final rows = db.select('SELECT metadata FROM sources WHERE id=?', [id]);
  if (rows.length != 1) _fail('출처 정보를 찾을 수 없습니다.');
  final text = rows.single['metadata'] as String;
  if (text.length > 4 * 1024 * 1024) _fail('출처 정보가 너무 큽니다.');
  final m = jsonDecode(text) as Map<String, dynamic>;
  final count =
      db.select('SELECT count(*) AS n FROM document_pages WHERE source_id=?', [
            id,
          ]).single['n']
          as int;
  return KnowledgeSource(
    id: id,
    title: m['title'] as String? ?? id,
    publisher: m['publisher'] as String? ?? '',
    url: m['url'] as String? ?? '',
    version: m['source_sha256'] as String? ?? m['snapshot_id'] as String? ?? '',
    pageCount: count,
    publicationDate: m['publication_or_revision_date'] as String?,
    reviewDate: m['clinical_reviewed_at'] as String?,
    rasterDpi: m['raster_dpi'] as int?,
  );
}

Uint8List _blob(Database db, int id) {
  // Check lengths before materializing the SQLite BLOB.
  final lengths = db.select(
    'SELECT raw_size,length(payload) AS size FROM blobs WHERE id=?',
    [id],
  );
  if (lengths.length != 1) _fail('내용 블록이 없습니다.');
  final size = lengths.single['raw_size'] as int;
  if (size < 0 ||
      size > _maxBlock ||
      (lengths.single['size'] as int) > _maxBlock) {
    _fail('내용 블록 크기를 초과했습니다.');
  }
  final row = db.select('SELECT payload,sha256 FROM blobs WHERE id=?', [
    id,
  ]).single;
  final sink = _BoundedBytes(size);
  final decoder = ZLibDecoder().startChunkedConversion(sink);
  decoder.add(row['payload'] as Uint8List);
  decoder.close();
  final bytes = sink.result;
  if (bytes.length != size || _digest(bytes) != row['sha256']) {
    _fail('내용 블록이 손상되었습니다.');
  }
  return bytes;
}

class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  int _length = 0;
  Uint8List get result => _bytes.takeBytes();
  @override
  void add(List<int> data) {
    _length += data.length;
    if (_length > limit) _fail('압축 해제 크기를 초과했습니다.');
    _bytes.add(data);
  }

  @override
  void close() {}
}
