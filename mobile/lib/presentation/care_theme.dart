import 'package:flutter/material.dart';

import '../domain/ui_preferences.dart';
import 'common.dart' show forest, ink;

ThemeData careTheme(
  UiPreferences preferences, {
  bool highContrast = false,
  bool reduceMotion = false,
}) {
  final contrast = highContrast || preferences.enabled(UiOption.highContrast);
  final low = preferences.enabled(UiOption.lowGraphics);
  final controls = preferences.enabled(UiOption.largeControls) ? 56.0 : 48.0;
  final scheme = ColorScheme.fromSeed(
    seedColor: forest,
    primary: forest,
    surface: contrast ? Colors.white : const Color(0xFFF7F8F3),
    onSurface: contrast ? Colors.black : ink,
    contrastLevel: contrast ? 1 : 0,
  );
  final border = contrast ? ink : const Color(0xFF718278);
  final base = ThemeData(
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 16, height: 1.5),
      bodySmall: TextStyle(fontSize: 14, height: 1.5),
      labelSmall: TextStyle(fontSize: 14),
    ),
    splashFactory: low || preferences.reduceMotion || reduceMotion
        ? NoSplash.splashFactory
        : InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      scrolledUnderElevation: low ? 0 : null,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: Size(controls, controls)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: Size(controls, controls)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: Size(controls, controls)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: Size(controls, controls)),
    ),
    checkboxTheme: const CheckboxThemeData(
      materialTapTargetSize: MaterialTapTargetSize.padded,
    ),
    chipTheme: ChipThemeData(
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: controls == 56 ? 12 : 8,
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(low ? 8 : 20),
        side: BorderSide(
          color: contrast ? ink : const Color(0xFFE6EBE4),
          width: contrast ? 1.5 : 1,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(low ? 6 : 14),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(low ? 6 : 14),
        borderSide: BorderSide(color: border, width: contrast ? 2 : 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(low ? 6 : 14),
        borderSide: const BorderSide(color: forest, width: 3),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: contrast
          ? const Color(0xFFBBD7BC)
          : const Color(0xFFDDEADB),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: forest,
      foregroundColor: Colors.white,
      elevation: low ? 0 : 2,
    ),
    pageTransitionsTheme: preferences.reduceMotion || reduceMotion
        ? PageTransitionsTheme(
            builders: {
              for (final platform in TargetPlatform.values)
                platform: const _StillPageTransition(),
            },
          )
        : const PageTransitionsTheme(),
  );
  // Text applies MediaQuery.boldText, including the OS preference, globally.
  return base;
}

class _StillPageTransition extends PageTransitionsBuilder {
  const _StillPageTransition();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
