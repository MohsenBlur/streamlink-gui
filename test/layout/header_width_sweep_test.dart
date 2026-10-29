import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/widgets/dashboard_header.dart';
import 'package:streamlink_gui/widgets/shell/app_chassis.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

import 'overflow_sweep_test.dart' show channel;

/// The compact channel header at every window width where it changes form.
///
/// It picks its tightened row below a width measured at 100% text, and the
/// sweeps only visit a handful of sizes: 380 (tight) and 700 (roomy) passed
/// while the single 440 point it used was wrong for an offline channel, whose
/// OFFLINE pill then overran the name's room in every window from 498 to 614
/// wide - and from 608 to 660 at 125% text. This walks the band in between,
/// on every material and in every state of the launch button.
void main() {
  for (final scale in const [1.0, 1.25]) {
    for (final spec in MaterialSpec.available) {
      for (final (state, live, playing) in const [
        ('offline', false, false),
        ('live', true, false),
        ('open', true, true),
      ]) {
        testWidgets(
            'the ${(scale * 100).round()}% header holds from 380 to 760 wide '
            '- ${spec.id.key} $state', (tester) async {
          final pulse = AnimationController(
              vsync: const TestVSync(), duration: const Duration(seconds: 2));
          addTearDown(pulse.dispose);
          final previousMaterial = NeuTheme.activeMaterial;
          NeuTheme.activeMaterial = spec.id;
          addTearDown(() => NeuTheme.activeMaterial = previousMaterial);
          themeNotifier.isDarkTheme = true;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          addTearDown(tester.view.reset);

          final overflowing = <int>[];
          for (var width = 380; width <= 760; width += 3) {
            // Portrait, so the header is the compact one at every width.
            final size = Size(width.toDouble(), 1400);
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1.0;
            var overflowed = false;
            final previous = FlutterError.onError;
            FlutterError.onError = (details) {
              if (details.exception.toString().contains('overflowed')) {
                overflowed = true;
              } else {
                previous?.call(details);
              }
            };
            try {
              await tester.pumpWidget(MaterialApp(
                theme: ThemeData(
                  brightness: Brightness.dark,
                  primaryColor: NeuTheme.defaultDarkAccent,
                ),
                home: AppLayout(
                  data: AppLayoutData.fromSize(size),
                  child: Scaffold(
                    body: AppChassis(
                      child: Padding(
                        // The channel page's padding in a rail layout.
                        padding: const EdgeInsets.all(NeuSpace.s16),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: DashboardHeader(
                            // A fresh header per width, as a resize would
                            // lay out: no state carried from the last one.
                            key: ValueKey(width),
                            channel: channel(isLive: live),
                            pulseController: pulse,
                            onPlay: () {},
                            onRefresh: () {},
                            openExternalLink: (_) {},
                            isPlaying: playing,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ));
              await tester.pump(const Duration(milliseconds: 50));
            } finally {
              FlutterError.onError = previous;
            }
            if (overflowed) overflowing.add(width);
          }

          expect(overflowing, isEmpty,
              reason: 'windows this wide overflowed the header');
        });
      }
    }
  }
}
