import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'material_palette.dart';

/// The paint half of the surface engine.
///
/// A `Decoration` with its own `BoxPainter` rather than a `BoxDecoration`,
/// because the recipe is depth-relative data (see `MaterialPalette.contact`)
/// and two call sites interpolate one role into another, raised into sunken.
///
/// Widening the return type of `NeuTheme.raised()`/`sunken()` from
/// `BoxDecoration` to `Decoration` is not free, and the compiler names none of
/// what is lost. Five members have base defaults that are wrong here and that
/// `BoxDecoration` overrides today:
///
///   * [getClipPath] throws `UnsupportedError` on the base class, and
///     `library_view.dart` sets `clipBehavior: Clip.antiAlias` over a themed
///     decoration — a paint-time crash on the Library tab.
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
    Gradient? gradient,
    double? blur,
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
        // A recess fills flat as well as casting outward: the shipped
        // `sunken()` sets `color:` and never `gradient:`. Ramping it would
        // darken the far half of every well by up to 11 levels.
        fillRamp: m.insetScale > 0 ? 0.0 : 1.0,
        bevelColour: m.invertBevel ? palette.bevelShade : palette.bevelLight,
        // A caller-supplied border REPLACES the palette's own edge, exactly as
        // `border ?? Border.all(...)` did. It does not stack on top of it.
        bevelWidth: (m.bevel && border == null) ? palette.bevelWidth : 0,
        gradientOverride: gradient,
        blurOverride: blur,
      ),
      border: border,
    );
  }

  final SurfaceParams params;

  /// A caller-supplied stroke, painted last and over everything.
  ///
  /// Distinct from the bevel: the bevel is the palette's own edge, this is a
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
  /// A TRUE constant - not `border?.dimensions`, which is what the first
  /// implementation returned while its own comment claimed otherwise. A
  /// padding that follows the caller border re-layouts the content whenever a
  /// hover adds a 1.5px ring: on the quick-action cards the title crossed its
  /// ellipsis boundary and "Twitch Account" became "Twitch Accou..." ON
  /// HOVER, re-wrapping mid-animation. A ring is paint, not layout; it may
  /// overlap the outer half-pixel of content padding and nobody can see it,
  /// but a title that rewrites itself under the pointer everyone can see.
  @override
  EdgeInsetsGeometry get padding => const EdgeInsets.all(1);

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
    this.fillRamp = 1.0,
    required this.bevelColour,
    required this.bevelWidth,
    this.circle = false,
    this.gradientOverride,
    this.blurOverride,
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

  /// Both cast outward: [inset] is a recess faked with a negative spread
  /// (see `MaterialPalette.inset`).
  final List<ShadowLayer> contact, inset;

  /// How much of the fill ramp to apply, 0 = flat.
  ///
  /// Interpolable rather than a boolean because a cross-role lerp runs through
  /// it: a checkbox animating raised to sunken would otherwise snap from a
  /// gradient to a flat colour at the midpoint.
  final double fillRamp;

  /// The edge: a uniform ring, matched to the border `BoxDecoration` drew.
  final Color bevelColour;
  final double bevelWidth;

  /// A fill supplied by the call site, replacing the palette's own ramp.
  /// One caller uses it: `NeuContainer`, for the rainbow live-border case.
  final Gradient? gradientOverride;

  /// A blur supplied by the call site, replacing `layer.blur * depth`.
  ///
  /// `NeuContainer` passes one on every call. It happens to equal the derived
  /// value at its defaults, but honouring it is what makes the widening a
  /// no-op rather than a coincidence.
  final double? blurOverride;

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
        fillRamp: fillRamp,
        bevelColour: bevelColour.withValues(alpha: bevelColour.a * t),
        bevelWidth: bevelWidth,
        gradientOverride: gradientOverride,
        blurOverride: blurOverride,
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
      fillRamp: d(a.fillRamp, b.fillRamp),
      bevelColour: Color.lerp(a.bevelColour, b.bevelColour, t)!,
      bevelWidth: d(a.bevelWidth, b.bevelWidth),
      gradientOverride:
          Gradient.lerp(a.gradientOverride, b.gradientOverride, t),
      blurOverride: (a.blurOverride == null && b.blurOverride == null)
          ? null
          : d(a.blurOverride ?? 0, b.blurOverride ?? 0),
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
      other.fillRamp == fillRamp &&
      other.bevelColour == bevelColour &&
      other.bevelWidth == bevelWidth &&
      other.gradientOverride == gradientOverride &&
      other.blurOverride == blurOverride &&
      _same(other.contact, contact) &&
      _same(other.inset, inset);

  @override
  int get hashCode => Object.hashAll([
        base, lightAzimuthDeg, diagonalCompensation, depth, radius, circle,
        fillRamp, bevelColour, bevelWidth,
        gradientOverride, blurOverride,
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
    if (p.bevelWidth > 0) _paintBevel(canvas, rect, p);
    _paintBorder(canvas, rect, configuration);
  }

  /// Layer 1 — everything drawn *outside* the shape.
  ///
  /// Includes the recess layers, which is how the app's original recipe
  /// faked a well: an outer shadow pair with a negative spread, hugging the
  /// silhouette.
  void _paintCast(Canvas canvas, Rect rect, SurfaceParams p) {
    final layers = <ShadowLayer>[...p.contact, ...p.inset];
    if (layers.isEmpty || p.depth <= 0) return;

    final k = p.travelScale;
    for (final l in layers) {
      final shadow = BoxShadow(
        color: l.color,
        offset: Offset(l.dx * p.depth * k, l.dy * p.depth * k),
        blurRadius: p.blurOverride ?? l.blur * p.depth,
        spreadRadius: l.spread * p.depth,
      );
      final paint = shadow.toPaint();
      final r = rect.shift(shadow.offset).inflate(shadow.spreadRadius);
      _draw(canvas, r, p, paint);
    }
  }

  /// Layer 2 — the form gradient along the light axis.
  void _paintFill(Canvas canvas, Rect rect, SurfaceParams p) {
    final override = p.gradientOverride;
    if (override != null) {
      _draw(canvas, rect, p, Paint()..shader = override.createShader(rect));
      return;
    }
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

  /// Layer 3 — the edge: a uniform ring.
  void _paintBevel(Canvas canvas, Rect rect, SurfaceParams p) {
    final w = p.bevelWidth;
    final paint = Paint()..color = p.bevelColour;

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

  /// Layer 4 — a caller-supplied stroke, over everything.
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
}
