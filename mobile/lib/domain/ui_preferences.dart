import 'dart:convert';

import 'records.dart';

enum UiOption {
  animations,
  largeText,
  boldText,
  highContrast,
  largeControls,
  reduceMotion,
  lowGraphics,
  photoPreviews,
  recentRecords,
  dailySummary,
  caregiverShortcut,
  chatShortcut,
  inputSuggestions,
  quickRecords,
  taskOverview,
  medicationOverview,
  photoShortcut,
  contactShortcut,
  dailyWidget,
  widgetDetails,
}

enum HomeSection {
  quickRecords(UiOption.quickRecords),
  tasks(UiOption.taskOverview),
  medications(UiOption.medicationOverview),
  photo(UiOption.photoShortcut),
  caregiver(UiOption.caregiverShortcut),
  chat(UiOption.chatShortcut),
  contacts(UiOption.contactShortcut),
  recent(UiOption.recentRecords),
  totals(UiOption.dailySummary);

  const HomeSection(this.option);
  final UiOption option;
}

/// Device-local display choices and explicit home-widget projection opt-ins.
/// These never change medical/safety policy, source photos, record contents,
/// retention, or the operating system's settings.
final class UiPreferences {
  const UiPreferences._(
    this._values, [
    this._order = const [],
    this.quickKinds = defaultQuickKinds,
  ]);
  static const defaults = UiPreferences._({});
  final Map<UiOption, bool> _values;
  final List<HomeSection> _order;
  final Set<EntryKind> quickKinds;
  static const defaultQuickKinds = {
    EntryKind.meal,
    EntryKind.medicationIntake,
    EntryKind.symptom,
    EntryKind.activity,
  };
  List<HomeSection> get homeOrder => List.unmodifiable([
    ..._order,
    ...HomeSection.values.where((s) => !_order.contains(s)),
  ]);
  static const _defaultOn = {
    UiOption.animations,
    UiOption.photoPreviews,
    UiOption.recentRecords,
    UiOption.dailySummary,
    UiOption.chatShortcut,
    UiOption.inputSuggestions,
    UiOption.quickRecords,
    UiOption.taskOverview,
    UiOption.medicationOverview,
    UiOption.photoShortcut,
    UiOption.contactShortcut,
  };

  bool enabled(UiOption option) =>
      _values[option] ?? _defaultOn.contains(option);
  bool get reduceMotion =>
      !enabled(UiOption.animations) ||
      enabled(UiOption.reduceMotion) ||
      enabled(UiOption.lowGraphics);
  bool get photoPreviews =>
      enabled(UiOption.photoPreviews) && !enabled(UiOption.lowGraphics);

  UiPreferences withOption(UiOption option, bool value) => UiPreferences._(
    Map.unmodifiable({..._values, option: value}),
    _order,
    quickKinds,
  );

  UiPreferences resetDisplay() => defaults
      .withOption(UiOption.dailyWidget, enabled(UiOption.dailyWidget))
      .withOption(UiOption.widgetDetails, enabled(UiOption.widgetDetails));

  UiPreferences moveHomeSection(HomeSection section, int delta) {
    final order = [...homeOrder];
    final before = order.indexOf(section);
    final after = (before + delta).clamp(0, order.length - 1);
    order.removeAt(before);
    order.insert(after, section);
    return UiPreferences._(_values, List.unmodifiable(order), quickKinds);
  }

  UiPreferences withQuickKind(EntryKind kind, bool show) => UiPreferences._(
    _values,
    _order,
    Set.unmodifiable({...quickKinds.where((k) => k != kind), if (show) kind}),
  );

  String encode() => jsonEncode({
    for (final option in UiOption.values) option.name: enabled(option),
    'homeOrder': homeOrder.map((s) => s.name).toList(),
    'quickKinds': quickKinds.map((k) => k.name).toList(),
  });

  static UiPreferences decode(String? encoded) {
    if (encoded == null) return defaults;
    try {
      final data = jsonDecode(encoded);
      if (data is! Map) return defaults;
      return UiPreferences._(
        Map.unmodifiable({
          for (final option in UiOption.values)
            if (data[option.name] is bool) option: data[option.name] as bool,
        }),
        data['homeOrder'] is List
            ? List.unmodifiable(
                (data['homeOrder'] as List)
                    .map(
                      (value) => HomeSection.values
                          .where((s) => s.name == value)
                          .firstOrNull,
                    )
                    .whereType<HomeSection>()
                    .toSet(),
              )
            : const [],
        data['quickKinds'] is List
            ? Set.unmodifiable(
                (data['quickKinds'] as List)
                    .map(
                      (value) => EntryKind.values
                          .where((k) => k.name == value)
                          .firstOrNull,
                    )
                    .whereType<EntryKind>(),
              )
            : defaultQuickKinds,
      );
    } on FormatException {
      return defaults;
    }
  }
}
