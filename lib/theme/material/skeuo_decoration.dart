import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'lit_surface.dart';
import 'material_palette.dart';
import 'texture_cache.dart';

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
    Gradient? gradient,
    double? blur,
    double fillOpacity = 1.0,
  }) {
    final m = RoleModifier.of(role);
    // The dark-side depth cue, folded into the base before the gradient sees
    // it. Resolved here rather than in paint() so it interpolates: a lerp
    // between two depths crosses overlay alphas smoothly instead of stepping.
    var ground = base ?? palette.groundFor(m.fill);
    if (palette.darkDepth == DarkDepth.elevationOverlay && depth > 0) {
      final a = palette.overlayFor(depth);
      if (a > 0) {
        ground = Color.alphaBlend(
            const Color(0xFFFFFFFF).withValues(alpha: a), ground);
      }
    }
    return SkeuoDecoration(
      SurfaceParams(
        base: ground,
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
        fillOpacity: fillOpacity,
        recessStyle: palette.recessStyle,
        bevelColour: m.invertBevel ? palette.bevelShade : palette.bevelLight,
        // A caller-supplied border REPLACES the material's own edge, exactly as
        // `border ?? Border.all(...)` did. It does not stack on top of it.
        bevelWidth: (m.bevel && border == null) ? palette.bevelWidth : 0,
        bevelSweepExponent: palette.bevelSweepExponent,
        bevelAmbientFloor:
            palette.bevelUniform ? 1.0 : palette.bevelAmbientFloor,
        gloss: palette.gloss * m.glossScale,
        glossBreak: palette.glossBreak,
        glossHardTerminator: palette.glossHardTerminator,
        glossColour: palette.glossColour,
        texture: palette.texture,
        textureScale: m.textureScale,
        textureAmplitude: palette.texture?.amplitudeFor(role) ?? 0,
        gradientOverride: gradient,
        blurOverride: blur,
        // The role half of the lit model, resolved to flat scalars for the
        // same reason contactScale is: two call sites tween across roles.
        //
        // litShadow IS contactScale - the cast policy is the same one the
        // Canvas path already encodes: panels at half, raised at full,
        // recesses not at all. Grain is broader than the Canvas tile's
        // panel-only rule because the shader grain fades itself out below
        // its Nyquist limit, so chips opt out by geometry rather than by
        // role.
        lit: role == SurfaceRole.flat ? null : palette.litFor(role),
        litRecess: m.insetScale > 0 ? 1.0 : 0.0,
        litShadow: m.contactScale,
        litGrain: switch (role) {
          SurfaceRole.panel => 1.0,
          SurfaceRole.raised => 0.7,
          SurfaceRole.sunken => 0.5,
          SurfaceRole.well => 0.35,
          SurfaceRole.screen || SurfaceRole.flat => 0.0,
        },
        litAmbience: switch (role) {
          SurfaceRole.sunken || SurfaceRole.well => 0.65,
          _ => 1.0,
        },
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

  /// Whether this decoration paints through the fragment shader.
  ///
  /// Public because tests assert the routing directly - a wrong branch here
  /// still paints *something* plausible through the other engine, which no
  /// screenshot notices until a material looks subtly dead.
  ///
  /// The Canvas path keeps three jobs the shader cannot or must not take:
  /// a caller-supplied [SurfaceParams.gradientOverride] (the rainbow live
  /// border), a translucent fill ([SurfaceParams.fillOpacity] below 1 - the
  /// screen bezel over a video thumbnail, where an opaque shader face would
  /// obliterate the picture), and every paint before the program loads or
  /// after it fails, which is the same surface the app shipped through
  /// v1.6.0.
  bool get rendersLit =>
      params.lit != null &&
      params.gradientOverride == null &&
      params.fillOpacity >= 1 &&
      LitSurfaceProgram.ready;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => rendersLit
      ? _LitPainter(this, onChanged)
      : _SkeuoPainter(this, onChanged);
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
    this.fillOpacity = 1.0,
    required this.bevelColour,
    required this.bevelWidth,
    required this.bevelSweepExponent,
    required this.bevelAmbientFloor,
    required this.gloss,
    required this.glossBreak,
    required this.glossHardTerminator,
    required this.glossColour,
    required this.textureScale,
    this.textureAmplitude = 0,
    this.texture,
    this.circle = false,
    this.gradientOverride,
    this.blurOverride,
    this.lit,
    this.litRecess = 0,
    this.litShadow = 0,
    this.litGrain = 0,
    this.litAmbience = 1,
    this.litOpacity = 1,
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

  /// How opaque the fill is, 0 = paint no fill at all.
  ///
  /// Distinct from [fillRamp], which flattens the ramp but still paints the
  /// base. This is for a surface drawn *over* content that has to survive: a
  /// screen bezel around a video thumbnail is the same inset, bevel and edge
  /// as a screen, minus the one layer that would obliterate the picture.
  ///
  /// A double rather than a bool so a cross-role lerp can cross it, on the
  /// same reasoning as [fillRamp].
  final double fillOpacity;

  final Color bevelColour;
  final double bevelWidth, bevelSweepExponent, bevelAmbientFloor;

  final double gloss, glossBreak;
  final bool glossHardTerminator;
  final Color glossColour;

  final TextureSpec? texture;
  final double textureScale;

  /// Peak deviation in sRGB levels for THIS role. Zero means no grain, which
  /// is how a chip opts out without the material having to know about chips.
  final int textureAmplitude;

  /// A fill supplied by the call site, replacing the material's own ramp.
  /// One caller uses it: `NeuContainer`, for the rainbow live-border case.
  final Gradient? gradientOverride;

  /// A blur supplied by the call site, replacing `layer.blur * depth`.
  ///
  /// `NeuContainer` passes one on every call. It happens to equal the derived
  /// value at its defaults, but honouring it is what makes the widening a
  /// no-op rather than a coincidence.
  final double? blurOverride;

  /// The material's lit model, or null for a Canvas-painted surface.
  ///
  /// When non-null (and the program loaded, and nothing forces the Canvas
  /// path) the painter is `_LitPainter`: one fragment-shader draw that covers
  /// every layer below. The four scalars are the ROLE half of the lit model,
  /// resolved by the factory the same way `contactScale` and friends are -
  /// flat doubles, so a cross-role checkbox tween interpolates them instead
  /// of switching on an enum.
  final LitSpec? lit;

  /// 0 proud .. 1 recessed. Continuous for the raised<->sunken tween.
  final double litRecess;

  /// Cast-shadow strength for this role: panels cast at half, recesses not
  /// at all - the same policy `RoleModifier.contactScale` encodes for the
  /// Canvas path.
  final double litShadow;

  /// Grain strength for this role. Unlike the Canvas tile - which only panels
  /// carry, because a tiled image aliases at chip sizes - the shader grain
  /// has an analytic Nyquist fade, so smaller roles can carry it too and it
  /// removes itself where it cannot resolve.
  final double litGrain;

  /// How much of the room this role's face sees, 0..1.
  ///
  /// Scales the ambient, environment, sheen and rim - never the key light.
  /// A well's floor is partly occluded from the sky it would otherwise
  /// reflect, and a screen is emissive glass that swallows the room almost
  /// entirely; without this, a recess glows and a log pane washes out under
  /// its own reflection. Measured: the light theme's screen face sat 56
  /// levels above its albedo at full ambience.
  final double litAmbience;

  /// Whole-surface opacity, for fading in from nothing (`scaled`). Maps to
  /// the shader's tone-map alpha rather than a saveLayer.
  final double litOpacity;

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
        fillOpacity: fillOpacity,
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
        textureAmplitude: textureAmplitude,
        gradientOverride: gradientOverride,
        blurOverride: blurOverride,
        lit: lit,
        litRecess: litRecess,
        litShadow: litShadow * t,
        litGrain: litGrain * t,
        litAmbience: litAmbience,
        litOpacity: litOpacity * t,
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
      fillOpacity: d(a.fillOpacity, b.fillOpacity),
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
      textureAmplitude:
          d(a.textureAmplitude.toDouble(), b.textureAmplitude.toDouble())
              .round(),
      gradientOverride:
          Gradient.lerp(a.gradientOverride, b.gradientOverride, t),
      blurOverride: (a.blurOverride == null && b.blurOverride == null)
          ? null
          : d(a.blurOverride ?? 0, b.blurOverride ?? 0),
      lit: LitSpec.lerp(a.lit, b.lit, t),
      litRecess: d(a.litRecess, b.litRecess),
      litShadow: d(a.litShadow, b.litShadow),
      litGrain: d(a.litGrain, b.litGrain),
      litAmbience: d(a.litAmbience, b.litAmbience),
      litOpacity: d(a.litOpacity, b.litOpacity),
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
      other.fillOpacity == fillOpacity &&
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
      other.textureAmplitude == textureAmplitude &&
      other.gradientOverride == gradientOverride &&
      other.blurOverride == blurOverride &&
      other.lit == lit &&
      other.litRecess == litRecess &&
      other.litShadow == litShadow &&
      other.litGrain == litGrain &&
      other.litAmbience == litAmbience &&
      other.litOpacity == litOpacity &&
      _same(other.contact, contact) &&
      _same(other.inset, inset);

  @override
  int get hashCode => Object.hashAll([
        base, lightAzimuthDeg, diagonalCompensation, depth, radius, circle,
        insetStrength, fillRamp, fillOpacity, recessStyle, bevelColour,
        bevelWidth,
        bevelSweepExponent, bevelAmbientFloor, gloss, glossBreak,
        glossHardTerminator, glossColour, texture, textureScale,
        textureAmplitude,
        gradientOverride, blurOverride,
        lit, litRecess, litShadow, litGrain, litAmbience, litOpacity,
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

  /// Set once this painter is torn down.
  ///
  /// `TextureCache` holds `onChanged` - which `RenderDecoratedBox` wires to its
  /// own `markNeedsPaint` - in a static queue with no unregister path. A
  /// textured surface that leaves the tree while its tile is generating (the
  /// frame or two after launch, or after a material switch) therefore leaves a
  /// dead callback behind, and the cache invokes it when the tile lands.
  ///
  /// In release that is harmless: `RenderDecoratedBox.detach` already set
  /// `_needsPaint`, so `markNeedsPaint` early-returns. In debug it trips
  /// `assert(!_debugDisposed)`, and the throw aborts the loop that notifies
  /// everyone else in the queue - so a *live* surface behind the dead one is
  /// left untextured until something unrelated repaints it.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

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
    if (p.textureScale > 0 && p.texture != null && p.textureAmplitude > 0) {
      _paintTexture(canvas, rect, p, configuration);
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
    // A bezel: every other layer, and not this one. Returning early rather
    // than painting at alpha 0 also skips building a shader nothing samples.
    if (p.fillOpacity <= 0) return;
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

  void _paintTexture(Canvas canvas, Rect rect, SurfaceParams p,
      ImageConfiguration configuration) {
    final spec = p.texture!;

    // Below this the structure aliases into something that reads as JPEG
    // damage rather than as material, so a chip gets the plain fill.
    if (rect.shortestSide < spec.dropBelowPx) return;

    final dpr = configuration.devicePixelRatio ?? 1.0;
    final key = TileKey(
      kind: spec.kind,
      width: spec.tileDevicePx.width.round(),
      height: spec.tileDevicePx.height.round(),
      amplitude: (p.textureAmplitude * p.textureScale).round(),
      seed: spec.seed,
    );

    final tile = TextureCache.lookup(key);
    if (tile == null) {
      // Miss: paint no grain this frame and ask for it. The surface reads as
      // an untextured material until the tile lands, which is a frame later
      // and indistinguishable in practice.
      final notify = onChanged;
      if (notify != null) {
        // Guarded, not raw: see `_disposed`.
        TextureCache.request(key, () {
          if (!_disposed) notify();
        });
      }
      return;
    }

    // The matrix is anchored to the BOX, not to the layer. A RepaintBoundary
    // repaints its child at Offset.zero, so an identity matrix would make the
    // grain jump phase the moment a boundary is added for performance - a
    // change that has nothing to do with texture and would be very hard to
    // connect to it.
    final matrix = Matrix4.identity()
      ..translateByDouble(rect.left, rect.top, 0, 1)
      ..rotateZ(spec.grainAngleDeg * math.pi / 180.0)
      ..scaleByDouble(1.0 / dpr, 1.0 / dpr, 1, 1);

    final paint = Paint()
      // Adds exactly: result = dst + deviation, independent of the ground and
      // of the gradient under it. See TextureCache for why this is not srcOver.
      ..blendMode = BlendMode.plus
      ..shader = ImageShader(
          tile, TileMode.repeated, TileMode.repeated, matrix.storage);

    canvas.save();
    try {
      canvas.clipPath(decoration.getClipPath(rect, TextDirection.ltr));
      canvas.drawRect(rect, paint);
    } finally {
      canvas.restore();
    }
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
        final sigma = _sigma(p.blurOverride ?? l.blur * p.depth);
        if (sigma <= 0) continue;
        final shifted = rect
            .shift(Offset(l.dx * p.depth * k, l.dy * p.depth * k))
            .inflate(l.spread * p.depth);
        // Circle-aware, like every other layer. This one was not, and it is
        // the layer where it shows most: a circular sunken surface got a
        // ROUNDED-RECT hole punched in it, clipped to a circle. The band that
        // remains is then thickest at the diagonals - where the rect's corner
        // arc falls furthest inside the circle - so a lens bezel read as an
        // oval pressed into a round hole. Every channel avatar in the sidebar
        // and the rail is one of these, and so is the circular add button.
        //
        // `_draw` cannot be reused here because this is a Path for
        // `Path.combine`, not a fill.
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

/// The shader path: one lit surface, shadow and all, in a single draw.
///
/// Everything `_SkeuoPainter` builds out of seven Canvas layers - cast
/// shadow, contact occlusion, fill, grain, gloss, bevel, recess - is one
/// `drawRect` here, evaluated per pixel as a function of a surface NORMAL
/// rather than of position. That is the entire difference between a lit
/// object and a picture of one, and it is why no amount of gradient tuning
/// ever made the Canvas engine stop reading as flat.
///
/// The painter's own responsibilities are exactly three:
///
///  * geometry - the draw rect is the surface inflated by the shadow's
///    reach, because the shadow lives INSIDE the shader's output and needs
///    somewhere to land;
///  * the translate - `FlutterFragCoord()` is canvas-local, not shape-local
///    (measured), so the shader assumes its origin is the draw rect's corner
///    and the painter must make that true;
///  * the uniform write, in declaration order, through one shared shader
///    instance. Uniforms are snapshotted per draw (verified), so mutating
///    the shared instance between draws is correct - and 5x cheaper than
///    allocating per surface.
class _LitPainter extends BoxPainter {
  _LitPainter(this.decoration, VoidCallback? onChanged) : super(onChanged);

  final SkeuoDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final p = decoration.params;
    final spec = p.lit!;

    // Cast-shadow geometry, in the palette's own light convention: the
    // shadow falls directly away from `lightAzimuthDeg`, at a distance and
    // blur that scale with elevation depth exactly as `ShadowLayer` does.
    // `travelScale` keeps the sqrt(2) diagonal compensation the Canvas path
    // applies, so a material switch does not re-rank every elevation.
    final az = p.lightAzimuthDeg * math.pi / 180.0;
    final mag = spec.shadowDyPerDepth * p.depth * p.litShadow * p.travelScale;
    final blur = (p.blurOverride ?? spec.shadowBlurPerDepth * p.depth);
    final shOp = spec.shadowOpacity * p.litShadow;
    final aoOp = spec.aoOpacity * (p.litShadow * 2).clamp(0.0, 1.0);
    final aoReach = spec.aoReachPerDepth * p.depth + 1.5;

    // Everything the shader paints outside the silhouette must fit in the
    // pad. Too small clips the shadow with a hard line; too large is only
    // fill rate.
    final pad = shOp > 0
        ? (mag + blur + aoReach + 2).ceilToDouble()
        : (aoOp > 0 ? (aoReach + 2).ceilToDouble() : 2.0);

    final rect = offset & size;
    final draw = rect.inflate(pad);
    final dpr = configuration.devicePixelRatio ?? 1.0;
    final radius =
        p.circle ? size.shortestSide / 2 : p.radius.clamp(0.0, size.shortestSide / 2);

    // Small parts are filleted, large stock is chamfered - which is also how
    // machining actually works. A chip or a button takes a wider, rounder
    // edge and more dome, so it reads as a pillowed keycap sitting in its
    // pocket; a card or a panel keeps the crisp machined land. Driven by
    // geometry rather than by role because the same role paints both: a
    // raised 34px chip and a raised 300px card are different parts cut from
    // the same stock. Continuous, so an animated resize cannot pop.
    final smallness =
        (1.0 - (size.shortestSide - 30.0) / 40.0).clamp(0.0, 1.0);
    final chamfer = spec.chamferWidth * (1.0 + 0.5 * smallness);
    final chamferProfile = spec.chamferProfile * (1.0 - 0.65 * smallness);
    final bow = spec.bow * (1.0 + 0.8 * smallness);

    // Light TO-vector in the shader's y-UP frame. The palette convention is
    // degrees counter-clockwise from +x with y DOWN naming the source, so 90
    // is above in both frames and the x component carries over unchanged.
    final el = spec.lightElevationDeg * math.pi / 180.0;
    final lx = math.cos(az) * math.cos(el);
    final ly = math.sin(az) * math.cos(el);
    final lz = math.sin(el);

    final s = LitSurfaceProgram.shared;
    var i = 0;
    void f(double v) => s.setFloat(i++, v);
    void c3(Color c) {
      f(c.r);
      f(c.g);
      f(c.b);
    }

    f(draw.width);
    f(draw.height); // uDraw
    f(size.width);
    f(size.height); // uShape
    f(pad);
    f(radius); // uPadRad
    f(chamfer);
    f(1.0 / dpr);
    f(chamferProfile);
    f(spec.landAngle); // uBevel
    c3(p.base); // uAlbedo
    c3(spec.f0); // uF0
    f(spec.roughness);
    f(spec.metalness);
    f(spec.anisotropy);
    f(bow); // uMat
    f(lx);
    f(ly);
    f(lz); // uL
    f(spec.key);
    f(spec.ambient * p.litAmbience);
    f(spec.sheen * p.litAmbience);
    f(p.litRecess); // uKey
    c3(spec.sky); // uSky
    c3(spec.ground); // uGnd
    f(spec.envAmount * p.litAmbience);
    f(spec.horizon);
    f(spec.softbox * p.litAmbience);
    f(spec.rim * p.litAmbience); // uEnv
    f(spec.grainAmp * p.litGrain);
    f(spec.grainAcross);
    f(spec.grainAngleDeg * math.pi / 180.0);
    f(3.0); // uGrain (seed)
    f(-math.cos(az) * mag);
    f(-math.sin(az) * mag); // shadow falls away from the light, y-UP
    f(blur);
    f(shOp); // uShadow
    f(aoOp);
    f(aoReach);
    f(spec.innerBlurPerDepth * p.depth);
    f(spec.innerOpacity); // uOcc
    f(spec.exposure);
    f(spec.white);
    f(spec.dither);
    f(p.litOpacity); // uTone
    assert(i == 53,
        'uniform count drifted: wrote $i, the shader declares 53 floats');

    canvas.save();
    canvas.translate(draw.left, draw.top);
    canvas.drawRect(Offset.zero & draw.size, Paint()..shader = s);
    canvas.restore();

    // Layer 7 stays on the Canvas: a caller-supplied ring is a decoration a
    // call site asked for, not part of the material.
    final b = decoration.border;
    if (b != null) {
      b.paint(
        canvas,
        rect,
        shape: p.circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: p.circle ? null : BorderRadius.circular(p.radius),
        textDirection: configuration.textDirection,
      );
    }
  }
}
