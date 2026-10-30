library;

import 'package:flutter/widgets.dart';

/// What a surface is made of, and how light falls on it.
///
/// This is the data half of the surface engine. `SkeuoDecoration` is the paint
/// half; it reads everything here and invents nothing.
///
/// The split matters because a palette is a *value*: it can be compared,
/// interpolated, and — crucially — handed to a contrast test without a widget
/// tree.

/// One stop in a surface fill, as a delta from the role's ground colour.
///
/// Deltas rather than absolute colours because one fill is applied to four
/// grounds (canvas/surface/well/screen) and must shade each the same way.
/// Expressed in HSL so shading is perceptually even rather than clipping a
/// channel — the app learned this once already, when a flat RGB offset made the
/// dark well's shadow clip to black.
///
/// * [at] — position along the light axis, 0..1, ascending, first 0, last 1.
/// * [dl] — lightness delta. The workhorse.
/// * [dh] — hue rotation, degrees.
/// * [ds] — saturation delta, in points.
typedef FillStop = ({double at, double dh, double ds, double dl});

/// A shadow inside the surface, as a multiple of the surface's depth.
///
/// Depth-relative, not pixel-valued, because `NeuContainer` already pushes
/// `depth / 2` for sunken surfaces and `NeuElevation.d1` for sockets. A
/// pixel-valued recess would sink an LED collar and a text field by the same
/// amount and make the depth scale decorative.
@immutable
class ShadowLayer {
  const ShadowLayer({
    required this.color,
    this.dx = 0,
    this.dy = 1,
    this.blur = 2,
    this.spread = 0,
  });

  final Color color;

  /// All four are multiplied by the surface's depth at paint time.
  final double dx, dy, blur, spread;

  static ShadowLayer lerp(ShadowLayer a, ShadowLayer b, double t) =>
      ShadowLayer(
        color: Color.lerp(a.color, b.color, t)!,
        dx: a.dx + (b.dx - a.dx) * t,
        dy: a.dy + (b.dy - a.dy) * t,
        blur: a.blur + (b.blur - a.blur) * t,
        spread: a.spread + (b.spread - a.spread) * t,
      );

  /// Interpolates two lists, padding the shorter with transparent copies so a
  /// two-layer recess cross-fades to a one-layer recess instead of popping.
  static List<ShadowLayer> lerpList(
      List<ShadowLayer> a, List<ShadowLayer> b, double t) {
    if (a.isEmpty && b.isEmpty) return const <ShadowLayer>[];
    final n = a.length > b.length ? a.length : b.length;
    return [
      for (var i = 0; i < n; i++)
        ShadowLayer.lerp(
          i < a.length ? a[i] : _faded(b[i]),
          i < b.length ? b[i] : _faded(a[i]),
          t,
        ),
    ];
  }

  static ShadowLayer _faded(ShadowLayer s) => ShadowLayer(
        color: s.color.withValues(alpha: 0),
        dx: s.dx,
        dy: s.dy,
        blur: s.blur,
        spread: s.spread,
      );

  @override
  bool operator ==(Object other) =>
      other is ShadowLayer &&
      other.color == color &&
      other.dx == dx &&
      other.dy == dy &&
      other.blur == blur &&
      other.spread == spread;

  @override
  int get hashCode => Object.hash(color, dx, dy, blur, spread);
}

/// Which ground a role fills from.
enum Ground { canvas, surface, well, screen }

/// A surface's job. Selects a ground and scales the layers the palette
/// declared; never introduces a colour or a light direction of its own.
enum SurfaceRole {
  /// The faceplate. Bevelled, lightly shadowed.
  panel,

  /// A physical key: convex, casts a contact shadow.
  raised,

  /// A routed recess.
  sunken,

  /// Inset glass — a display set into a bezel.
  screen,

  /// A deep socket.
  well,

  /// Inert fill. No light model at all.
  flat,
}

/// Which of the painter's layers a role paints, and how strongly.
///
/// Deliberately **not** a second palette. A per-role palette would multiply the
/// authored surface tenfold and turn the `Soft` fidelity assertion into a
/// six-way loop; this table is palette-independent and global.
@immutable
class RoleModifier {
  const RoleModifier({
    required this.fill,
    this.contactScale = 0,
    this.insetScale = 0,
    this.invertBevel = false,
    this.bevel = true,
  });

  final Ground fill;
  final double contactScale, insetScale;
  final bool invertBevel;
  final bool bevel;

  static const Map<SurfaceRole, RoleModifier> table = {
    SurfaceRole.panel:
        RoleModifier(fill: Ground.surface, contactScale: 0.5),
    SurfaceRole.raised:
        RoleModifier(fill: Ground.surface, contactScale: 1.0),
    SurfaceRole.sunken:
        RoleModifier(fill: Ground.well, insetScale: 1.0, invertBevel: true),
    SurfaceRole.screen:
        RoleModifier(fill: Ground.screen, insetScale: 1.0, invertBevel: true),
    SurfaceRole.well:
        RoleModifier(fill: Ground.well, insetScale: 1.6, invertBevel: true),
    SurfaceRole.flat: RoleModifier(fill: Ground.canvas, bevel: false),
  };

  static RoleModifier of(SurfaceRole role) => table[role]!;
}

/// Everything a surface needs to paint itself, for one brightness.
@immutable
class MaterialPalette {
  const MaterialPalette({
    required this.canvas,
    required this.surface,
    required this.well,
    required this.screen,
    required this.text,
    required this.subtext,
    required this.border,
    required this.highlight,
    required this.shadow,
    required this.disabledText,
    required this.lightAzimuthDeg,
    required this.fill,
    required this.bevelLight,
    required this.bevelShade,
    required this.contact,
    this.diagonalCompensation = true,
    this.inset = const <ShadowLayer>[],
    this.bevelWidth = 1.0,
    this.inkOverrides = const <String, Color>{},
  });
  // `fill.length >= 2` cannot be asserted here: a const constructor cannot
  // read `.length` off a list. material_contract_test enforces it, along with
  // stop ordering, which an assert could not check cheaply anyway.

  // --- grounds -------------------------------------------------------------
  final Color canvas, surface, well, screen;

  // --- inks ----------------------------------------------------------------
  final Color text, subtext, border, highlight, shadow, disabledText;

  /// Pins for semantic inks, by accessor name.
  ///
  /// Buys character, never an exemption: an override still faces the
  /// contrast tests. Everything absent is derived, so the palette does not
  /// carry fifty hand-calibrated hexes to keep true forever.
  final Map<String, Color> inkOverrides;

  // --- light ---------------------------------------------------------------

  /// 0 = straight down; 135 = from the upper left.
  ///
  /// Single-valued and applied app-wide: two light directions in one window
  /// read as a mirrored bevel. It is a palette field rather than a widget
  /// parameter precisely so that cannot happen.
  final double lightAzimuthDeg;

  /// Whether to pre-scale diagonal offsets by 0.707.
  ///
  /// `Offset(d, d)` travels 1.414*d, so an uncompensated diagonal shadow reads
  /// a full elevation step too high. False for `Soft`, which is the shipped
  /// look: rescaling it would be a redesign, not a fix.
  final bool diagonalCompensation;

  // --- form ----------------------------------------------------------------
  final List<FillStop> fill;

  // --- bevel ---------------------------------------------------------------
  //
  // A uniform ring: [bevelLight] on proud surfaces, [bevelShade] on recessed
  // ones.
  final Color bevelLight, bevelShade;
  final double bevelWidth;

  // --- depth ---------------------------------------------------------------
  /// The outer stack, depth-relative like [inset].
  ///
  /// The review that shaped this schema argued for `List<BoxShadow>`, so that
  /// `spreadRadius` and the exact `radius * 0.57735 + 0.5` sigma conversion
  /// come free via `toPaint()`. Both do — but a `BoxShadow` is absolute, and
  /// `Soft`'s shadows are `Offset(+-depth, +-depth)` with `blur = 2 * depth`.
  /// Freezing them at one depth would flatten the whole elevation scale, so
  /// these stay relative and the painter builds a `BoxShadow` per paint, which
  /// keeps `toPaint()` anyway.
  final List<ShadowLayer> contact;

  /// The recess stack.
  ///
  /// Cast *outward*, like [contact], with a negative spread so it hugs the
  /// silhouette: Soft's recess was never a true inset, and it reads as a well
  /// against a matching ground.
  final List<ShadowLayer> inset;

  // --- compliance ----------------------------------------------------------

  /// Whether the ink that lands on [role] is dark ink.
  ///
  /// Follows the palette for every role whose ground belongs to the surface
  /// family, and the ground itself for the screen.
  bool inkIsDarkOn(SurfaceRole role) {
    if (RoleModifier.of(role).fill != Ground.screen) return isLight;
    // Ask which pole the screen affords rather than testing luminance against
    // a threshold, which has no correct value for a mid-tone.
    return _contrast(const Color(0xFF000000), screen) >
        _contrast(const Color(0xFFFFFFFF), screen);
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// The darkest (or lightest) pixel a glyph can land on for [role]: the
  /// worst *stop* of that role's fill.
  ///
  /// Darkest in a light palette, lightest in a dark one — the asymmetry that
  /// makes a fill hurt dark ink and help light ink, and the reason the light
  /// theme has so much less gradient headroom than the dark one.
  ///
  /// The bevel is deliberately NOT included. It is a ring one logical pixel
  /// wide at the very edge of the box, and every surface in the app carries
  /// at least four pixels of padding, so it is not a ground a glyph ever sits
  /// on.
  Color worstGround(SurfaceRole role) {
    final base = groundFor(RoleModifier.of(role).fill);
    final stops = <Color>[base, for (final s in fill) shadeStop(base, s)];
    stops.sort((a, b) => a.computeLuminance().compareTo(b.computeLuminance()));

    // Which extreme hurts depends on the polarity of the ink that lands here,
    // which for the screen is decided by the screen rather than by the
    // palette (see [inkIsDarkOn]).
    return inkIsDarkOn(role) ? stops.first : stops.last;
  }

  /// True when this palette's own surface is light.
  bool get isLight => surface.computeLuminance() > 0.5;

  /// The ground an ink must survive anywhere it can land, excluding [screen].
  ///
  /// Screen ink is derived separately, against the screen alone
  /// (`NeuTheme.inkOnScreen`).
  Color get inkGround {
    // EVERY non-screen role, not a hand-picked three. `flat` fills from the
    // canvas and `well` from the well, and a derivation that skipped them
    // would aim at the wrong worst case.
    final candidates = <Color>[
      for (final role in SurfaceRole.values)
        if (RoleModifier.of(role).fill != Ground.screen) worstGround(role),
    ];
    candidates.sort((a, b) => a.computeLuminance().compareTo(b.computeLuminance()));
    return isLight ? candidates.first : candidates.last;
  }

  Color groundFor(Ground g) => switch (g) {
        Ground.canvas => canvas,
        Ground.surface => surface,
        Ground.well => well,
        Ground.screen => screen,
      };

  /// Applies a stop's HSL deltas to a base colour.
  ///
  /// Saturates toward [bevelLight]/[bevelShade] at the ends rather than
  /// clamping lightness. Clamping is what makes a stop silently resolve to pure
  /// white: at L = 1.0 `HSLColor.toColor` yields chroma 0, so on a light
  /// surface any stop above about +0.07 collapses to #FFFFFF — which violates
  /// "never pure white or black" and is invisible to a contrast check, because
  /// white improves every light ink.
  Color shadeStop(Color base, FillStop stop) {
    final hsl = HSLColor.fromColor(base);
    final target = hsl.lightness + stop.dl;
    if (target > 0.98) {
      return Color.lerp(base, bevelLight, ((target - 0.98) / 0.02).clamp(0, 1))!;
    }
    if (target < 0.02) {
      return Color.lerp(base, bevelShade, ((0.02 - target) / 0.02).clamp(0, 1))!;
    }
    return hsl
        .withLightness(target)
        .withSaturation((hsl.saturation + stop.ds).clamp(0.0, 1.0))
        .withHue((hsl.hue + stop.dh) % 360)
        .toColor();
  }

  @override
  bool operator ==(Object other) =>
      other is MaterialPalette &&
      other.canvas == canvas &&
      other.surface == surface &&
      other.well == well &&
      other.screen == screen &&
      other.text == text &&
      other.subtext == subtext &&
      other.border == border &&
      other.highlight == highlight &&
      other.shadow == shadow &&
      other.disabledText == disabledText &&
      other.lightAzimuthDeg == lightAzimuthDeg &&
      other.diagonalCompensation == diagonalCompensation &&
      _sameFill(other.fill, fill) &&
      other.bevelLight == bevelLight &&
      other.bevelShade == bevelShade &&
      other.bevelWidth == bevelWidth &&
      _sameList<ShadowLayer>(other.contact, contact) &&
      _sameList<ShadowLayer>(other.inset, inset);

  @override
  int get hashCode => Object.hashAll([
        canvas, surface, well, screen,
        text, subtext, border, highlight, shadow, disabledText,
        lightAzimuthDeg, diagonalCompensation,
        Object.hashAll(fill.map((s) => Object.hash(s.at, s.dh, s.ds, s.dl))),
        bevelLight, bevelShade, bevelWidth,
        Object.hashAll(contact), Object.hashAll(inset),
      ]);

  static bool _sameFill(List<FillStop> a, List<FillStop> b) {
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

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
