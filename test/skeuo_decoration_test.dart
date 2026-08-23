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

    test('padding matches the 1px border every themed slot has today', () {
      // BoxDecoration.padding is border?.dimensions, and both builders always
      // install Border.all(width: 1). Inheriting EdgeInsets.zero would shrink
      // every themed container in the app by 2px in each axis.
      for (final role in SurfaceRole.values) {
        final expected = RoleModifier.of(role).bevel ? 1.0 : 0.0;
        expect(deco(role).padding, EdgeInsets.all(expected),
            reason: '$role padding');
      }
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
