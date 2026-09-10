import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../domain/records.dart';
import 'catalogs.g.dart';

enum AppLanguage {
  korean('ko', '한국어', Locale('ko')),
  english('en', 'English', Locale('en')),
  japanese('ja', '日本語', Locale('ja')),
  simplifiedChinese(
    'zh_Hans',
    '简体中文',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  ),
  traditionalChinese(
    'zh_Hant',
    '繁體中文',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  );

  const AppLanguage(this.code, this.nativeName, this.locale);
  final String code, nativeName;
  final Locale locale;

  static AppLanguage fromCode(String? code) =>
      values.firstWhere((value) => value.code == code, orElse: () => korean);
  static AppLanguage fromLocale(Locale locale) {
    if (locale.languageCode == 'zh') {
      return locale.scriptCode == 'Hant' ||
              (locale.scriptCode != 'Hans' &&
                  ['TW', 'HK', 'MO'].contains(locale.countryCode))
          ? traditionalChinese
          : simplifiedChinese;
    }
    return fromCode(locale.languageCode);
  }
}

/// Only developer-authored copy and known metadata are translated.
/// User content must be supplied as arguments, never as a catalog key.
class AppStrings {
  const AppStrings(this.language);
  final AppLanguage language;
  static final _placeholder = RegExp(r'\{(\d+)\}');
  String get intlLocale => switch (language) {
    AppLanguage.simplifiedChinese => 'zh_CN',
    AppLanguage.traditionalChinese => 'zh_TW',
    _ => language.code,
  };
  String text(String source, [List<Object?> args = const []]) {
    assert(
      translationCatalogs['ko']!.containsKey(source),
      'Missing translation key: $source',
    );
    final template = translationCatalogs[language.code]?[source] ?? source;
    // One pass: braces in patient content are never interpreted as placeholders.
    return template.replaceAllMapped(_placeholder, (match) {
      final index = int.parse(match[1]!);
      return index < args.length ? '${args[index]}' : match[0]!;
    });
  }

  String error(Object error) {
    const fallback = '작업을 완료하지 못했습니다. 입력 내용과 기기 저장 공간을 확인하고 다시 시도해 주세요.';
    if (error is! CareError ||
        !translationCatalogs['ko']!.containsKey(error.message)) {
      return text(fallback);
    }
    return text(error.message, error.labels.map(text).toList());
  }

  String patient(Patient patient) => patient.alias.trim().isNotEmpty
      ? patient.alias
      : text(patient.role == 'self' ? '나의 수첩' : '돌봄 대상');
  String summary(CareEntry entry) => [
    ...entry.kind.fields
        .where((field) => (entry.fields[field.key] ?? '').isNotEmpty)
        .map((field) {
          final value = entry.fields[field.key]!;
          final choice = field.choices[value];
          return '${text(field.label)}: ${choice == null ? value : text(choice)}';
        }),
    if (entry.note.isNotEmpty) entry.note,
  ].join(' · ');
  String fieldValue(RecordField field, String value) =>
      field.choices.containsKey(value) ? text(field.choices[value]!) : value;
  String date(DateTime value) => DateFormat.yMd(intlLocale).format(value);
  String time(DateTime value) => DateFormat.Hm(intlLocale).format(value);
  String day(DateTime value) => DateFormat.MMMEd(intlLocale).format(value);

  static const delegate = _StringsDelegate();
  static AppStrings of(BuildContext context) =>
      Localizations.of<AppStrings>(context, AppStrings) ??
      const AppStrings(AppLanguage.korean);
}

class _StringsDelegate extends LocalizationsDelegate<AppStrings> {
  const _StringsDelegate();
  @override
  bool isSupported(Locale locale) =>
      ['ko', 'en', 'ja', 'zh'].contains(locale.languageCode);
  @override
  Future<AppStrings> load(Locale locale) =>
      SynchronousFuture(AppStrings(AppLanguage.fromLocale(locale)));
  @override
  bool shouldReload(_StringsDelegate old) => false;
}

extension CareLocalization on BuildContext {
  AppStrings get strings => AppStrings.of(this);
  String tr(String source, [List<Object?> args = const []]) =>
      strings.text(source, args);
}
