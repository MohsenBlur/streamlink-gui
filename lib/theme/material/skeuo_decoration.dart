import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'material_palette.dart';

/// The paint half of the material engine.
///
/// `BoxDecoration` tops out at one gradient, one image and a list of outer
/// shadows. A material needs seven layers in a fixed order, including a real
/// inset shadow, which the framework has no way to express at all. So this is a
/// `Decoration` with its own `BoxPainter`.
///
/// Widening the return type of `NeuTheme.raised()`/`sunken()` from
/// `BoxDecoration` to `Decoration` is not free, and the compiler names none of
/// what is lost. Five members have base defaults that are wrong here and that
/// `BoxDecoration` overrides today:
///
///   * [getClipPath] throws `UnsupportedError` on the base class, and
///     `library_view.dart` sets `clipBehavior: Clip.antiAlias` over a themed
///     decoration — a paint-time crash on the Library tab, in every material.
///   * [padding] is `border?.dimensions` on `BoxDecoration`, and both builders
///     always install a 1px border, so every themed slot in the app is inset
///     1px today. Inheriting `EdgeInsets.zero` would move layout app-wide.
///   * [operator ==] gates `RenderDecoratedBox`'s early-out and, worse,
///     `AnimatedWidgetBaseState`'s tween restart — which returns one bool for
///     *all* tweens, so an unequal decoration visibly re-runs the sibling
///     transform on every unrelated rebuild.
///   * [hitTest] defaults to `true`, which would make rounded corners live and
///     grow every circular control to its bounding square.
///   * [isComplex] is `boxShadow != null` on `BoxDecoration`.
@immutable
class SkeuoDecoration extends Decoration {
  const SkeuoDecoration(this.params, {this.border});

  /// Resolves a palette and a role into a flat parameter set.
  ///
  /// The resolution happens **here** rather than inside `paint()` because two
  /// call sites interpolate across roles — the multi-select tick and every
  /// checkbox toggle both animate raised to sunken. A `switch (role)` in the
  /// painter cannot be interpolated; a flat parameter set can.
  factory SkeuoDecoration.role({
    required MaterialPalette palette,
    required SurfaceRole role,
    required double depth,
    required double radius,
    bool circle = false,
    Color? base,
    Border? border,
  }) {
    final m = RoleModifier.of(role);
    return SkeuoDecoration(
      SurfaceParams(
        base: base ?? palette.groundFor(m.fill),
        fill: palette.fill,
        lightAzimuthDeg: palette.lightAzimuthDeg,
        diagonalCompensation: palette.diagonalCompensation,
        depth: depth,
        radius: radius,
        circle: circle,
        contact: _scaled(palette.contact, m.contactScale),
        inset: _scaled(palette.inset, m.insetScale),
        insetStrength: m.insetScale > 0 ? 1.0 : 0.0,
        // A faked recess fills flat as well as casting outward: the shipped
        // `sunken()` sets `color:` and never `gradient:`. Ramping it would
        // darken the far half of every well by up to 11 levels.
        fillRamp: (palette.recessStyle == RecessStyle.outerFake &&
                m.insetScale > 0)
            ? 0.0
            : 1.0,
        recessStyle: palette.recessStyle,
        bevelColour: m.invertBevel ? palette.bevelShade : palette.bevelLight,
        bevelWidth: m.bevel ? palette.bevelWidth : 0,
        bevelSweepExponent: palette.bevelSweepExponent,
        bevelAmbientFloor:
            palette.bevelUniform ? 1.0 : palette.bevelAmbientFloor,
        gloss: palette.gloss * m.glossScale,
        glossBreak: palette.glossBreak,
        glossHardTerminator: palette.glossHardTerminator,
        glossColour: palette.glossColour,
        texture: palette.texture,
        textureScale: m.textureScale,
      ),
      border: border,
    );
  }

  final SurfaceParams params;

  /// A caller-supplied stroke, painted last and over everything.
  ///
  /// Distinct from the bevel: the bevel is the material's own edge, this is a
  /// decoration a call site asks for — a selection ring, a focus outline.
  final Border? border;

  static List<ShadowLayer> _scaled(List<ShadowLayer> layers, double scale) {
    if (scale == 0 || layers.isEmpty) return const <ShadowLayer>[];
    if (scale == 1.0) return layers;
    return [
      for (final l in layers)
        ShadowLayer(
          color: l.color,
          dx: l.dx * scale,
          dy: l.dy * scale,
          blur: l.blur * scale,
          spread: l.spread * scale,
        ),
    ];
  }

  // --- the five members BoxDecoration was supplying -------------------------

  /// Bevels paint *inside* this and never claim more box.
  ///
  /// A constant regardless of material, depth or lerp position. A padding that
  /// varied by material would move layout on a material switch; one that varied
  /// across a lerp would make hover animations animate layout.
  @override
  EdgeInsetsGeometry get padding => EdgeInsets.all(params.bevelWidth);

  @override
  Path getClipPath(Rect rect, TextDirection textDirection) {
    final path = Path();
    if (params.circle) {
      path.addOval(rect);
    } else {
      path.addRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(params.radius)));
    }
    return path;
  }

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) {
    final rect = Offset.zero & size;
    if (params.circle) {
      final r = math.min(size.width, size.height) / 2;
      return (position - rect.center).distance <= r;
    }
    return RRect.fromRectAndRadius(rect, Radius.circular(params.radius))
        .contains(position);
  }

  @override
  bool get isComplex => params.contact.isNotEmpty || params.inset.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is SkeuoDecoration &&
      other.params == params &&
      other.border == border;

  @override
  int get hashCode => Object.hash(params, border);

  // --- interpolation --------------------------------------------------------
  //
  // The base implementations return null, and `Decoration.lerp` then falls
  // through to `t < 0.5 ? a : b`. Nothing asserts and nothing logs: the
  // decoration simply hard-swaps halfway through every hover animation. A crash
  // would be caught on the first run; a mid-animation pop ships.

  @override
  Decoration? lerpFrom(Decoration? a, double t) {
    if (a == null) return SkeuoDecoration(params.scaled(t), border: border);
    if (a is SkeuoDecoration) {
      return SkeuoDecoration(
        SurfaceParams.lerp(a.params, params, t),
        border: Border.lerp(a.border, border, t),
      );
    }
    return null;
  }

  @override
  Decoration? lerpTo(Decoration? b, double t) {
    if (b == null) return SkeuoDecoration(params.scaled(1 - t), border: border);
    if (b is SkeuoDecoration) {
      return SkeuoDecoration(
        SurfaceParams.lerp(params, b.params, t),
        border: Border.lerp(border, b.border, t),
      );
    }
    return null;
  }

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _SkeuoPainter(this, onChanged);
}

/// A surface's paint recipe with the role already resolved away.
///
/// Flat and interpolable on purpose: role is never switched on inside
/// `paint()`, because two call sites animate across roles and an enum cannot be
/// tweened.
@immutable
class SurfaceParams {
  const SurfaceParams({
    required this.base,
    required this.fill,
    required this.lightAzimuthDeg,
    required this.diagonalCompensation,
    required this.depth,
    required this.radius,
    required this.contact,
    required this.inset,
    required this.insetStrength,
    required this.recessStyle,
    this.fillRamp = 1.0,
    required this.bevelColour,
    required this.bevelWidth,
    required this.bevelSweepExponent,
    required this.bevelAmbientFloor,
    required this.gloss,
    required this.glossBreak,
    required this.glossHardTerminator,
    required this.glossColour,
    required this.textureScale,
    this.texture,
    this.circle = false,
  });

  final Color base;
  final List<FillStop> fill;

  /// Degrees counter-clockwise from +x, naming the direction of the light
  /// *source* in screen space where y grows downward.
  ///
  /// So 90 is directly above and 135 is above-left. Stated explicitly because
  /// every other convention in circulation disagrees with every other, and a
  /// mirrored bevel is the defect nobody can name but everyone sees.
  final double lightAzimuthDeg;

  final bool diagonalCompensation;
  final double depth, radius;
  final bool circle;

  final List<ShadowLayer> contact, inset;
  final double insetStrength;
  final RecessStyle recessStyle;

  /// How much of the fill ramp to apply, 0 = flat.
  ///
  /// Interpolable rather than a boolean because a cross-role lerp runs through
  /// it: a checkbox animating raised to sunken would otherwise snap from a
  /// gradient to a flat colour at the midpoint.
  final double fillRamp;

  final Color bevelColour;
  final double bevelWidth, bevelSweepExponent, bevelAmbientFloor;

  final double gloss, glossBreak;
  final bool glossHardTerminator;
  final Color glossColour;

  final TextureSpec? texture;
  final double textureScale;

  /// Unit vector pointing at the light source.
  Offset get toLight {
    final r = lightAzimuthDeg * math.pi / 180.0;
    return Offset(math.cos(r), -math.sin(r));
  }

  /// [toLight] pushed out to the edge of the alignment square.
  ///
  /// `Alignment` is not a direction, it is a *point*: (-1,-1) is the top-left
  /// corner. Feeding it a raw unit vector puts the gradient's first stop
  /// 29% inside the box on a diagonal, which shortens the ramp and stops the
  /// corners ever reaching the end colours. Scaling so the larger component
  /// reaches 1 lands exactly on `Alignment.topLeft` at 135 degrees and on
  /// `Alignment.topCenter` at 90.
  Alignment get lightCorner {
    final l = toLight;
    final m = math.max(l.dx.abs(), l.dy.abs());
    if (m < 1e-6) return Alignment.topCenter;
    return Alignment(l.dx / m, l.dy / m);
  }

  /// Diagonal offsets travel `sqrt(2)` further than axis-aligned ones, so an
  /// uncompensated diagonal shadow reads a full elevation step too high.
  double get travelScale {
    if (!diagonalCompensation) return 1.0;
    final l = toLight;
    return (l.dx.abs() > 0.001 && l.dy.abs() > 0.001) ? math.sqrt1_2 : 1.0;
  }

  /// Fades every layer out toward nothing, for interpolating from null.
  SurfaceParams scaled(double t) => SurfaceParams(
        base: base,
        fill: fill,
        lightAzimuthDeg: lightAzimuthDeg,
        diagonalCompensation: diagonalCompensation,
        depth: depth * t,
        radius: radius,
        circle: circle,
        contact: ShadowLayer.lerpList(const [], contact, t),
        inset: ShadowLayer.lerpList(const [], inset, t),
        insetStrength: insetStrength * t,
        fillRamp: fillRamp,
        recessStyle: recessStyle,
        bevelColour: bevelColour.withValues(alpha: bevelColour.a * t),
        bevelWidth: bevelWidth,
        bevelSweepExponent: bevelSweepExponent,
        bevelAmbientFloor: bevelAmbientFloor,
        gloss: gloss * t,
        glossBreak: glossBreak,
        glossHardTerminator: glossHardTerminator,
        glossColour: glossColour,
        texture: texture,
        textureScale: textureScale * t,
      );

  static SurfaceParams lerp(SurfaceParams a, SurfaceParams b, double t) {
    double d(double x, double y) => x + (y - x) * t;
    return SurfaceParams(
      base: Color.lerp(a.base, b.base, t)!,
      // Stops are a shape, not a scalar: interpolating a two-stop ramp toward a
      // three-stop one would need resampling. Cross-fading the resolved colours
      // is what actually reads correctly, so the stop list snaps at the
      // midpoint while every colour it produces is interpolated through `base`.
      fill: t < 0.5 ? a.fill : b.fill,
      lightAzimuthDeg: d(a.lightAzimuthDeg, b.lightAzimuthDeg),
      diagonalCompensation:
          t < 0.5 ? a.diagonalCompensation : b.diagonalCompensation,
      depth: d(a.depth, b.depth),
      radius: d(a.radius, b.radius),
      circle: t < 0.5 ? a.circle : b.circle,
      contact: ShadowLayer.lerpList(a.contact, b.contact, t),
      inset: ShadowLayer.lerpList(a.inset, b.inset, t),
      insetStrength: d(a.insetStrength, b.insetStrength),
      fillRamp: d(a.fillRamp, b.fillRamp),
      recessStyle: t < 0.5 ? a.recessStyle : b.recessStyle,
      bevelColour: Color.lerp(a.bevelColour, b.bevelColour, t)!,
      bevelWidth: d(a.bevelWidth, b.bevelWidth),
      bevelSweepExponent: d(a.bevelSweepExponent, b.bevelSweepExponent),
      bevelAmbientFloor: d(a.bevelAmbientFloor, b.bevelAmbientFloor),
      gloss: d(a.gloss, b.gloss),
      glossBreak: d(a.glossBreak, b.glossBreak),
      glossHardTerminator:
          t < 0.5 ? a.glossHardTerminator : b.glossHardTerminator,
      glossColour: Color.lerp(a.glossColour, b.glossColour, t)!,
      texture: t < 0.5 ? a.texture : b.texture,
      textureScale: d(a.textureScale, b.textureScale),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SurfaceParams &&
      other.base == base &&
      _sameFill(other.fill, fill) &&
      other.lightAzimuthDeg == lightAzimuthDeg &&
      other.diagonalCompensation == diagonalCompensation &&
      other.depth == depth &&
      other.radius == radius &&
      other.circle == circle &&
      other.insetStrength == insetStrength &&
      other.fillRamp == fillRamp &&
      other.recessStyle == recessStyle &&
      other.bevelColour == bevelColour &&
      other.bevelWidth == bevelWidth &&
      other.bevelSweepExponent == bevelSweepExponent &&
      other.bevelAmbientFloor == bevelAmbientFloor &&
      other.gloss == gloss &&
      other.glossBreak == glossBreak &&
      other.glossHardTerminator == glossHardTerminator &&
      other.glossColour == glossColour &&
      other.texture == texture &&
      other.textureScale == textureScale &&
      _same(other.contact, contact) &&
      _same(other.inset, inset);

  @override
  int get hashCode => Object.hashAll([
        base, lightAzimuthDeg, diagonalCompensation, depth, radius, circle,
        insetStrength, fillRamp, recessStyle, bevelColour, bevelWidth,
        bevelSweepExponent, bevelAmbientFloor, gloss, glossBreak,
        glossHardTerminator, glossColour, texture, textureScale,
        Object.hashAll(fill.map((s) => Object.hash(s.at, s.dh, s.ds, s.dl))),
        Object.hashAll(contact), Object.hashAll(inset),
      ]);

  /// A real comparison, not identity.
  ///
  /// Identity would be conservative in the wrong direction: two equal-but-
  /// distinct stop lists would report unequal, and an unequal decoration
  /// restarts every tween on the widget — which is the exact bug this
  /// `operator ==` exists to prevent.
  static bool _sameFill(List<FillStop> a, List<FillStop> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].at != b[i].at ||
          a[i].dh != b[i].dh ||
          a[i].ds != b[i].ds ||
          a[i].dl != b[i].dl) {
        return false;
      }
    }
    return true;
  }

  static bool _same(List<ShadowLayer> a, List<ShadowLayer> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _SkeuoPainter extends BoxPainter {
  _SkeuoPainter(this.decoration, VoidCallback? onChanged) : super(onChanged);

  final SkeuoDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final p = decoration.params;
    final rect = offset & size;

    _paintCast(canvas, rect, p);
    _paintFill(canvas, rect, p);
    // Layer 3 (texture) and layer 4 (gloss) are no-ops for every material that
    // currently exists: Soft declares neither. They are branches rather than
    // stubs — the tile cache plugs into the first, and a palette with gloss
    // lights up the second with no change here.
    if (p.textureScale > 0 && p.texture != null) {
      _paintTexture(canvas, rect, p);
    }
    if (p.gloss > 0) _paintGloss(canvas, rect, p);
    if (p.bevelWidth > 0) _paintBevel(canvas, rect, p);
    if (p.insetStrength > 0 && p.recessStyle == RecessStyle.trueInset) {
      _paintInset(canvas, rect, p);
    }
    _paintBorder(canvas, rect, configuration);
  }

  /// Layer 1 — everything drawn *outside* the shape.
  ///
  /// Includes the recess layers when the palette uses [RecessStyle.outerFake],
  /// which is how the app's original recipe faked a well: an outer shadow pair
  /// with a negative spread, hugging the silhouette.
  void _paintCast(Canvas canvas, Rect rect, SurfaceParams p) {
    final layers = <ShadowLayer>[
      ...p.contact,
      if (p.recessStyle == RecessStyle.outerFake) ...p.inset,
    ];
    if (layers.isEmpty || p.depth <= 0) return;

    final k = p.travelScale;
    for (final l in layers) {
      final shadow = BoxShadow(
        color: l.color,
        offset: Offset(l.dx * p.depth * k, l.dy * p.depth * k),
        blurRadius: l.blur * p.depth,
        spreadRadius: l.spread * p.depth,
      );
      final paint = shadow.toPaint();
      final r = rect.shift(shadow.offset).inflate(shadow.spreadRadius);
      _draw(canvas, r, p, paint);
    }
  }

  /// Layer 2 — the form gradient along the light axis.
  void _paintFill(Canvas canvas, Rect rect, SurfaceParams p) {
    final begin = p.lightCorner;
    final gradient = LinearGradient(
      begin: begin,
      end: -begin,
      colors: [
        for (final stop in p.fill) _shade(p, stop),
      ],
      stops: [for (final stop in p.fill) stop.at],
    );
    _draw(canvas, rect, p, Paint()..shader = gradient.createShader(rect));
  }

  void _paintTexture(Canvas canvas, Rect rect, SurfaceParams p) {
    // The tile cache lands with the first textured material. Until then this
    // branch is unreachable: no palette declares a texture.
  }

  /// Layer 4 — the specular sweep, with a terminator.
  void _paintGloss(Canvas canvas, Rect rect, SurfaceParams p) {
    final begin = p.lightCorner;
    final peak = p.glossColour.withValues(alpha: p.gloss);
    final gradient = LinearGradient(
      begin: begin,
      end: -begin,
      colors: [
        peak,
        peak.withValues(alpha: p.gloss * 0.35),
        p.glossColour.withValues(alpha: 0),
      ],
      stops: p.glossHardTerminator
          ? [0.0, p.glossBreak, p.glossBreak]
          : [0.0, p.glossBreak, math.min(1.0, p.glossBreak + 0.35)],
    );
    _draw(canvas, rect, p, Paint()..shader = gradient.createShader(rect));
  }

  /// Layer 5 — the edge.
  ///
  /// A uniform ring when the material says so; otherwise an envelope that is
  /// brightest where it faces the light and dims to [bevelAmbientFloor] on the
  /// far side. A constant-alpha ring reads as a CSS border rather than a curved
  /// edge catching a light.
  void _paintBevel(Canvas canvas, Rect rect, SurfaceParams p) {
    final w = p.bevelWidth;
    final paint = Paint();

    if (p.bevelAmbientFloor >= 1.0) {
      paint.color = p.bevelColour;
    } else {
      // A sweep centred on the shape, peaking toward the light and dimming to
      // the ambient floor on the far side. A constant-alpha ring reads as a CSS
      // border rather than a curved edge catching a light.
      final l = p.toLight;
      final lightAngle = math.atan2(l.dy, l.dx);
      const steps = 16;
      final colors = <Color>[];
      final stops = <double>[];
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final delta =
            math.cos(t * 2 * math.pi - lightAngle).clamp(-1.0, 1.0);
        final env = p.bevelAmbientFloor +
            (1 - p.bevelAmbientFloor) *
                math.pow(math.max(0.0, delta), p.bevelSweepExponent).toDouble();
        colors.add(p.bevelColour.withValues(alpha: p.bevelColour.a * env));
        stops.add(t);
      }
      paint.shader = SweepGradient(colors: colors, stops: stops)
          .createShader(rect);
    }

    // Matched to `BoxBorder._paintUniformBorderWithRadius`, which fills the
    // ring between two RRects rather than stroking a path. A centred stroke at
    // `radius - w/2` traces a different curve through the corner arc and
    // anti-aliases differently — worth 14 levels on the corner pixels, which
    // is exactly what the fidelity gate caught.
    if (p.circle) {
      // And to `_paintUniformBorderWithCircle`, which strokes at
      // `(shortestSide - w) / 2`.
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

  /// Layer 6 — a real recess.
  ///
  /// Built as `(a rect well outside the shape) minus (the shape, offset toward
  /// the light)`, filled with a blurred paint while clipped to the shape. That
  /// leaves a dark band on the edge the light does not reach, which is what an
  /// inset shadow is. `BlurStyle.inner` fades inward from every edge equally
  /// and cannot express the offset.
  void _paintInset(Canvas canvas, Rect rect, SurfaceParams p) {
    if (p.inset.isEmpty || p.depth <= 0) return;
    final clip = decoration.getClipPath(rect, TextDirection.ltr);
    canvas.save();
    try {
      canvas.clipPath(clip);
      final k = p.travelScale;
      for (final l in p.inset) {
        final sigma = _sigma(l.blur * p.depth);
        if (sigma <= 0) continue;
        final shifted = rect
            .shift(Offset(l.dx * p.depth * k, l.dy * p.depth * k))
            .inflate(l.spread * p.depth);
        final hole = Path()
          ..addRRect(RRect.fromRectAndRadius(
              shifted, Radius.circular(p.radius)));
        final outer = Path()..addRect(rect.inflate(sigma * 4 + p.radius));
        final band = Path.combine(PathOperation.difference, outer, hole);
        canvas.drawPath(
          band,
          Paint()
            ..color = l.color.withValues(alpha: l.color.a * p.insetStrength)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
        );
      }
    } finally {
      // RenderDecoratedBox throws in debug if the painter's save count differs.
      canvas.restore();
    }
  }

  /// Layer 7 — a caller-supplied stroke, over everything.
  void _paintBorder(Canvas canvas, Rect rect, ImageConfiguration configuration) {
    final b = decoration.border;
    if (b == null) return;
    final p = decoration.params;
    b.paint(
      canvas,
      rect,
      shape: p.circle ? BoxShape.circle : BoxShape.rectangle,
      borderRadius: p.circle
          ? null
          : BorderRadius.circular(p.radius),
      textDirection: configuration.textDirection,
    );
  }

  Color _shade(SurfaceParams p, FillStop stop) {
    if (p.fillRamp <= 0) return p.base;
    final k = p.fillRamp;
    final hsl = HSLColor.fromColor(p.base);
    final target = hsl.lightness + stop.dl * k;
    return hsl
        .withLightness(target.clamp(0.0, 1.0))
        .withSaturation((hsl.saturation + stop.ds * k).clamp(0.0, 1.0))
        .withHue((hsl.hue + stop.dh * k) % 360)
        .toColor();
  }

  void _draw(Canvas canvas, Rect rect, SurfaceParams p, Paint paint,
      {double deflateRadius = 0}) {
    if (p.circle) {
      canvas.drawOval(rect, paint);
    } else {
      final r = math.max(0.0, p.radius - deflateRadius);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(r)), paint);
    }
  }

  /// Flutter's blur radius is not CSS's: `sigma = 0.57735 * radius + 0.5`.
  /// Pasting a CSS blur straight in over-blurs by about a fifth.
  static double _sigma(double blurRadius) =>
      blurRadius <= 0 ? 0 : blurRadius * 0.57735 + 0.5;
}
