import 'package:flutter/material.dart';

import 'neu_theme.dart';
import 'theme_notifier.dart';

/// The app's Material theme for one brightness.
///
/// One function rather than two inline copies in the app widget, so the
/// layout sweeps can pump a dialog under the theme that actually ships:
/// filled outline fields add a suffix margin to every dropdown, and a sweep
/// under the stock theme measures narrower controls than users get.
///
/// Reads the live [themeNotifier] (accent, surfaces) and the active material
/// through [NeuTheme], so it must be rebuilt whenever either changes - the
/// app widget does, per notification.
ThemeData buildAppTheme({required bool isDark}) {
  return ThemeData(
    brightness: isDark ? Brightness.dark : Brightness.light,
    fontFamily: 'Segoe UI',
    scaffoldBackgroundColor: themeNotifier.backgroundColor,
    primaryColor: themeNotifier.primaryColor,
    cardColor: themeNotifier.surfaceColor,
    colorScheme: isDark
        ? ColorScheme.dark(
            primary: themeNotifier.primaryColor,
            secondary: NeuTheme.live,
            surface: themeNotifier.surfaceColor,
            error: NeuTheme.danger,
          )
        : ColorScheme.light(
            primary: themeNotifier.primaryColor,
            secondary: NeuTheme.live,
            surface: themeNotifier.surfaceColor,
            error: NeuTheme.danger,
          ),
    // Not const: a const expression cannot invoke a function, and these must
    // resolve through the active material rather than pinning Soft's ink
    // into every Material widget in the app.
    textTheme: TextTheme(
      titleLarge:
          TextStyle(fontWeight: FontWeight.bold, color: NeuTheme.text(isDark)),
      bodyLarge: TextStyle(color: NeuTheme.text(isDark)),
      bodyMedium: TextStyle(color: NeuTheme.subtext(isDark)),
    ),
    // Raw Material TextFields (Settings, the wizard) inherited the stock M3
    // look - web-default input fields floating in a machined chassis, inches
    // from sunken NeuTextFields. This theme gives every un-migrated field the
    // system's recessed-well read.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: NeuTheme.wellSurface(isDark),
      hintStyle: TextStyle(color: NeuTheme.disabledText(isDark)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.r8),
        borderSide: BorderSide(color: NeuTheme.border(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.r8),
        borderSide: BorderSide(color: themeNotifier.accentInk, width: 1.5),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NeuRadius.r8),
        borderSide: BorderSide(color: NeuTheme.border(isDark)),
      ),
    ),
  );
}
