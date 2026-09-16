import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/application/input_field_suggestions.dart';
import 'package:care_notebook/domain/records.dart';
import 'package:care_notebook/l10n/app_strings.dart';

void main() {
  final strings = AppStrings(AppLanguage.korean);
  test('only explicitly labeled fields become candidates; no prescription implies intake', () {
    expect(
      InputFieldSuggestions.parse(
        '약 이름: 약 A 5 mg\n복용 상태: 복용하지 못함',
        EntryKind.medicationIntake,
        strings,
      ),
      {'medicine': '약 A 5 mg', 'status': 'missed'},
    );
    expect(
      InputFieldSuggestions.parse(
        '약 A 5 mg 아침 식후\n1일 3회',
        EntryKind.medicationIntake,
        strings,
      ),
      isEmpty,
    );
    expect(
      InputFieldSuggestions.parse(
        '약 이름: 약 A 5 mg',
        EntryKind.medicationIntake,
        strings,
      ),
      {'medicine': '약 A 5 mg'},
    );
  });
  test(
    'conflicting repeated labels and invalid choices are never selected',
    () {
      expect(
        InputFieldSuggestions.parse(
          '약 이름: 약 A 5 mg\n약 이름: 약 A 15 mg\n복용 상태: 아마 복용함',
          EntryKind.medicationIntake,
          strings,
        ),
        isEmpty,
      );
      expect(
        InputFieldSuggestions.parse(
          '수분 (mL): 1O0\n먹은 양: 전부',
          EntryKind.meal,
          strings,
        ),
        {'amount': 'all'},
      );
      expect(
        InputFieldSuggestions.parse('수분 (mL): -100', EntryKind.meal, strings),
        isEmpty,
      );
      expect(
        InputFieldSuggestions.parse(
          '수분 (mL): 100\n수분 (mL): 불확실',
          EntryKind.meal,
          strings,
        ),
        isEmpty,
      );
    },
  );
  test('numeric text is not repaired or converted; ordinary notes stay out of fields', () {
    expect(
      InputFieldSuggestions.parse(
        '수분 (mL): 0\n음식: 죽\n추측: 충분함',
        EntryKind.meal,
        strings,
      ),
      {'water_ml': '0', 'food': '죽'},
    );
    expect(
      InputFieldSuggestions.parse('수분 (mL): 100mL', EntryKind.meal, strings),
      isEmpty,
    );
    expect(
      InputFieldSuggestions.parse(
        '약 이름: 약 A\n복용 상태: 복용 거부\n누락·거부 이유: 삼키기 어려움',
        EntryKind.medicationIntake,
        strings,
      )['status'],
      'refused',
    );
  });
}
