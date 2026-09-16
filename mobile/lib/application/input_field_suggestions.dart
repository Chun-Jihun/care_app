import '../domain/records.dart';
import '../l10n/app_strings.dart';

/// Extracts only literal "field label: value" lines. There is no inference,
/// fuzzy drug matching, unit conversion, or default medication intake status.
final class InputFieldSuggestions {
  static Map<String, String> parse(
    String text,
    EntryKind kind,
    AppStrings strings,
  ) {
    if (text.length > 20000) return const {};
    final labels = <String, RecordField>{
      for (final field in kind.fields) ...{
        field.label: field,
        strings.text(field.label): field,
      },
    };
    final observed = <String, Set<String>>{};
    for (final line in text.split('\n')) {
      final match = RegExp(r'^\s*([^:：]{1,80})[:：]\s*(.*?)\s*$')
          .firstMatch(line);
      if (match == null) continue;
      final field = labels[match[1]!.trim()];
      if (field == null) continue;
      observed.putIfAbsent(field.key, () => {}).add(match[2]!);
    }
    final result = <String, String>{};
    for (final field in kind.fields) {
      final values = observed[field.key];
      if (values == null || values.length != 1) continue;
      final value = values.single;
      if (value.isEmpty || value.length > 4000) continue;
      if (field.numeric &&
          (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value) ||
              !(double.tryParse(value)?.isFinite ?? false))) {
        continue;
      }
      if (field.choices.isNotEmpty) {
        final choices = field.choices.entries
            .where((e) => e.value == value || strings.text(e.value) == value)
            .toList();
        if (choices.length == 1) result[field.key] = choices.single.key;
      } else {
        result[field.key] = value;
      }
    }
    return Map.unmodifiable(result);
  }
}
