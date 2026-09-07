enum EntryKind {
  meal('식사·수분', 'meal_entry'),
  medicationIntake('복약', 'medication_intake'),
  symptom('증상', 'symptom_entry'),
  activity('활동·재활', 'activity_entry'),
  measurement('측정', 'measurement_entry'),
  dailyLiving('생활', 'daily_living_entry'),
  incident('사건', 'incident_entry'),
  medicalContact('진료·연락', 'medical_contact_entry'),
  handoff('인계', 'handoff_entry'),
  generalNote('자유 메모', 'general_note_entry');

  const EntryKind(this.label, this.table);
  final String label;
  final String table;
  List<RecordField> get fields => recordFields[this]!;
}

class RecordField {
  const RecordField(
    this.key,
    this.label, {
    this.numeric = false,
    this.choices = const {},
    this.required = false,
  });
  final String key, label;
  final bool numeric, required;
  final Map<String, String> choices;
}

const intakeLabels = {
  'taken': '복용함',
  'missed': '복용하지 못함',
  'refused': '복용 거부',
  'unknown': '확인 못함',
};
const recordFields = <EntryKind, List<RecordField>>{
  EntryKind.meal: [
    RecordField('food', '음식'),
    RecordField(
      'amount',
      '먹은 양',
      choices: {
        'all': '전부',
        'most': '대부분',
        'half': '절반',
        'little': '조금',
        'none': '먹지 않음',
      },
    ),
    RecordField('water_ml', '수분 (mL)', numeric: true),
    RecordField('appetite', '식욕'),
    RecordField('swallowing', '씹기·삼키기'),
    RecordField('after', '식사 전후 상태'),
  ],
  EntryKind.medicationIntake: [
    RecordField('medicine', '약 이름', required: true),
    RecordField('status', '복용 상태', choices: intakeLabels, required: true),
    RecordField('reason', '누락·거부 이유'),
    RecordField('reaction', '관찰한 반응'),
    RecordField('instruction', '당시 처방 지시 원문'),
  ],
  EntryKind.symptom: [
    RecordField('symptom', '증상', required: true),
    RecordField('location', '부위'),
    RecordField('severity', '정도 (느낀 그대로)'),
    RecordField('started', '시작 시각'),
    RecordField('duration', '지속·반복'),
    RecordField('factors', '악화·완화 요인'),
    RecordField('impact', '일상생활 영향'),
    RecordField('action', '한 일·이후 변화'),
  ],
  EntryKind.activity: [
    RecordField('activity', '활동 이름', required: true),
    RecordField('minutes', '활동 시간 (분)', numeric: true),
    RecordField('assistance', '도움 정도'),
    RecordField(
      'completion',
      '수행 상태',
      choices: {'done': '완료', 'partial': '일부 수행', 'stopped': '중단'},
    ),
    RecordField('after', '활동 후 변화·중단 이유'),
  ],
  EntryKind.measurement: [
    RecordField('measurement', '측정 항목', required: true),
    RecordField('value', '측정값 (혈압은 120/80처럼 입력)', required: true),
    RecordField('unit', '단위', required: true),
    RecordField('source', '기기·측정 방법'),
  ],
  EntryKind.dailyLiving: [
    RecordField(
      'category',
      '생활 항목',
      choices: {
        'sleep': '수면',
        'urine': '소변',
        'bowel': '대변',
        'hygiene': '세면·목욕',
        'oral': '구강관리',
        'skin': '피부·상처',
        'position': '체위·이동',
        'mood': '기분·행동',
      },
      required: true,
    ),
    RecordField('details', '관찰 내용'),
    RecordField('assistance', '필요했던 도움'),
    RecordField('after', '이후 상태'),
  ],
  EntryKind.incident: [
    RecordField('event', '일어난 일', required: true),
    RecordField('action', '취한 조치'),
    RecordField('contact', '연락한 곳'),
    RecordField('after', '이후 상태'),
  ],
  EntryKind.medicalContact: [
    RecordField(
      'contact_type',
      '연락 방식',
      choices: {'visit': '진료', 'phone': '전화', 'other': '기타'},
    ),
    RecordField('institution', '의료기관'),
    RecordField('instruction', '의료진이 설명한 내용 (원문)'),
    RecordField('followup', '다음에 할 일·일정'),
  ],
  EntryKind.handoff: [
    RecordField('completed', '마친 일'),
    RecordField('pending', '남은 일'),
    RecordField('observe', '관찰할 내용'),
  ],
  EntryKind.generalNote: [],
};

class CareError implements Exception {
  const CareError(this.message);
  final String message;
  @override
  String toString() => message;
}

void validateEntry(EntryKind kind, Map<String, String> fields, String note) {
  if (note.length > 20000) {
    throw const CareError('메모는 20,000자 이내로 입력해 주세요.');
  }
  for (final field in kind.fields) {
    final value = (fields[field.key] ?? '').trim();
    if (field.required && value.isEmpty) {
      throw CareError('필수 항목을 입력해 주세요: ${field.label}');
    }
    if (value.length > 4000) {
      throw CareError('${field.label}은 4,000자 이내로 입력해 주세요.');
    }
    if (field.numeric &&
        value.isNotEmpty &&
        (double.tryParse(value) == null ||
            !double.parse(value).isFinite ||
            double.parse(value) < 0)) {
      throw CareError('${field.label}은 0 이상의 숫자로 입력해 주세요.');
    }
    if (field.choices.isNotEmpty &&
        value.isNotEmpty &&
        !field.choices.containsKey(value)) {
      throw CareError('항목을 다시 선택해 주세요: ${field.label}');
    }
  }
  if (kind == EntryKind.generalNote && note.trim().isEmpty) {
    throw const CareError('메모 내용을 입력해 주세요.');
  }
}

class Patient {
  const Patient(this.id, this.alias, this.role, this.context, this.contact);
  final String id, alias, role, context, contact;
  String get label =>
      alias.trim().isEmpty ? (role == 'self' ? '나의 수첩' : '돌봄 대상') : alias;
}

class CareEntry {
  const CareEntry({
    required this.id,
    required this.patientId,
    required this.kind,
    required this.occurredAt,
    required this.offsetMinutes,
    required this.note,
    required this.fields,
    required this.version,
  });
  final String id, patientId, note;
  final EntryKind kind;
  final DateTime occurredAt;
  final int offsetMinutes, version;
  final Map<String, String> fields;
  String get summary {
    final values = kind.fields
        .where((f) => (fields[f.key] ?? '').isNotEmpty)
        .map((f) => '${f.label}: ${f.choices[fields[f.key]] ?? fields[f.key]}');
    return [...values, if (note.isNotEmpty) note].join(' · ');
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'occurred_at': occurredAt.toUtc().millisecondsSinceEpoch,
    'offset_minutes': offsetMinutes,
    'note': note,
    'fields': fields,
    'version': version,
  };
}

class Medication {
  const Medication(
    this.id,
    this.name,
    this.instruction,
    this.times,
    this.active,
    this.planId,
    this.version,
  );
  final String id, name, instruction, planId;
  final List<String> times;
  final bool active;
  final int version;
}

class CareTask {
  const CareTask(
    this.id,
    this.title,
    this.note,
    this.dueAt,
    this.done,
    this.reminder,
  );
  final String id, title, note;
  final DateTime dueAt;
  final bool done, reminder;
}

class VisitPreparation {
  const VisitPreparation(
    this.id,
    this.title,
    this.questions,
    this.stale,
    this.createdAt,
  );
  final String id, title, questions;
  final bool stale;
  final DateTime createdAt;
}

class Attachment {
  const Attachment(this.id, this.entryId, this.wrappedKey, this.bytes);
  final String id, entryId, wrappedKey;
  final int bytes;
}
