import 'package:flutter_test/flutter_test.dart';
import 'package:care_notebook/infrastructure/ai/ocr_engine.dart';

void main() {
  test('word boxes merge within a line without joining adjacent rows or distant columns', () {
    final rows = mergeHorizontalBoxes(
      [
        [.1, .1, .3, .2],
        [.32, .11, .45, .2],
        [.8, .1, .9, .2],
        [.1, .3, .3, .4],
        [.32, .31, .45, .4],
      ],
      1000,
      500,
    );
    expect(rows, [
      [.1, .1, .45, .2],
      [.8, .1, .9, .2],
      [.1, .3, .45, .4],
    ]);
  });
  test('CTC preserves repeated characters separated by blank', () {
    final result = decodeCtc(
      [0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
      [1, 5, 3],
      ['', '1', '0'],
    );
    expect(result.$1, '110');
  });
}
