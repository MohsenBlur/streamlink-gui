import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/app_startup.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';

/// The first load re-applies the stored look from MainScreen's initState -
/// inside the build - so every setter it calls has to be silent when nothing
/// changes. `updateTheme` was not: it notified on every launch, which marked
/// the app's own ListenableBuilder dirty mid-build.
void main() {
  test('updateTheme notifies only when a colour changes', () {
    final notifier = AppThemeNotifier();
    var notified = 0;
    notifier.addListener(() => notified++);

    notifier.updateTheme(
      activeProgress: notifier.activeProgressColor,
      watchedProgress: notifier.watchedProgressColor,
    );
    notifier.updateTheme();
    expect(notified, 0);

    notifier.updateTheme(activeProgress: const Color(0xFF00FF00));
    expect(notified, 1);
    expect(notifier.activeProgressColor, const Color(0xFF00FF00));

    notifier.updateTheme(watchedProgress: const Color(0xFF0000FF));
    expect(notified, 2);
    expect(notifier.activeProgressColor, const Color(0xFF00FF00),
        reason: 'a colour left out is kept');
  });

  test('main() seeds the progress colours with the rest of the look', () {
    final active = themeNotifier.activeProgressColor;
    final watched = themeNotifier.watchedProgressColor;
    addTearDown(() {
      themeNotifier
        ..activeProgressColor = active
        ..watchedProgressColor = watched;
    });

    seedStoredLook(AppSettings()
      ..activeProgressColorHex = '#FF112233'
      ..watchedProgressColorHex = '#80445566');

    // So the first load's own updateTheme, from inside the build, has
    // nothing left to change.
    expect(themeNotifier.activeProgressColor, const Color(0xFF112233));
    expect(themeNotifier.watchedProgressColor, const Color(0x80445566));
  });
}
