import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/chassis_furniture.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/shell/app_chassis.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

import 'layout/overflow_sweep_test.dart' show sweepSizes;

/// The window's ornament, and the two ways it can go wrong.
///
/// It can cover something — a screw on a close button is the plan's own
/// example of ornament obscuring a control, and it is what the first build of
/// this actually did. And it can appear where there is no room for it, which
/// on a 380px window means pushing the layout around under a decorative
/// pretext.
///
/// Both are properties of *placement*, not of pixels, so both are assertable
/// without looking at an image.
void main() {
  Widget host(Size size, Widget child) => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: AppLayout(
          data: AppLayoutData.fromSize(size),
          child: Scaffold(body: child),
        ),
      );

  group('the ornament appears only where there is room for it', () {
    for (final size in sweepSizes) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';
      final isRail = AppLayoutData.fromSize(size).isRail;

      testWidgets('rack — $label', (tester) async {
        final previous = NeuTheme.activeMaterial;
        NeuTheme.activeMaterial = AppMaterial.rack;
        addTearDown(() => NeuTheme.activeMaterial = previous);

        late bool shows;
        await tester.pumpWidget(host(
          size,
          Builder(builder: (context) {
            shows = AppChassis.showsFurniture(context);
            return const SizedBox.shrink();
          }),
        ));

        // The predicate is `isRail`, not the width band. `compactMax` is 700,
        // so a 900x1200 portrait window is `medium` — and cramped, which is
        // the thing `isRail` exists to say. Keying on the band would put
        // screws in the one window shape with least room for them.
        expect(shows, !isRail,
            reason: '$label: isRail=$isRail but showsFurniture=$shows');
      });
    }

    testWidgets('Soft never shows any, at any size', (tester) async {
      // Not a special case in the widget — Soft declares `Furniture.none()`
      // and `isNone` is what the predicate reads. If this ever goes green by
      // Soft growing a screw, the classic look has stopped being classic.
      final previous = NeuTheme.activeMaterial;
      NeuTheme.activeMaterial = AppMaterial.soft;
      addTearDown(() => NeuTheme.activeMaterial = previous);

      for (final size in sweepSizes) {
        late bool shows;
        await tester.pumpWidget(host(
          size,
          Builder(builder: (context) {
            shows = AppChassis.showsFurniture(context);
            return const SizedBox.shrink();
          }),
        ));
        expect(shows, isFalse,
            reason: 'Soft showed furniture at ${size.width.toInt()}px');
      }
    });
  });

  group('the ornament cannot take a click', () {
    test('hitTest is false everywhere on the box', () {
      // `Decoration.hitTest` defaults to true, and this is installed as a
      // foregroundDecoration over the entire app. Inheriting the default would
      // make every pixel of the window unclickable.
      final d = ChassisFurniture(
        furniture: MaterialSpec.of(AppMaterial.rack).furniture,
        palette: MaterialSpec.of(AppMaterial.rack).palette(true),
      );
      const size = Size(400, 300);
      for (final at in [
        Offset.zero,
        const Offset(20, 20),
        const Offset(200, 150),
        const Offset(399, 299),
      ]) {
        expect(d.hitTest(size, at), isFalse, reason: 'swallowed a click at $at');
      }
    });
  });

  group('clearance and ornament agree', () {
    test('the title bar holds back exactly what a screw needs', () {
      // The two numbers that must not drift apart. The screws sit at
      // `inset + screwDiameter / 2 + 3` from each edge, so their outer edge is
      // `inset + screwDiameter / 2 + 3 + screwDiameter / 2`, and the clearance
      // has to cover at least that. When it did not, the first build put a
      // screw on the close button.
      const screwOuterEdge = ChassisFurniture.inset +
          ChassisFurniture.screwDiameter / 2 +
          3 +
          ChassisFurniture.screwDiameter / 2;
      expect(ChassisFurniture.edgeClearance,
          greaterThanOrEqualTo(screwOuterEdge - 1),
          reason: 'the title bar does not hold back far enough for a screw at '
              'the window corner');
    });
  });

  group('it paints, and it is comparable', () {
    /// Renders the ornament over a flat ground and reports how many pixels it
    /// actually changed.
    Future<int> markedPixels(ChassisFurniture d, Size size) async {
      const ground = Color(0xFF808080);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Offset.zero & size, Paint()..color = ground);
      final painter = d.createBoxPainter();
      painter.paint(canvas, Offset.zero, ImageConfiguration(size: size));
      painter.dispose();
      final image = await recorder
          .endRecording()
          .toImage(size.width.round(), size.height.round());
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();

      var changed = 0;
      for (var i = 0; i < bytes.length; i += 4) {
        if (bytes[i] != 0x80 || bytes[i + 1] != 0x80 || bytes[i + 2] != 0x80) {
          changed++;
        }
      }
      return changed;
    }

    for (final spec in MaterialSpec.available) {
      if (spec.furniture.isNone) continue;
      for (final isDark in [false, true]) {
        test('${spec.id.key} ${isDark ? 'dark' : 'light'} draws something', () {
          // A material that declares furniture and paints nothing is the
          // silent failure this catches: every predicate above would still be
          // green, the screenshot matrix would show a plain window, and
          // nothing would say why.
          final d = ChassisFurniture(
            furniture: spec.furniture,
            palette: spec.palette(isDark),
          );
          expect(
            markedPixels(d, const Size(400, 300)),
            completion(greaterThan(200)),
            reason: '${spec.id.key} declares furniture but painted almost '
                'nothing — check that the bevel pair is not transparent',
          );
        });
      }
    }

    test('equal specs compare equal', () {
      // `RenderDecoratedBox` early-outs on `==`. Identity equality here would
      // rebuild the painter on every frame of every unrelated animation in the
      // app, since this decoration wraps the whole window.
      final a = ChassisFurniture(
        furniture: MaterialSpec.of(AppMaterial.rack).furniture,
        palette: MaterialSpec.of(AppMaterial.rack).palette(true),
      );
      final b = ChassisFurniture(
        furniture: MaterialSpec.of(AppMaterial.rack).furniture,
        palette: MaterialSpec.of(AppMaterial.rack).palette(true),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(ChassisFurniture(
          furniture: MaterialSpec.of(AppMaterial.rack).furniture,
          palette: MaterialSpec.of(AppMaterial.rack).palette(false),
        )),
      );
    });
  });
}
