library;

import 'package:flutter/widgets.dart';

/// What a surface is made of, and how light falls on it.
///
/// This is the data half of the material engine. `SkeuoDecoration` is the paint
/// half; it reads everything here and invents nothing.
///
/// The split matters because a palette is a *value*: it can be compared,
/// interpolated, and — crucially — handed to a contrast test without a widget
/// tree. A design that resolved grounds from a global singleton would make the
/// five-material contrast matrix impossible to write, and the Settings preview
/// tiles impossible to render.
///
/// Every field below earns its place by naming a failure it prevents. Fields
/// were not added speculatively: a field missing here is an engine change
/// later, and an engine change in v1.8.0 means this abstraction was wrong.

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
/// * [dh] — hue rotation, degrees. Champagne swings ~10 degrees, warm at the
///   sheen and cool in the shade; without it, champagne renders as beige paint.
/// * [ds] — saturation delta, in points. Bakelite's shadow *gains* saturation;
///   a lightness-only ramp is the single clearest tell of fake plastic.
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

/// How a tile is generated. Each is a procedure, not an asset.
///
/// Procedural because the window fully invalidates on every resize
/// (`CS_HREDRAW | CS_VREDRAW`, `windows/runner/win32_window.cpp:94`) and
/// per-monitor DPI is live. A regenerated tile is always crisp at the current
/// scale; a bundled PNG is resampled.
enum TextureKind {
  /// Fine unidirectional streaks. Brushed and anodised aluminium.
  brushed,

  /// Layered bands with slow cross-grain variation. Wood.
  grain,

  /// Crosshatch. Linen, felt, book cloth.
  weave,

  /// Irregular cells with burnished edges. Leather.
  cell,

  /// A regular dot lattice. Speaker grille, perforated metal.
  mesh,

  /// Isotropic value noise. Moulded plastic, bakelite, paper. Also the dither.
  speckle,
}

/// How a tile composites.
///
/// [bakedOpaque] is the default and the rule: the delta is baked into an opaque
/// tile in the surface's own colour and drawn `srcOver` at alpha 1.
///
/// The alternative — a translucent white tile in [BlendMode.overlay] — is
/// rejected for two reasons. Overlay's effect is about 2.4x stronger against a
/// dark base than a light one, so an alpha tuned in light mode is invisible in
/// dark and every texture needs retuning per brightness. And a baked tile makes
/// the worst texel an *integer* the contrast matrix can assert, rather than a
/// composite it must simulate.
///
/// [blended] survives for the one case baking cannot serve: texture over
/// content whose base colour is unknown, i.e. video artwork.
enum TileComposite { bakedOpaque, blended }

/// Texture amplitude, in **sRGB levels**, per role.
///
/// Levels rather than alpha because alpha is theme-dependent and levels are
/// not: an amplitude tuned as alpha in one brightness is wrong in the other.
/// The value is not a free parameter — it is the largest the worst-texel
/// contrast assertion permits given the palette's *shipped inks*. Three levels
/// is the default where inks are unchanged; four is legal only where a palette
/// has moved an ink to buy the headroom.
typedef AmplitudeLevels = Map<SurfaceRole, int>;

@immutable
class TextureSpec {
  const TextureSpec({
    required this.kind,
    required this.amplitude,
    this.composite = TileComposite.bakedOpaque,
    this.grainAngleDeg = 0,
    this.tileDevicePx = const Size(256, 256),
    this.secondTileScale = 0.75,
    this.secondTileAngleDeg = 29,
    this.dropBelowPx = 40,
    this.domainWarp = 0,
    this.domainWarpPeriodPx = 48,
    this.seed = 0x5EED,
  })  : assert(dropBelowPx >= 0),
        assert(domainWarp >= 0 && domainWarp <= 0.05);

  final TextureKind kind;

  /// Per-role amplitude in sRGB levels. Absent roles paint no texture.
  final AmplitudeLevels amplitude;

  final TileComposite composite;

  /// Anisotropy axis in degrees. 0 for brushed metal's horizontal streaks.
  ///
  /// Its own field rather than a reuse of the light azimuth, which is the only
  /// other angle in the palette and would otherwise be reached for — putting
  /// the brush on the diagonal. Palette-level, never per-surface: one material
  /// world is cut from one piece of stock, and a per-surface grain axis is the
  /// same defect as a mirrored bevel.
  final double grainAngleDeg;

  /// Non-square for anisotropic materials — 512x128 for a brush, 256 square for
  /// isotropic noise. A square tile cannot carry a long streak without the
  /// repeat becoming obvious.
  final Size tileDevicePx;

  /// A second copy of the tile, scaled and rotated, kills the repeat lattice.
  /// Without it the tile boundary becomes a visible landmark grid.
  final double secondTileScale, secondTileAngleDeg;

  /// Below this box size the structure aliases and reads as JPEG damage, so it
  /// is dropped and only the micro-grain remains. 18px chips are the case.
  final double dropBelowPx;

  /// Warps the sampling coordinate. Turns grain into *wobble* — the difference
  /// between a reflection in imperfect glass and dirt on it.
  final double domainWarp, domainWarpPeriodPx;

  final int seed;

  int amplitudeFor(SurfaceRole role) => amplitude[role] ?? 0;

  @override
  bool operator ==(Object other) =>
      other is TextureSpec &&
      other.kind == kind &&
      other.composite == composite &&
      other.grainAngleDeg == grainAngleDeg &&
      other.tileDevicePx == tileDevicePx &&
      other.secondTileScale == secondTileScale &&
      other.secondTileAngleDeg == secondTileAngleDeg &&
      other.dropBelowPx == dropBelowPx &&
      other.domainWarp == domainWarp &&
      other.domainWarpPeriodPx == domainWarpPeriodPx &&
      other.seed == seed &&
      _sameAmplitude(other.amplitude, amplitude);

  @override
  int get hashCode => Object.hash(
        kind,
        composite,
        grainAngleDeg,
        tileDevicePx,
        secondTileScale,
        secondTileAngleDeg,
        dropBelowPx,
        domainWarp,
        domainWarpPeriodPx,
        seed,
        Object.hashAll(
            SurfaceRole.values.map((r) => amplitude[r] ?? 0)),
      );

  static bool _sameAmplitude(AmplitudeLevels a, AmplitudeLevels b) {
    for (final r in SurfaceRole.values) {
      if ((a[r] ?? 0) != (b[r] ?? 0)) return false;
    }
    return true;
  }
}

/// Which ground a role fills from.
enum Ground { canvas, surface, well, screen }

/// A surface's job. Selects a ground and scales the layers the material
/// declared; never introduces a colour or a light direction of its own.
enum SurfaceRole {
  /// The faceplate. Textured, bevelled, lightly shadowed.
  panel,

  /// A physical key: convex, glossed, casts a contact shadow.
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

/// Which of the seven layers a role paints, and how strongly.
///
/// Deliberately **not** a second palette. A per-role palette would multiply the
/// authored surface tenfold and turn the `Soft` fidelity assertion into a
/// six-way loop; this table is material-independent and global.
@immutable
class RoleModifier {
  const RoleModifier({
    required this.fill,
    this.glossScale = 0,
    this.textureScale = 0,
    this.contactScale = 0,
    this.insetScale = 0,
    this.invertBevel = false,
    this.bevel = true,
  });

  final Ground fill;
  final double glossScale, textureScale, contactScale, insetScale;
  final bool invertBevel;
  final bool bevel;

  static const Map<SurfaceRole, RoleModifier> table = {
    SurfaceRole.panel: RoleModifier(
        fill: Ground.surface, textureScale: 1.0, contactScale: 0.5),
    SurfaceRole.raised: RoleModifier(
        fill: Ground.surface, glossScale: 1.0, contactScale: 1.0),
    SurfaceRole.sunken:
        RoleModifier(fill: Ground.well, insetScale: 1.0, invertBevel: true),
    // The screen's reflective sweep lives in the fill as extra stops, not in
    // the gloss layer: gloss is panel-level and a screen is per-card.
    SurfaceRole.screen:
        RoleModifier(fill: Ground.screen, insetScale: 1.0, invertBevel: true),
    SurfaceRole.well:
        RoleModifier(fill: Ground.well, insetScale: 1.6, invertBevel: true),
    SurfaceRole.flat: RoleModifier(fill: Ground.canvas, bevel: false),
  };

  static RoleModifier of(SurfaceRole role) => table[role]!;
}

/// How a dark palette carries depth.
///
/// Arithmetic, not taste: black at alpha 0.50 over `#1D212A` reaches 1.23:1.
/// There is no headroom below a dark surface, so a dark theme must put the
/// depth cue on the *light* side or read mushy. Two mechanisms are legal;
/// which one is a material choice.
enum DarkDepth {
  /// White composited into the base before the gradient, keyed by elevation.
  elevationOverlay,

  /// A highlight shadow on the light side at alpha >= 0.40.
  lightSideCast,
}

/// How a recessed surface gets its shadow.
///
/// [trueInset] draws inside the shape. [outerFake] draws the same layers as
/// *outer* shadows with a negative spread so they hug the silhouette — which
/// is not a recess at all, but reads as one against a matching ground.
///
/// The fake is banned in every new material and preserved in exactly one:
/// `Soft`, where it is the shipped look. It leaks a halo outside the well and
/// breaks the moment the well sits on a differently-coloured parent — which it
/// does, in every dialog. Naming it in the schema rather than special-casing it
/// in the painter is what keeps that a stated compromise instead of a bug.
enum RecessStyle { trueInset, outerFake }

/// How a material satisfies WCAG 1.4.11 for control boundaries.
enum BoundaryStrategy {
  /// The border itself clears 3:1 against every ground it can sit on.
  explicitBorder,

  /// The border may be sub-3:1, and the burden is carried by the focus ring
  /// plus a mandatory widget test proving every interactive surface renders a
  /// >=4.5:1 label or a >=3:1 icon.
  ///
  /// Conforming under the Understanding text — *"a visual boundary indicating
  /// the hit area is only required when there is no other visual way to
  /// identify the presence of the control"* — but only once that test exists.
  /// Without it this is an apology, not a strategy.
  focusRingOnly,
}

/// Ornament: what a material's furniture is made of.
///
/// A data record, not a painter layer. Screws, seams, engraved plates and rims
/// are drawn by the widget that owns the surface, because a `BoxPainter`
/// receives no `BuildContext` and its `ImageConfiguration.size` is the
/// decorated box's size rather than the window's — so a painter cannot know it
/// sits in a 400px window, and must not be the thing deciding whether ornament
/// fits.
@immutable
class Furniture {
  const Furniture({
    this.screws = false,
    this.seams = false,
    this.plates = false,
    this.bezels = false,
    this.rim = RimStyle.none,
  });

  const Furniture.none()
      : screws = false,
        seams = false,
        plates = false,
        bezels = false,
        rim = RimStyle.none;

  final bool screws, seams, plates;

  /// Whether a recessed display gets a rim around it.
  ///
  /// Its own flag rather than a consequence of the `screen` role, because a
  /// bezel is drawn *over* the picture it surrounds and Soft has no business
  /// putting a ring around a video thumbnail that has never had one. A
  /// material that declares no bezel gets a null decoration and the call site
  /// paints nothing at all.
  final bool bezels;

  final RimStyle rim;

  bool get isNone =>
      !screws && !seams && !plates && !bezels && rim == RimStyle.none;

  @override
  bool operator ==(Object other) =>
      other is Furniture &&
      other.screws == screws &&
      other.seams == seams &&
      other.plates == plates &&
      other.bezels == bezels &&
      other.rim == rim;

  @override
  int get hashCode => Object.hash(screws, seams, plates, bezels, rim);
}

enum RimStyle { none, chrome, brass, moulded }

/// Backdrop refraction, for the one material that needs it.
///
/// Separate from the palette because blur is a *layer* operation no
/// `Decoration` can reach: `BoxPainter.paint` receives a canvas, and the only
/// backdrop API is `SceneBuilder.pushBackdropFilter`. Painted glass is a
/// decoration like any other; blurred glass is a widget.
@immutable
class GlassSpec {
  const GlassSpec({
    required this.sigma,
    required this.tint,
    this.scale = 1.05,
    this.rimWidthFactor = 0.55,
    this.opaqueTintFloor = 0.84,
  })  : assert(scale >= 1.0 && scale <= 1.25,
            'above 1.25 the refraction reads as a fisheye bug'),
        assert(opaqueTintFloor >= 0.80,
            'below this the surface has no computable contrast ratio');

  final double sigma;
  final Color tint;

  /// Backdrop magnification. Sells thickness; overdone it looks like a defect.
  final double scale;

  /// Rim width as a fraction of the corner radius, clamped 6..18px at use.
  final double rimWidthFactor;

  /// Minimum opacity of the tint. Non-negotiable: below it the surface has no
  /// fixed ground, which deletes the contrast matrix's premise rather than
  /// extending it. This is the line iOS 7 vibrancy crossed.
  final double opaqueTintFloor;

  @override
  bool operator ==(Object other) =>
      other is GlassSpec &&
      other.sigma == sigma &&
      other.tint == tint &&
      other.scale == scale &&
      other.rimWidthFactor == rimWidthFactor &&
      other.opaqueTintFloor == opaqueTintFloor;

  @override
  int get hashCode =>
      Object.hash(sigma, tint, scale, rimWidthFactor, opaqueTintFloor);
}

/// Everything a surface needs to paint itself, for one brightness of one
/// material.
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
    this.screenIsEmissive = false,
    Color? screenText,
    Color? screenSubtext,
    this.diagonalCompensation = true,
    this.inset = const <ShadowLayer>[],
    this.bevelWidth = 1.0,
    this.bevelSweepExponent = 2.0,
    this.bevelAmbientFloor = 0.15,
    this.bevelUniform = false,
    this.gloss = 0,
    this.glossBreak = 0.32,
    this.glossHardTerminator = false,
    this.glossColour = const Color(0xFFFFFFFF),
    this.texture,
    this.darkDepth = DarkDepth.lightSideCast,
    this.recessStyle = RecessStyle.trueInset,
    this.elevationOverlay = const <int, double>{},
    this.adaptiveAlphaMultiplier = 1.0,
    this.boundaryStrategy = BoundaryStrategy.explicitBorder,
    this.inkOverrides = const <String, Color>{},
  })  : _screenText = screenText,
        _screenSubtext = screenSubtext,
        // `fill.length >= 2` cannot be asserted here: a const constructor
        // cannot read `.length` off a list. material_contract_test enforces
        // it, along with stop ordering, which an assert could not check
        // cheaply anyway.
        assert(gloss >= 0 && gloss <= 1),
        assert(bevelAmbientFloor >= 0 && bevelAmbientFloor <= 1);

  // --- grounds -------------------------------------------------------------
  final Color canvas, surface, well, screen;

  final Color? _screenText, _screenSubtext;

  /// The ink a [SurfaceRole.screen] carries.
  ///
  /// Defaults to the palette's own text, which is right for a reflective
  /// readout — a printed card takes the room's ink. An **emissive** readout
  /// does not: a light material's own `text` measured 1.08:1 on Rack's screen,
  /// because both are dark. Emissive palettes pass the dark pair explicitly.
  Color get screenText => _screenText ?? text;
  Color get screenSubtext => _screenSubtext ?? subtext;

  /// An emissive screen keeps its dark treatment in **both** brightnesses.
  ///
  /// A CRT does not change colour with the room; a printed card does. Without
  /// this field a light theme either loses its readout or ships an unvalidated
  /// ink pair on a light one.
  final bool screenIsEmissive;

  // --- inks ----------------------------------------------------------------
  //
  // `subtext` in particular MUST be a palette field rather than a global token:
  // two materials move it specifically to buy texture headroom, and shrinking
  // the texture instead is the wrong trade.
  final Color text, subtext, border, highlight, shadow, disabledText;

  /// Per-material pins for semantic inks, by accessor name.
  ///
  /// Buys character — a rack wants a real panel amber — never an exemption: an
  /// override still faces the contrast matrix. Everything absent is derived, so
  /// a material does not carry fifty hand-calibrated hexes to keep true forever.
  final Map<String, Color> inkOverrides;

  // --- light ---------------------------------------------------------------

  /// 0 = straight down; 135 = from the upper left.
  ///
  /// Single-valued and applied app-wide. Both conventions are defensible — a
  /// horizontal brush grain needs a horizontal sheen band, while vertical
  /// matches what every Material widget does for free — but two light
  /// directions in one window never are. It is a palette field rather than a
  /// widget parameter precisely so that cannot happen.
  final double lightAzimuthDeg;

  /// Whether to pre-scale diagonal offsets by 0.707.
  ///
  /// `Offset(d, d)` travels 1.414*d, so an uncompensated diagonal shadow reads
  /// a full elevation step too high. True everywhere except `Soft`, which is
  /// the shipped look: rescaling it would be a redesign, not a fix.
  final bool diagonalCompensation;

  // --- form ----------------------------------------------------------------
  final List<FillStop> fill;

  // --- bevel ---------------------------------------------------------------
  final Color bevelLight, bevelShade;
  final double bevelWidth;

  /// Exponent p in `alpha(theta) = alpha * (floor + (1-floor) * max(0, cos(theta - thetaL))^p)`.
  ///
  /// A bevel is an envelope around the edge, not a uniform stroke. Real Fresnel
  /// reflectance is nearly flat to about 60 degrees and then climbs steeply, so
  /// a constant-alpha ring reads as a CSS border rather than a curved edge
  /// catching a light.
  final double bevelSweepExponent;

  /// The floor of that envelope, so the unlit side of the bevel is dim rather
  /// than absent.
  final double bevelAmbientFloor;

  /// True only for `Soft`, whose ring genuinely is uniform.
  final bool bevelUniform;

  // --- specular ------------------------------------------------------------
  final double gloss;

  /// Terminator position as a fraction of height. 0.26-0.38 is the useful band.
  final double glossBreak;

  /// A hard terminator reads as glass or gel; a soft one as matte plastic.
  final bool glossHardTerminator;

  /// Required rather than assumed white: without it, half a surface's
  /// composited ground is not computable from the palette, and the contrast
  /// matrix measures the composited ground.
  final Color glossColour;

  // --- texture -------------------------------------------------------------
  final TextureSpec? texture;

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
  final List<ShadowLayer> inset;
  final DarkDepth darkDepth;
  final RecessStyle recessStyle;

  /// White composited into the base *before* the gradient, by depth.
  ///
  /// The dark theme's depth cue cannot be a darker shadow: black at alpha 0.50
  /// over a `#1D212A` canvas reaches 1.23:1, and there is no headroom below
  /// that. So a dark material lifts the surface instead. Only consulted when
  /// [darkDepth] is [DarkDepth.elevationOverlay].
  final Map<int, double> elevationOverlay;

  /// The overlay alpha for a depth, interpolated between declared steps.
  double overlayFor(double depth) {
    if (elevationOverlay.isEmpty) return 0;
    final keys = elevationOverlay.keys.toList()..sort();
    if (depth <= keys.first) return elevationOverlay[keys.first]!;
    if (depth >= keys.last) return elevationOverlay[keys.last]!;
    for (var i = 1; i < keys.length; i++) {
      if (depth <= keys[i]) {
        final t = (depth - keys[i - 1]) / (keys[i] - keys[i - 1]);
        final a = elevationOverlay[keys[i - 1]]!, b = elevationOverlay[keys[i]]!;
        return a + (b - a) * t;
      }
    }
    return elevationOverlay[keys.last]!;
  }

  /// Multiplier applied to shadow alpha where a surface sits over text or
  /// artwork rather than over a flat ground. 1.55-2.0 in practice.
  ///
  /// This is the one genuinely new idea in modern "glass" design, and it costs
  /// a single lerp rather than a shader, because we own the layer stack and
  /// therefore already know what is behind.
  final double adaptiveAlphaMultiplier;

  // --- compliance ----------------------------------------------------------
  final BoundaryStrategy boundaryStrategy;

  /// The ground an ink must survive for a given role: the worst *stop* of that
  /// role's fill, before texture and gloss are composited.
  ///
  /// Darkest in a light palette, lightest in a dark one — the asymmetry that
  /// makes a fill hurt dark ink and help light ink, and the reason the light
  /// theme has so much less gradient headroom than the dark one.
  ///
  /// The full ground including texture and gloss is *measured*, not derived;
  /// this is the analytic floor that measurement must not fall below.
  /// Whether the ink that lands on [role] is dark ink.
  ///
  /// Follows the palette for every role whose ground belongs to the surface
  /// family, and the ground itself for the screen — which is the one surface
  /// in the app whose brightness is independent of the theme's.
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

  Color worstGround(SurfaceRole role) {
    final base = groundFor(RoleModifier.of(role).fill);
    final stops = <Color>[base, for (final s in fill) shadeStop(base, s)];
    stops.sort((a, b) => a.computeLuminance().compareTo(b.computeLuminance()));

    // Which extreme hurts depends on the polarity of the ink that lands here,
    // and for one role that is not the palette's polarity.
    //
    // Everywhere else it is: a light palette carries dark ink, and a darker
    // stop is what closes the gap. The screen breaks the rule because an
    // emissive screen stays dark inside a light material, so the ink on it is
    // light and the *lightest* stop is its worst case. Choosing by palette
    // brightness here returned the darkest stop - the friendliest ground on
    // the surface - and the matrix passed on the worst stop while failing on
    // the flat token, which is the tell that the extremes were swapped.
    final inkIsDark = inkIsDarkOn(role);
    final worst = inkIsDark ? stops.first : stops.last;

    // The grain, in closed form. It only ever lightens - it composites with
    // BlendMode.plus and its tile carries the positive deviation only - so
    // where the ink is light the worst texel is the lightest stop plus the
    // amplitude, and where the ink is dark the grain moves the ground AWAY
    // from its worst case and is simply ignored.
    //
    // Being able to write this as arithmetic rather than by rasterising and
    // sampling is the whole reason the texture is lighten-only.
    if (inkIsDark) return worst;
    final amp = texture?.amplitudeFor(role) ?? 0;
    if (amp == 0) return worst;
    return Color.from(
      alpha: 1,
      red: ((worst.r * 255 + amp) / 255).clamp(0.0, 1.0),
      green: ((worst.g * 255 + amp) / 255).clamp(0.0, 1.0),
      blue: ((worst.b * 255 + amp) / 255).clamp(0.0, 1.0),
    );
  }

  /// True when this palette's own surface is light. Not a theme flag — an
  /// emissive screen is dark inside a light palette.
  bool get isLight => surface.computeLuminance() > 0.5;

  /// The ground an ink must survive anywhere it can land, excluding [screen].
  ///
  /// `screen` is excluded and this is arithmetic, not taste: it is dark in both
  /// brightnesses, so requiring one ink to clear 4.5:1 against both a champagne
  /// canvas and a near-black screen is an empty set — the best any single
  /// colour reaches across that pair is about 3.73:1. Screen ink is derived
  /// separately.
  Color get inkGround {
    // EVERY non-screen role, not a hand-picked three. `flat` fills from the
    // canvas and `well` from the well, and a derivation that skipped them
    // aimed at the wrong worst case - which is exactly how Rack's derived
    // liveText landed at 4.14:1 against a ground this getter never looked at.
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
      other.screenIsEmissive == screenIsEmissive &&
      other.screenText == screenText &&
      other.screenSubtext == screenSubtext &&
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
      other.bevelSweepExponent == bevelSweepExponent &&
      other.bevelAmbientFloor == bevelAmbientFloor &&
      other.bevelUniform == bevelUniform &&
      other.gloss == gloss &&
      other.glossBreak == glossBreak &&
      other.glossHardTerminator == glossHardTerminator &&
      other.glossColour == glossColour &&
      other.texture == texture &&
      other.darkDepth == darkDepth &&
      other.recessStyle == recessStyle &&
      _sameOverlay(other.elevationOverlay, elevationOverlay) &&
      other.adaptiveAlphaMultiplier == adaptiveAlphaMultiplier &&
      other.boundaryStrategy == boundaryStrategy &&
      _sameList<ShadowLayer>(other.contact, contact) &&
      _sameList<ShadowLayer>(other.inset, inset);

  @override
  int get hashCode => Object.hashAll([
        canvas, surface, well, screen, screenIsEmissive,
        screenText, screenSubtext,
        text, subtext, border, highlight, shadow, disabledText,
        lightAzimuthDeg, diagonalCompensation,
        Object.hashAll(fill.map((s) => Object.hash(s.at, s.dh, s.ds, s.dl))),
        bevelLight, bevelShade, bevelWidth,
        bevelSweepExponent, bevelAmbientFloor, bevelUniform,
        gloss, glossBreak, glossHardTerminator, glossColour,
        texture, darkDepth, recessStyle, adaptiveAlphaMultiplier,
        boundaryStrategy,
        Object.hashAll(contact), Object.hashAll(inset),
      ]);

  static bool _sameOverlay(Map<int, double> a, Map<int, double> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

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
