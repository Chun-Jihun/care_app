import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/domain/reviewed_input.dart';
import 'package:care_notebook/domain/errors.dart';

void main() {
  test(
    'reviewed input appends without replacing existing text or negations',
    () {
      expect(
        appendReviewedInput('복용하지 않음', '5 mg 원문 확인'),
        '복용하지 않음\n5 mg 원문 확인',
      );
      expect(appendReviewedInput('', '  원문 그대로  '), '  원문 그대로  ');
      expect(appendReviewedInput('existing', '   '), 'existing');
    },
  );
  test('combined length is checked before changing the original input', () {
    final previous = 'a' * 19999;
    expect(() => appendReviewedInput(previous, 'b'), throwsA(isA<CareError>()));
    expect(appendReviewedInput('a' * 19998, 'b'), hasLength(20000));
    expect(previous, hasLength(19999));
  });
}
