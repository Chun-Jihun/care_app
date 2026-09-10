import 'error_messages.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../domain/records.dart';
import '../domain/drafts.dart';
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
  String draftStatus(DraftStatus status) => text(switch (status) {
    DraftStatus.waiting => '입력하면 기기에 암호화 초안으로 보관해요.',
    DraftStatus.restored => '암호화 초안을 불러왔어요. 확인 후 저장해 주세요.',
    DraftStatus.saving => '초안을 저장하고 있어요…',
    DraftStatus.saved => '기기에 암호화 초안으로 보관했어요. 기록 확정은 저장을 눌러 주세요.',
    DraftStatus.failed =>
      '초안 저장에 실패했어요. 저장 공간을 확인해 주세요. 이전 자동 저장 이후 입력은 복구되지 않을 수 있어요.',
  });
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
    if (error is! CareError) return text(fallback);
    return text(
      errorMessages[error.code] ?? fallback,
      error.labels.map(text).toList(),
    );
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
