import 'package:flutter/widgets.dart';

import '../domain/ui_preferences.dart';

class UiPreferencesScope extends InheritedWidget {
  const UiPreferencesScope({
    super.key,
    required this.value,
    required super.child,
  });
  final UiPreferences value;
  static UiPreferences of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiPreferencesScope>()?.value ??
      UiPreferences.defaults;
  @override
  bool updateShouldNotify(UiPreferencesScope oldWidget) =>
      value != oldWidget.value;
}

/// Adds an app-level minimum while retaining nonlinear/larger OS text scaling.
class MinimumTextScaler extends TextScaler {
  const MinimumTextScaler(this.system, this.minimum);
  final TextScaler system;
  final double minimum;
  @override
  double scale(double fontSize) {
    final original = system.scale(fontSize);
    final floor = fontSize * minimum;
    return original > floor ? original : floor;
  }

  @override
  double get textScaleFactor => scale(14) / 14;
}
