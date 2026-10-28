import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// The bezel and the Canvas recess, held pixel-for-pixel to what shipped.
///
/// Every VOD card and Library thumbnail carries a bezel, and a bezel always
/// takes the Canvas engine (its fill is transparent, so the opaque shader face
/// cannot draw it). Its recess layer used to run a `Path.combine` boolean -
/// rect minus rounded rect, Skia PathOps on the CPU - for every inset layer on
/// every paint, and its bevel rebuilt a seventeen-stop sweep with a `pow` per
/// stop on every paint. Both were replaced with cheaper constructions that
/// are meant to draw the SAME pixels; this is the proof.
///
/// The oracle is the shipped code itself, reproduced verbatim below rather
/// than kept alive in the painter. Goldens were deliberately skipped in this
/// project, so the comparison is against a recipe, not against a picture.
void main() {
  double sigmaOf(double blurRadius) =>
      blurRadius <= 0 ? 0 : blurRadius * 0.57735 + 0.5;

  Path shapeOf(Rect rect, SurfaceParams p) {
    final path = Path();
    if (p.circle) {
      path.addOval(rect);
    } else {
      path.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(p.radius)));
    }
    return path;
  }

  /// Layer 6 exactly as it shipped through v1.10.0.
  void insetAsShipped(Canvas canvas, Rect rect, SurfaceParams p) {
    if (p.inset.isEmpty || p.depth <= 0) return;
    canvas.save();
    canvas.clipPath(shapeOf(rect, p));
    final k = p.travelScale;
    for (final l in p.inset) {
      final sigma = sigmaOf(p.blurOverride ?? l.blur * p.depth);
      if (sigma <= 0) continue;
      final shifted = rect
          .shift(Offset(l.dx * p.depth * k, l.dy * p.depth * k))
          .inflate(l.spread * p.depth);
      final hole = Path();
      if (p.circle) {
        hole.addOval(shifted);
      } else {
        hole.addRRect(
            RRect.fromRectAndRadius(shifted, Radius.circular(p.radius)));
      }
      final outer = Path()
        ..addRect(rect.inflate(
            sigma * 4 + (p.circle ? rect.shortestSide / 2 : p.radius)));
      final band = Path.combine(PathOperation.difference, outer, hole);
      canvas.drawPath(
        band,
        Paint()
          ..color = l.color.withValues(alpha: l.color.a * p.insetStrength)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
      );
    }
    canvas.restore();
  }

  /// Layer 5 exactly as it shipped: the sweep rebuilt on every paint.
  void bevelAsShipped(Canvas canvas, Rect rect, SurfaceParams p) {
    final w = p.bevelWidth;
    final paint = Paint();
    if (p.bevelAmbientFloor >= 1.0) {
      paint.color = p.bevelColour;
    } else {
      final l = p.toLight;
      final lightAngle = math.atan2(l.dy, l.dx);
      const steps = 16;
      final colors = <Color>[];
      final stops = <double>[];
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final delta = math.cos(t * 2 * math.pi - lightAngle).clamp(-1.0, 1.0);
        final env = p.bevelAmbientFloor +
            (1 - p.bevelAmbientFloor) *
                math.pow(math.max(0.0, delta), p.bevelSweepExponent).toDouble();
        colors.add(p.bevelColour.withValues(alpha: p.bevelColour.a * env));
        stops.add(t);
      }
      paint.shader =
          SweepGradient(colors: colors, stops: stops).createShader(rect);
    }
    if (p.circle) {
      canvas.drawCircle(
          rect.center,
          (rect.shortestSide - w) / 2,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = w);
    } else {
      final outer = RRect.fromRectAndRadius(rect, Radius.circular(p.radius));
      canvas.drawDRRect(outer, outer.deflate(w), paint);
    }
  }

  /// A whole bezel as it shipped. A bezel paints no cast, fill, grain or
  /// gloss - asserted by the caller, so the oracle cannot quietly skip a
  /// layer the painter draws.
  void bezelAsShipped(Canvas canvas, Rect rect, SkeuoDecoration d) {
    final p = d.params;
    if (p.bevelWidth > 0) bevelAsShipped(canvas, rect, p);
    if (p.insetStrength > 0 && p.recessStyle == RecessStyle.trueInset) {
      insetAsShipped(canvas, rect, p);
    }
    d.border?.paint(
      canvas,
      rect,
      shape: p.circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: p.circle ? null : BorderRadius.circular(p.radius),
    );
  }

  const margin = 12.0;
  // Mid-grey: a recess darkens it and a bevel lightens it, so neither layer
  // can hide against the ground.
  const ground = Color(0xFF7A7F86);

  Future<Uint8List> render(
      Size size, void Function(Canvas canvas, Rect rect) paint) async {
    final full = Size(size.width + 2 * margin, size.height + 2 * margin);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & full, Paint()..color = ground);
    paint(canvas, const Offset(margin, margin) & size);
    final image = await rec
        .endRecording()
        .toImage(full.width.round(), full.height.round());
    final bytes = (await image.toByteData())!.buffer.asUint8List();
    image.dispose();
    return bytes;
  }

  Future<Uint8List> renderPainter(Size size, Decoration d) =>
      render(size, (canvas, rect) {
        final painter = d.createBoxPainter();
        painter.paint(canvas, rect.topLeft,
            ImageConfiguration(size: size, devicePixelRatio: 1));
        painter.dispose();
      });

  /// Byte count that differ, and by how much at worst.
  ({int pixels, int worst}) diff(Uint8List a, Uint8List b) {
    expect(a.length, b.length);
    var pixels = 0, worst = 0;
    for (var i = 0; i < a.length; i += 4) {
      var any = false;
      for (var c = 0; c < 4; c++) {
        final d = (a[i + c] - b[i + c]).abs();
        if (d > 0) any = true;
        worst = math.max(worst, d);
      }
      if (any) pixels++;
    }
    return (pixels: pixels, worst: worst);
  }

  /// Every material that draws a bezel, in both brightnesses.
  final palettes = [
    for (final spec in MaterialSpec.available)
      for (final isDark in [false, true]) (spec: spec, isDark: isDark),
  ];

  test('every shipped bezel paints exactly what it shipped painting',
      () async {
    var compared = 0;
    for (final (:spec, :isDark) in palettes) {
      for (final radius in [0.0, NeuRadius.inner(NeuRadius.r12, NeuSpace.s8),
        NeuRadius.inner(NeuRadius.r16, 1)]) {
        for (final depth in [NeuElevation.d1, NeuElevation.d2]) {
          final d = NeuTheme.bezel(isDark,
              radius: radius, depth: depth, material: spec.id);
          if (d == null) continue; // a material that declares no bezel
          final bezel = d as SkeuoDecoration;
          final p = bezel.params;
          expect(bezel.rendersLit, isFalse,
              reason: 'a bezel must take the Canvas engine');
          expect(p.contact, isEmpty, reason: 'the oracle paints no cast');
          expect(p.fillOpacity, 0, reason: 'the oracle paints no fill');
          expect(p.gloss, 0, reason: 'the oracle paints no gloss');
          expect(p.textureScale, 0, reason: 'the oracle paints no grain');

          for (final size in const [
            Size(48, 27),
            Size(120, 68),
            Size(320, 180),
          ]) {
            final shipped =
                await render(size, (c, r) => bezelAsShipped(c, r, bezel));
            final now = await renderPainter(size, bezel);
            final delta = diff(shipped, now);
            expect(delta.pixels, 0,
                reason: '${spec.id.name} ${isDark ? 'dark' : 'light'} bezel '
                    'at $size, radius $radius, depth $depth: '
                    '${delta.pixels} pixels differ, worst by '
                    '${delta.worst} levels');
            compared++;
          }
        }
      }
    }
    expect(compared, greaterThan(20),
        reason: 'precondition: most materials draw a bezel');
  });

  test('every Canvas recess paints exactly what it shipped painting',
      () async {
    // The same layer paints every sunken, well and screen surface on the
    // Canvas engine - which is every one of them when the lit engine is
    // unavailable or switched off. Isolated to the one layer: the painter is
    // handed a copy of each role's recess parameters with every other layer
    // turned off, so a difference can only come from layer 6.
    SurfaceParams recessOnly(SurfaceParams p, {required bool circle}) =>
        SurfaceParams(
          base: p.base,
          fill: const [],
          lightAzimuthDeg: p.lightAzimuthDeg,
          diagonalCompensation: p.diagonalCompensation,
          depth: p.depth,
          radius: p.radius,
          circle: circle,
          contact: const [],
          inset: p.inset,
          insetStrength: p.insetStrength,
          recessStyle: p.recessStyle,
          fillOpacity: 0,
          bevelColour: const Color(0x00000000),
          bevelWidth: 0,
          bevelSweepExponent: 1,
          bevelAmbientFloor: 1,
          gloss: 0,
          glossBreak: 0.5,
          glossHardTerminator: false,
          glossColour: const Color(0x00000000),
          textureScale: 0,
          blurOverride: p.blurOverride,
        );

    var compared = 0;
    for (final (:spec, :isDark) in palettes) {
      final palette = spec.palette(isDark);
      if (palette.recessStyle != RecessStyle.trueInset) continue;
      for (final role in [
        SurfaceRole.sunken,
        SurfaceRole.screen,
        SurfaceRole.well,
      ]) {
        for (final depth in [NeuElevation.d1, NeuElevation.d3]) {
          for (final radius in [0.0, NeuRadius.r8, NeuRadius.r12]) {
            final p = SkeuoDecoration.role(
              palette: palette,
              role: role,
              depth: depth,
              radius: radius,
            ).params;
            for (final (size, circle) in const [
              (Size(28, 28), true),
              (Size(28, 28), false),
              (Size(64, 36), false),
              (Size(220, 48), false),
            ]) {
              final params = recessOnly(p, circle: circle);
              final shipped = await render(
                  size, (c, r) => insetAsShipped(c, r, params));
              final now = await renderPainter(size, SkeuoDecoration(params));
              final delta = diff(shipped, now);
              expect(delta.pixels, 0,
                  reason: '${spec.id.name} ${isDark ? 'dark' : 'light'} '
                      '${role.name} at $size${circle ? ' (circle)' : ''}, '
                      'radius $radius, depth $depth: ${delta.pixels} pixels '
                      'differ, worst by ${delta.worst} levels');
              compared++;
            }
          }
        }
      }
    }
    expect(compared, greaterThan(100),
        reason: 'precondition: most materials recess truly');
  });

  test('a hole the outer band cannot contain still paints as it shipped',
      () async {
    // `drawDRRect` draws NOTHING when the inner shape pokes outside the
    // outer one - Skia's own precondition - where the boolean difference
    // still leaves a band. No shipped material comes near it (the band is
    // inflated by four sigmas plus the radius), but a call site with an
    // extreme offset must not lose its recess, so this pins the fallback.
    const params = SurfaceParams(
      base: Color(0xFF30343A),
      fill: [],
      lightAzimuthDeg: 135,
      diagonalCompensation: true,
      depth: 6,
      radius: 0,
      contact: [],
      inset: [
        ShadowLayer(color: Color(0xCC000000), dx: 3, dy: 3, blur: 0.2),
      ],
      insetStrength: 1,
      recessStyle: RecessStyle.trueInset,
      fillOpacity: 0,
      bevelColour: Color(0x00000000),
      bevelWidth: 0,
      bevelSweepExponent: 1,
      bevelAmbientFloor: 1,
      gloss: 0,
      glossBreak: 0.5,
      glossHardTerminator: false,
      glossColour: Color(0x00000000),
      textureScale: 0,
    );
    // Precondition: the shift really does push the hole past the band.
    final sigma = sigmaOf(0.2 * 6);
    final shift = 3 * 6 * math.sqrt1_2;
    expect(shift, greaterThan(sigma * 4),
        reason: 'precondition: this case must exercise the fallback');

    const size = Size(80, 40);
    final shipped =
        await render(size, (c, r) => insetAsShipped(c, r, params));
    final now = await renderPainter(size, const SkeuoDecoration(params));
    final delta = diff(shipped, now);
    expect(delta.pixels, 0,
        reason: '${delta.pixels} pixels differ, worst by ${delta.worst}');
  });
}
