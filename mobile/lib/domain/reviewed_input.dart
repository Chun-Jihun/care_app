import 'errors.dart';

final class ReviewedInput {
  ReviewedInput(this.text, {Map<String, String> fields = const {}})
    : fields = Map.unmodifiable(fields);
  final String text;
  final Map<String, String> fields;
}

/// Compose before assigning to any editor so failures preserve the old input.
String appendReviewedInput(String current, String reviewed) {
  if (reviewed.trim().isEmpty) return current;
  final result = current.isEmpty ? reviewed : '$current\n$reviewed';
  if (result.length > 20000) throw CareError(CareErrorCode.noteTooLong);
  return result;
}
