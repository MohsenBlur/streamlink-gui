import 'package:flutter/material.dart';

import '../widgets/settings_dialog.dart' show ThemeUpdateListener;
import 'neu_theme.dart';

/// App-wide theme state.
///
/// Lives here rather than in main.dart: nine widgets - including every file in
/// widgets/neumorphic/ - used to import the application entrypoint purely to
/// reach the [themeNotifier] global, which made the whole widget layer depend
/// on the app shell.
class AppThemeNotifier extends ChangeNotifier implements ThemeUpdateListener {
  @override
  bool isDarkTheme = true;

  @override
  Color lightAccentColor = NeuTheme.defaultLightAccent;

  @override
  Color darkAccentColor = NeuTheme.defaultDarkAccent;

  @override
  Color get primaryColor => isDarkTheme ? darkAccentColor : lightAccentColor;

  /// Readable foreground for content rendered on [primaryColor]. Computed,
  /// never a constant: the accent is user-selectable and bright accents need
  /// dark ink where dark accents need white.
  Color get onPrimaryColor => NeuTheme.onAccent(primaryColor);

  @override
  Color get backgroundColor => NeuTheme.background(isDarkTheme);

  @override
  Color get surfaceColor => NeuTheme.surface(isDarkTheme);

  @override
  Color get lightShadowColor => NeuTheme.highlight(isDarkTheme);

  @override
  Color get darkShadowColor => NeuTheme.shadow(isDarkTheme);

  @override
  Color get textColor => NeuTheme.text(isDarkTheme);

  @override
  Color get subtextColor => NeuTheme.subtext(isDarkTheme);

  @override
  Color activeProgressColor = const Color(0xFF9146FF);

  @override
  Color watchedProgressColor = const Color(0x804CAF50);

  @override
  void setDarkTheme(bool isDark) {
    if (isDarkTheme == isDark) return;
    isDarkTheme = isDark;
    notifyListeners();
  }

  @override
  void setLightAccent(Color color) {
    if (lightAccentColor == color) return;
    lightAccentColor = color;
    notifyListeners();
  }

  @override
  void setDarkAccent(Color color) {
    if (darkAccentColor == color) return;
    darkAccentColor = color;
    notifyListeners();
  }

  @override
  void updateTheme({
    Color? activeProgress,
    Color? watchedProgress,
  }) {
    if (activeProgress != null) activeProgressColor = activeProgress;
    if (watchedProgress != null) watchedProgressColor = watchedProgress;
    notifyListeners();
  }
}

final AppThemeNotifier themeNotifier = AppThemeNotifier();
