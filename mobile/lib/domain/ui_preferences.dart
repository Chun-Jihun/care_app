import 'dart:convert';

enum UiOption {
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
}

/// Device-only presentation choices. These never change medical/safety policy,
/// source photos, record contents, retention, or the operating system's settings.
final class UiPreferences {
  const UiPreferences._(this._values);
  static const defaults = UiPreferences._({});
  final Map<UiOption, bool> _values;
  static const _defaultOn = {
    UiOption.photoPreviews,
    UiOption.recentRecords,
    UiOption.dailySummary,
    UiOption.chatShortcut,
    UiOption.inputSuggestions,
  };

  bool enabled(UiOption option) =>
      _values[option] ?? _defaultOn.contains(option);
  bool get reduceMotion =>
      enabled(UiOption.reduceMotion) || enabled(UiOption.lowGraphics);
  bool get photoPreviews =>
      enabled(UiOption.photoPreviews) && !enabled(UiOption.lowGraphics);

  UiPreferences withOption(UiOption option, bool value) =>
      UiPreferences._(Map.unmodifiable({..._values, option: value}));

  String encode() => jsonEncode({
    for (final option in UiOption.values) option.name: enabled(option),
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
      );
    } on FormatException {
      return defaults;
    }
  }
}
