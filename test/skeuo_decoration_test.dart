import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// The geometry contract of the painter.
///
/// Widening `raised()`/`sunken()` from `BoxDecoration` to `Decoration` silently
/// drops five members the framework was supplying. None of them produces a
/// compiler error, one is a paint-time crash, one moves layout app-wide, and
/// one makes unrelated animations re-run. This file is the thing that notices.
void main() {
  group('a circular surface is circular in every layer', () {
    /// The whole rendered surface, as bytes.
    Future<Uint8List> render(Decoration d, double side) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final size = Size(side, side);
      canvas.drawRect(
          Offset.zero & size, Paint()..color = const Color(0xFF808080));
      final painter = d.createBoxPainter();
      painter.paint(canvas, Offset.zero, ImageConfiguration(size: size));
      painter.dispose();
      final image =
          await recorder.endRecording().toImage(side.round(), side.round());
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      return bytes;
    }

    test('a circle ignores the corner radius, in every layer', () async {
      // The invariant, stated exactly: a circle's shape is fixed by its box,
      // so `radius` cannot reach the output when `circle` is true. Six of the
      // seven layers honoured that. Layer 6 - the recess - built its hole as
      // `RRect.fromRectAndRadius(shifted, Radius.circular(p.radius))`
      // regardless, so a round sunken surface got a rounded-RECT recess
      // clipped to a circle, and the corner radius leaked into a shape that
      // has no corners.
      //
      // Every channel avatar in the sidebar and the rail is one of these
      // (NeuAvatarFrame passes isCircle), and so is the circular add button.
      //
      // Asserted as byte equality rather than as a shading tolerance because
      // the visible error is only about two sRGB levels - a threshold that
      // catches it would be brittle, while this is exact and cannot drift.
      final palette = MaterialSpec.of(AppMaterial.rack).palette(true);

      for (final depth in [NeuElevation.d1, NeuElevation.d3, NeuElevation.d5]) {
        for (final role in [SurfaceRole.sunken, SurfaceRole.well]) {
          Decoration at(double radius) => SkeuoDecoration.role(
                palette: palette,
                role: role,
                depth: depth,
                radius: radius,
                circle: true,
              );

          final a = await render(at(NeuRadius.r4), 48);
          final b = await render(at(NeuRadius.r16), 48);

          var worst = 0;
          for (var i = 0; i < a.length; i++) {
            final d = (a[i] - b[i]).abs();
            if (d > worst) worst = d;
          }
          expect(worst, 0,
              reason: '$role at depth $depth renders differently at radius 4 '
                  'and radius 16 while circle is true - worst channel delta '
                  '$worst. Some layer is still building a rounded rect.');
        }
      }
    });

    test('the comparison can tell two shapes apart', () async {
      // Without this, byte equality would also pass on a painter that drew
      // nothing at all, or on a comparison that read the same buffer twice.
      final palette = MaterialSpec.of(AppMaterial.rack).palette(true);
      Decoration at(double radius) => SkeuoDecoration.role(
            palette: palette,
            role: SurfaceRole.sunken,
            depth: NeuElevation.d3,
            radius: radius,
            circle: false,
          );

      final r4 = await render(at(NeuRadius.r4), 48);
      final r16 = await render(at(NeuRadius.r16), 48);
      var worst = 0;
      for (var i = 0; i < r4.length; i++) {
        final d = (r4[i] - r16[i]).abs();
        if (d > worst) worst = d;
      }
      expect(worst, greaterThan(8),
          reason: 'radius has no effect on a NON-circular surface either, so '
              'the test above is comparing something that never varies');
    });
  });

  final soft = softSpec.palette(true);

  SkeuoDecoration deco(SurfaceRole role,
          {double depth = NeuElevation.d3,
          double radius = NeuRadius.r12,
          bool circle = false,
          Border? border}) =>
      SkeuoDecoration.role(
        palette: soft,
        role: role,
        depth: depth,
        radius: radius,
        circle: circle,
        border: border,
      );

  group('the five members BoxDecoration was supplying', () {
    test('getClipPath returns a path instead of throwing', () {
      // The base implementation throws UnsupportedError, and library_view.dart
      // wraps a themed decoration in clipBehavior: Clip.antiAlias. Inheriting
      // the default is a paint-time crash on the Library tab in every material.
      const rect = Rect.fromLTWH(0, 0, 100, 40);
      final rounded = deco(SurfaceRole.raised).getClipPath(rect, TextDirection.ltr);
      expect(rounded.getBounds(), rect);
      // A rounded path must exclude its own corner.
      expect(rounded.contains(const Offset(0.5, 0.5)), isFalse);
      expect(rounded.contains(const Offset(50, 20)), isTrue);

      final circular =
          deco(SurfaceRole.raised, circle: true).getClipPath(rect, TextDirection.ltr);
      expect(circular.contains(const Offset(50, 20)), isTrue);
    });

    test('padding is one constant, whatever the role or caller border', () {
      // Successor to the per-role assertion: padding is a TRUE constant now,
      // per the plan's own contract. It used to follow `border?.dimensions`,
      // and the day a hover added a 1.5px ring the card re-laid-out under
      // the pointer and its title re-ellipsized mid-animation ("Twitch
      // Account" became "Twitch Accou..." ON HOVER). A ring is paint, not
      // layout. The 1px also matches what every themed slot inherited from
      // BoxDecoration's Border.all(width: 1) through v1.6.0, so nothing
      // shrinks.
      for (final role in SurfaceRole.values) {
        expect(deco(role).padding, const EdgeInsets.all(1.0),
            reason: '$role padding');
      }
      final ringed = deco(SurfaceRole.raised,
          border: Border.all(color: const Color(0xFFFF0000), width: 2));
      expect(ringed.padding, const EdgeInsets.all(1.0),
          reason: 'a caller ring must not move layout');
    });

    test('padding does not move across a lerp or with depth', () {
      // A padding that varied across a lerp would make hover animations
      // animate layout.
      final a = deco(SurfaceRole.raised, depth: NeuElevation.d1);
      final b = deco(SurfaceRole.sunken, depth: NeuElevation.d5);
      for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final mid = Decoration.lerp(a, b, t)!;
        expect(mid.padding, const EdgeInsets.all(1.0), reason: 't = $t');
      }
    });

    test('hitTest excludes the rounded corners', () {
      // The base default is `true`, which would make every circular control's
      // hit area its bounding square.
      const size = Size(100, 40);
      final d = deco(SurfaceRole.raised, radius: NeuRadius.r16);
      expect(d.hitTest(size, const Offset(50, 20)), isTrue);
      expect(d.hitTest(size, const Offset(0.5, 0.5)), isFalse,
          reason: 'the top-left corner is outside a 16px radius');

      final circle = deco(SurfaceRole.raised, circle: true);
      expect(circle.hitTest(const Size(40, 40), const Offset(20, 20)), isTrue);
      expect(circle.hitTest(const Size(40, 40), const Offset(1, 1)), isFalse);
    });

    test('isComplex tracks whether anything is actually cast', () {
      expect(deco(SurfaceRole.raised).isComplex, isTrue);
      expect(deco(SurfaceRole.flat).isComplex, isFalse,
          reason: 'flat casts nothing and should not ask for a raster cache');
    });

    test('equal inputs produce equal decorations', () {
      // AnimatedWidgetBaseState restarts EVERY tween when the widget compares
      // unequal, and it returns one bool for all of them - so a decoration that
      // failed this would visibly re-run the sibling transform on every
      // unrelated rebuild.
      expect(deco(SurfaceRole.raised), deco(SurfaceRole.raised));
      expect(deco(SurfaceRole.raised).hashCode,
          deco(SurfaceRole.raised).hashCode);
      expect(deco(SurfaceRole.raised), isNot(deco(SurfaceRole.sunken)));
      expect(deco(SurfaceRole.raised, depth: NeuElevation.d1),
          isNot(deco(SurfaceRole.raised, depth: NeuElevation.d5)));
    });
  });

  group('lerp', () {
    test('a cross-role transition interpolates instead of swapping', () {
      // The checkbox animates raised to sunken on every toggle, and so does the
      // multi-select tick. Without lerpFrom/lerpTo the framework falls through
      // to `t < 0.5 ? a : b` - no assert, no log, just a pop at the midpoint.
      final a = deco(SurfaceRole.raised);
      final b = deco(SurfaceRole.sunken);

      final quarter = Decoration.lerp(a, b, 0.25)! as SkeuoDecoration;
      final half = Decoration.lerp(a, b, 0.5)! as SkeuoDecoration;
      final threeQuarter = Decoration.lerp(a, b, 0.75)! as SkeuoDecoration;

      for (final mid in [quarter, half, threeQuarter]) {
        expect(mid, isNot(a));
        expect(mid, isNot(b));
      }

      // Monotonic through the transition rather than jumping.
      expect(quarter.params.insetStrength, closeTo(0.25, 1e-9));
      expect(half.params.insetStrength, closeTo(0.5, 1e-9));
      expect(threeQuarter.params.insetStrength, closeTo(0.75, 1e-9));

      // And the endpoints are exact.
      expect(Decoration.lerp(a, b, 0.0), a);
      expect(Decoration.lerp(a, b, 1.0), b);
    });

    test('the base colour crosses continuously', () {
      final a = deco(SurfaceRole.raised); // fills from surface
      final b = deco(SurfaceRole.sunken); // fills from well
      final half = Decoration.lerp(a, b, 0.5)! as SkeuoDecoration;
      expect(half.params.base, Color.lerp(soft.surface, soft.well, 0.5));
    });

    test('interpolating from null scales out rather than popping', () {
      final d = deco(SurfaceRole.raised);
      final faded = Decoration.lerp(null, d, 0.5)! as SkeuoDecoration;
      expect(faded.params.depth, closeTo(NeuElevation.d3 * 0.5, 1e-9));
      expect(faded.params.contact.first.color.a,
          lessThan(d.params.contact.first.color.a));
    });
  });

  group('painting', () {
    /// Paints into a recorder and returns the decoded pixels.
    Future<ui.Image> render(Decoration d, Size size) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = d.createBoxPainter();
      painter.paint(canvas, Offset.zero, ImageConfiguration(size: size));
      painter.dispose();
      return recorder
          .endRecording()
          .toImage(size.width.round(), size.height.round());
    }

    test('every role paints without throwing and leaves the canvas balanced',
        () async {
      // A painter that leaves an unbalanced save() makes RenderDecoratedBox
      // throw in debug - which is why the inset clip restores in a finally.
      for (final role in SurfaceRole.values) {
        for (final depth in [NeuElevation.d0, NeuElevation.d3, NeuElevation.d5]) {
          final image = await render(
              deco(role, depth: depth), const Size(80, 32));
          expect(image.width, 80, reason: '$role at depth $depth');
          image.dispose();
        }
      }
    });

    test('a zero-size box paints nothing rather than crashing', () async {
      final recorder = ui.PictureRecorder();
      final painter = deco(SurfaceRole.raised).createBoxPainter();
      painter.paint(Canvas(recorder), Offset.zero,
          const ImageConfiguration(size: Size.zero));
      painter.dispose();
      recorder.endRecording().dispose();
    });

    test('the fill actually lands on the surface colour', () async {
      // The centre of a raised surface should be close to the material's own
      // surface, not to some blend the painter invented.
      final image = await render(
          deco(SurfaceRole.raised, depth: NeuElevation.d0), const Size(64, 64));
      final data = await image.toByteData();
      final i = ((32 * 64) + 32) * 4;
      final r = data!.getUint8(i), g = data.getUint8(i + 1), b = data.getUint8(i + 2);
      final centre = Color.fromARGB(255, r, g, b);
      final ratio = NeuTheme.contrastRatio(centre, soft.surface);
      expect(ratio, lessThan(1.15),
          reason: 'painted centre $centre should sit near ${soft.surface}');
      image.dispose();
    });
  });
}
