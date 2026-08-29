import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/lit_surface.dart';
import 'package:streamlink_gui/theme/material/texture_cache.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_badge.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_led_indicator.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_progress.dart';
import 'package:streamlink_gui/widgets/shell/engraved_rule.dart';

/// Renders composite scenes of REAL widgets to `shots/composite/*.png`.
///
/// The app holds a single-instance mutex, so while the user's installed copy
/// is running the dev build cannot launch at all - and screenshots taken
/// then silently show the WRONG binary. This harness is the loop that works
/// regardless: it mounts real widget subtrees over the real material engine
/// (shader included - `FragmentProgram.fromAsset` works under flutter test)
/// and writes what actually painted.
///
///   flutter test test/tools/render_composite_preview.dart
void main() {
  setUpAll(() async {
    await LitSurfaceProgram.load();
    // Prime every hairline tile, or the preview paints the one layer this
    // harness exists to judge as MISSING - the calibration eye would be
    // tuning the shader grain while believing it was seeing the brush.
    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final t = spec.palette(isDark).texture;
        if (t == null) continue;
        for (final role in SurfaceRole.values) {
          final amp = t.amplitudeFor(role);
          final scale = RoleModifier.of(role).textureScale;
          if (amp <= 0 || scale <= 0) continue;
          await TextureCache.prime(TileKey(
            kind: t.kind,
            width: t.tileDevicePx.width.round(),
            height: t.tileDevicePx.height.round(),
            amplitude: (amp * scale).round(),
            seed: t.seed,
          ));
        }
      }
    }
  });

  Future<void> snap(WidgetTester tester, Widget scene, Size size, String name,
      {bool dark = true}) async {
    themeNotifier.isDarkTheme = dark;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: NeuTheme.canvas(dark),
          child: scene,
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final img = await boundary.toImage();
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      File('shots/composite/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  Widget card(bool dark, {double w = 240, double h = 135, String? label}) =>
      Container(
        width: w,
        height: h,
        margin: const EdgeInsets.only(right: NeuSpace.s12),
        decoration: NeuTheme.raisedDecoration(dark, radius: NeuRadius.r12),
        padding: const EdgeInsets.all(NeuSpace.s12),
        alignment: Alignment.bottomLeft,
        child: Text(label ?? 'Card', style: NeuType.body(dark)),
      );

  testWidgets('the strip: shadows must survive the viewport', (tester) async {
    for (final dark in [true, false]) {
      final mode = dark ? 'dark' : 'light';
      await snap(
        tester,
        Center(
          child: SizedBox(
            width: 700,
            height: 155,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < 4; i++)
                    card(dark, label: 'VOD ${i + 1}'),
                ],
              ),
            ),
          ),
        ),
        const Size(760, 240),
        'strip_$mode',
        dark: dark,
      );
    }
  });

  testWidgets('instruments: meters, lamps, grooves, glass', (tester) async {
    for (final dark in [true, false]) {
      final mode = dark ? 'dark' : 'light';
      await snap(
        tester,
        Center(
          child: Container(
            width: 560,
            decoration: NeuTheme.panel(dark),
            padding: const EdgeInsets.all(NeuSpace.s24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const NeuLedIndicator(size: 8, isPulsing: false),
                  const SizedBox(width: NeuSpace.s8),
                  Text('SESSION', style: NeuType.plate(dark)),
                  const Spacer(),
                  const NeuLedIndicator(
                      size: 8,
                      isPulsing: false,
                      activeColor: NeuTheme.danger),
                  const SizedBox(width: NeuSpace.s8),
                  Text('FAULT', style: NeuType.plate(dark)),
                ]),
                const SizedBox(height: NeuSpace.s12),
                EngravedRule(),
                const SizedBox(height: NeuSpace.s16),
                const NeuProgressBar(
                    value: 0.62, size: NeuProgressSize.lg),
                const SizedBox(height: NeuSpace.s12),
                const NeuProgressBar(
                    value: 0.31, size: NeuProgressSize.md),
                const SizedBox(height: NeuSpace.s12),
                const NeuProgressBar(
                    value: 0.85, size: NeuProgressSize.sm),
                const SizedBox(height: NeuSpace.s16),
                EngravedRule(),
                const SizedBox(height: NeuSpace.s16),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: NeuSpace.s8, vertical: NeuSpace.s4),
                  decoration: NeuTheme.screen(dark,
                      radius: NeuRadius.r8, depth: NeuElevation.d1),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('2 DOWNLOADS - 64%',
                            style: NeuType.plate(dark,
                                color: NeuTheme.screenText(dark))),
                        const SizedBox(height: NeuSpace.s4),
                        const NeuProgressBar(
                            value: 0.64,
                            size: NeuProgressSize.xs,
                            width: 120),
                      ]),
                ),
              ],
            ),
          ),
        ),
        const Size(640, 420),
        'instruments_$mode',
        dark: dark,
      );
    }
  });

  testWidgets('a molecule board: buttons, badges, wells on a panel',
      (tester) async {
    for (final dark in [true, false]) {
      final mode = dark ? 'dark' : 'light';
      await snap(
        tester,
        Center(
          child: Container(
            width: 560,
            decoration: NeuTheme.panel(dark),
            padding: const EdgeInsets.all(NeuSpace.s24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: NeuSpace.s16, vertical: NeuSpace.s8),
                    decoration:
                        NeuTheme.raisedDecoration(dark, radius: NeuRadius.r8),
                    child: Text('Refresh', style: NeuType.body(dark)),
                  ),
                  const SizedBox(width: NeuSpace.s16),
                  const StatusBadge(label: 'LIVE', tone: BadgeTone.live),
                  const SizedBox(width: NeuSpace.s12),
                  const StatusBadge(label: 'QUEUED', tone: BadgeTone.neutral),
                  const SizedBox(width: NeuSpace.s12),
                  const StatusBadge(label: 'FAILED', tone: BadgeTone.danger),
                ]),
                const SizedBox(height: NeuSpace.s16),
                Container(
                  height: 40,
                  decoration:
                      NeuTheme.sunkenDecoration(dark, radius: NeuRadius.r8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                  alignment: Alignment.centerLeft,
                  child: Text('Search or add username…',
                      style: NeuType.body(dark,
                          color: NeuTheme.subtext(dark))),
                ),
                const SizedBox(height: NeuSpace.s16),
                Container(
                  height: 72,
                  decoration: NeuTheme.screen(dark, radius: NeuRadius.r8),
                  padding: const EdgeInsets.all(NeuSpace.s12),
                  alignment: Alignment.topLeft,
                  child: Text('[12:02:11] streamlink: opening stream…',
                      style: NeuType.mono(dark,
                          color: NeuTheme.screenText(dark))),
                ),
              ],
            ),
          ),
        ),
        const Size(640, 400),
        'molecules_$mode',
        dark: dark,
      );
    }
  });
}
