import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/theme/app_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/widgets/settings_dialog.dart';

import 'overflow_sweep_test.dart' show sweepSizes;

/// The settings dialog, swept tab by tab.
///
/// `real_surface_sweep_test` pumps `NeuDialog` with a stand-in body, which is
/// the shell and not the settings. The settings were described as "not
/// practical to pump" and checked by source scan alone - and the first run of
/// this sweep found fourteen rows overflowing at the 380x500 minimum window,
/// across three of the five tabs. Each one put a label beside a control in a
/// Row with nothing flexible in it, so the control was laid out past the
/// dialog's edge: clipped in release, unreachable either way.
///
/// The test font is wider than Segoe UI, so this is stricter than the
/// shipping font at the same size. That is the useful direction: a row that
/// survives it also survives Windows' larger text sizes.
void main() {
  /// The dark theme the app ships, not a copy of it: the input decoration
  /// is the part that matters, since filled outline fields add a suffix
  /// margin to every dropdown, and a sweep under the stock theme (or a copy
  /// that drifted) would measure narrower controls than users get.
  ThemeData appTheme() => buildAppTheme(isDark: true);

  /// Hostile settings: every optional row that can appear, appears.
  ///
  /// The custom player is selected so its path field and found/missing line
  /// are built. The path is long but LOCAL: the dialog stats it on open, and
  /// a UNC host that does not exist would stall the test on an SMB timeout.
  AppSettings hostileSettings() => AppSettings()
    ..playerType = 'custom'
    ..customPlayerPath = r'C:\a\very\deep\folder\that\does\not\exist'
        r'\players\mpv-x86_64-v3-20260801\mpv.exe'
    ..twitchOauthToken = 'oauth:abcdefghijklmnopqrstuvwxyz0123'
    ..twitchWebOauthToken = 'abcdefghijklmnopqrstuvwxyz0123';

  const tabs = ['Playback', 'Downloads', 'Appearance', 'Twitch', 'System'];

  /// Opens the real dialog at [size], visits every tab, and returns each
  /// overflow with the dialog source line that raised it.
  Future<List<String>> sweepTabs(WidgetTester tester, Size size) async {
    final overflows = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exception.toString();
      if (text.contains('overflowed')) {
        final where = RegExp(r'settings_dialog\.dart:(\d+)')
            .firstMatch(details.toString());
        overflows.add('${text.split('\n').first} '
            '(settings_dialog.dart:${where?.group(1) ?? '?'})');
      } else {
        previous?.call(details);
      }
    };

    final previousDark = themeNotifier.isDarkTheme;
    themeNotifier.isDarkTheme = true;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => themeNotifier.isDarkTheme = previousDark);

    try {
      await tester.pumpWidget(MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => SettingsDialog.show(
                context,
                settings: hostileSettings(),
                themeNotifier: themeNotifier,
                authenticatedUserLogin: null,
                onRevalidateHelix: () async {},
                onConnectAccount: () {},
                onSave: (_) {},
                openExternalLink: (_) {},
                onClearWatchHistory: () {},
                onOpenLogs: () {},
              ),
              child: const Text('open settings'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      for (final tab in tabs) {
        // The tab strip scrolls at narrow widths, and a tap on a label
        // outside it lands on nothing - silently, as a warning, leaving the
        // sweep re-measuring the first tab five times.
        await tester.ensureVisible(find.text(tab));
        await tester.pump();
        await tester.tap(find.text(tab));
        // The TabBarView slide, then a settled frame. Only the visible page
        // is built, so each tab has to be shown to be measured at all.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(DefaultTabController.of(tester.element(find.text(tab))).index,
            tabs.indexOf(tab),
            reason: 'the sweep did not reach the $tab tab');
      }
    } finally {
      FlutterError.onError = previous;
    }
    return overflows;
  }

  group('every settings tab fits every window size', () {
    for (final size in sweepSizes) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      testWidgets(label, (tester) async {
        final overflows = await sweepTabs(tester, size);
        expect(overflows, isEmpty, reason: '$label:\n${overflows.join('\n')}');
      });
    }
  });
}
