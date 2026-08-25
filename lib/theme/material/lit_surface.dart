import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The lit-surface fragment program, loaded once for the whole app.
///
/// One [ui.FragmentShader] instance is shared by every painter: uniforms are
/// snapshotted per draw call (verified against the pinned SDK), and a shared
/// instance records five times faster than allocating one per surface —
/// 1.10 µs versus 5.46 µs, which at a 200-card VOD grid is the difference
/// between 220 µs and over a millisecond per frame.
abstract final class LitSurfaceProgram {
  static ui.FragmentProgram? _program;
  static ui.FragmentShader? _shared;

  static bool get ready => _shared != null;

  /// The one shader instance. Only valid while [ready].
  static ui.FragmentShader get shared => _shared!;

  /// Called once from `main()`, awaited before `runApp`.
  ///
  /// A shipped build CAN fail here: the SDK's shader compiler retries without
  /// `--sksl` on an SkSL rejection and downgrades the failure to a build
  /// WARNING, so a Skia-incompatible shader ships green and throws at load.
  /// Degrade to the Canvas engine rather than to a blank window — every
  /// surface keeps painting through the seven-layer path exactly as it did
  /// before the shader existed.
  static Future<void> load() async {
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/surface.frag');
      _shared = _program!.fragmentShader();
    } catch (e, st) {
      _program = null;
      _shared = null;
      debugPrint('lit surface unavailable, falling back to Canvas: $e\n$st');
    }
  }

  /// Simulates a load failure, so tests can assert the fallback routing.
  @visibleForTesting
  static void reset() {
    _shared?.dispose();
    _shared = null;
    _program = null;
  }
}

/// One material's physical description, for the lit-surface shader.
///
/// This is the palette-level half of the lit model: what the material is
/// *made of* and what room it stands in. The role-level half — which ground it
/// fills with, whether it is recessed, how strongly it casts — lives on
/// `SurfaceParams` as plain scalars, resolved by the role factory, because two
/// call sites animate across roles and a spec cannot be tweened per-role.
///
/// Everything here is a number the shader consumes directly. There is no
/// indirection on purpose: tuning a material is editing this record, running
/// `render_surface_preview.dart`, and looking.
@immutable
class LitSpec {
  const LitSpec({
    required this.f0,
    this.roughness = 0.34,
    this.metalness = 0.0,
    this.anisotropy = 0.0,
    this.bow = 0.26,
    this.chamferWidth = 3.5,
    this.chamferProfile = 1.0,
    this.landAngle = 0.5,
    this.lightElevationDeg = 37.0,
    this.key = 1.0,
    this.ambient = 0.55,
    this.sheen = 0.20,
    required this.sky,
    required this.ground,
    this.envAmount = 0.75,
    this.horizon = 0.22,
    this.softbox = 0.40,
    this.rim = 0.55,
    this.grainAmp = 0.0,
    this.grainAcross = 3.0,
    this.grainAngleDeg = 0.0,
    this.shadowDyPerDepth = 1.1,
    this.shadowBlurPerDepth = 2.2,
    this.shadowOpacity = 0.55,
    this.aoOpacity = 0.40,
    this.aoReachPerDepth = 0.8,
    this.innerBlurPerDepth = 2.2,
    this.innerOpacity = 0.75,
    this.exposure = 1.0,
    this.white = 2.2,
    this.dither = 1.0,
    this.faceLiftLevels = 24,
    this.faceDropLevels = 24,
    double? recessLiftLevels,
    double? recessDropLevels,
  })  : recessLiftLevels = recessLiftLevels ?? faceLiftLevels,
        recessDropLevels = recessDropLevels ?? faceDropLevels;

  /// Specular reflectance at normal incidence, as an sRGB colour.
  ///
  /// This is what separates gold from grey plastic: a metal's reflection
  /// carries the metal's own colour, a dielectric's stays neutral at ~4%.
  /// Only meaningful when [metalness] lifts it in; dielectrics ignore it.
  final Color f0;

  final double roughness, metalness, anisotropy;

  /// A shallow bow across the face, as a normal tilt at the rim.
  ///
  /// Rolled sheet is never dead flat. Without this the interior normal is
  /// constant, a constant normal dotted with a fixed light is a constant, and
  /// the face is one flat colour — which is exactly what the gradient engine
  /// produced and exactly what read as fake.
  final double bow;

  /// Chamfer band width in logical pixels, before element scaling.
  final double chamferWidth;

  /// 0 = bullnose fillet (moulded), 1 = flat machined land with two arrises.
  final double chamferProfile;

  /// Land angle as a fraction of 90°, for the machined profile.
  final double landAngle;

  /// Light elevation above the surface plane, degrees. The azimuth is the
  /// palette's `lightAzimuthDeg` — one light per app, held on the palette so
  /// no call site can disagree with another.
  final double lightElevationDeg;

  final double key, ambient, sheen;

  /// The room: environment above and below the horizon. The chamfer reflects
  /// these, and the sharp step between them sweeping across a curved edge is
  /// what the eye reads as "shiny".
  final Color sky, ground;

  final double envAmount, horizon, softbox, rim;

  /// Brush grain as a normal tilt (NOT a luminance delta — the specular
  /// amplifies it, so the grain sparkles in the highlight and vanishes in
  /// shadow, which is what real brushed metal does).
  final double grainAmp;

  /// Across-grain wavelength in logical pixels. Must stay above ~2.5 at
  /// DPR 1 or the shader's Nyquist guard correctly erases it.
  final double grainAcross;

  final double grainAngleDeg;

  /// Depth-relative shadow model, authored against the same convention as
  /// `ShadowLayer`: multiplied by the surface's elevation depth at paint time.
  final double shadowDyPerDepth, shadowBlurPerDepth, shadowOpacity;
  final double aoOpacity, aoReachPerDepth, innerBlurPerDepth, innerOpacity;

  final double exposure, white, dither;

  /// Declared bounds on how far the LIGHTING can move the face away from its
  /// albedo, in sRGB levels, worst case over every text-bearing role.
  ///
  /// The shader replaces the fill stops, so the closed-form contrast model
  /// cannot derive the painted extremes from the palette any more - and the
  /// shading equation is not invertible in any useful way. These two numbers
  /// are the bridge: `worstGround` trusts them, and `lit_ground_test`
  /// rasterises every lit role through the real painter and fails if the
  /// declaration understates what actually paints. Tuning a material brighter
  /// means raising these, which means the ink derivation compensates - the
  /// same discipline the grain amplitude already lives under.
  final double faceLiftLevels, faceDropLevels;

  /// The recessed roles' own bounds, defaulting to the proud ones.
  ///
  /// Split because the two worst cases do not co-occur: a recess's lit far
  /// wall reaches ~2x the lift of a proud face's sheen, but it does so on
  /// the WELL ground, which is darker and has contrast to spare. One shared
  /// bound taxed every proud-face ink for a recess-only extreme, and pushed
  /// subtext within a few levels of text - flattening the type hierarchy to
  /// pay for a pixel no proud face ever paints.
  final double recessLiftLevels, recessDropLevels;

  static LitSpec? lerp(LitSpec? a, LitSpec? b, double t) {
    if (a == null && b == null) return null;
    // One side has no lit model at all. There is no meaningful halfway
    // between "an object" and "a picture", so this snaps — the same
    // documented behaviour as `Decoration.lerp`'s own fallback. In practice
    // the only cross is the material picker, which rebuilds rather than
    // tweens.
    if (a == null || b == null) return t < 0.5 ? a : b;
    double d(double x, double y) => x + (y - x) * t;
    return LitSpec(
      f0: Color.lerp(a.f0, b.f0, t)!,
      roughness: d(a.roughness, b.roughness),
      metalness: d(a.metalness, b.metalness),
      anisotropy: d(a.anisotropy, b.anisotropy),
      bow: d(a.bow, b.bow),
      chamferWidth: d(a.chamferWidth, b.chamferWidth),
      chamferProfile: d(a.chamferProfile, b.chamferProfile),
      landAngle: d(a.landAngle, b.landAngle),
      lightElevationDeg: d(a.lightElevationDeg, b.lightElevationDeg),
      key: d(a.key, b.key),
      ambient: d(a.ambient, b.ambient),
      sheen: d(a.sheen, b.sheen),
      sky: Color.lerp(a.sky, b.sky, t)!,
      ground: Color.lerp(a.ground, b.ground, t)!,
      envAmount: d(a.envAmount, b.envAmount),
      horizon: d(a.horizon, b.horizon),
      softbox: d(a.softbox, b.softbox),
      rim: d(a.rim, b.rim),
      grainAmp: d(a.grainAmp, b.grainAmp),
      grainAcross: d(a.grainAcross, b.grainAcross),
      grainAngleDeg: d(a.grainAngleDeg, b.grainAngleDeg),
      shadowDyPerDepth: d(a.shadowDyPerDepth, b.shadowDyPerDepth),
      shadowBlurPerDepth: d(a.shadowBlurPerDepth, b.shadowBlurPerDepth),
      shadowOpacity: d(a.shadowOpacity, b.shadowOpacity),
      aoOpacity: d(a.aoOpacity, b.aoOpacity),
      aoReachPerDepth: d(a.aoReachPerDepth, b.aoReachPerDepth),
      innerBlurPerDepth: d(a.innerBlurPerDepth, b.innerBlurPerDepth),
      innerOpacity: d(a.innerOpacity, b.innerOpacity),
      exposure: d(a.exposure, b.exposure),
      white: d(a.white, b.white),
      dither: d(a.dither, b.dither),
      faceLiftLevels: d(a.faceLiftLevels, b.faceLiftLevels),
      faceDropLevels: d(a.faceDropLevels, b.faceDropLevels),
      recessLiftLevels: d(a.recessLiftLevels, b.recessLiftLevels),
      recessDropLevels: d(a.recessDropLevels, b.recessDropLevels),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LitSpec &&
      other.f0 == f0 &&
      other.roughness == roughness &&
      other.metalness == metalness &&
      other.anisotropy == anisotropy &&
      other.bow == bow &&
      other.chamferWidth == chamferWidth &&
      other.chamferProfile == chamferProfile &&
      other.landAngle == landAngle &&
      other.lightElevationDeg == lightElevationDeg &&
      other.key == key &&
      other.ambient == ambient &&
      other.sheen == sheen &&
      other.sky == sky &&
      other.ground == ground &&
      other.envAmount == envAmount &&
      other.horizon == horizon &&
      other.softbox == softbox &&
      other.rim == rim &&
      other.grainAmp == grainAmp &&
      other.grainAcross == grainAcross &&
      other.grainAngleDeg == grainAngleDeg &&
      other.shadowDyPerDepth == shadowDyPerDepth &&
      other.shadowBlurPerDepth == shadowBlurPerDepth &&
      other.shadowOpacity == shadowOpacity &&
      other.aoOpacity == aoOpacity &&
      other.aoReachPerDepth == aoReachPerDepth &&
      other.innerBlurPerDepth == innerBlurPerDepth &&
      other.innerOpacity == innerOpacity &&
      other.exposure == exposure &&
      other.white == white &&
      other.dither == dither &&
      other.faceLiftLevels == faceLiftLevels &&
      other.faceDropLevels == faceDropLevels &&
      other.recessLiftLevels == recessLiftLevels &&
      other.recessDropLevels == recessDropLevels;

  @override
  int get hashCode => Object.hashAll([
        f0, roughness, metalness, anisotropy, bow,
        chamferWidth, chamferProfile, landAngle,
        lightElevationDeg, key, ambient, sheen,
        sky, ground, envAmount, horizon, softbox, rim,
        grainAmp, grainAcross, grainAngleDeg,
        shadowDyPerDepth, shadowBlurPerDepth, shadowOpacity,
        aoOpacity, aoReachPerDepth, innerBlurPerDepth, innerOpacity,
        exposure, white, dither, faceLiftLevels, faceDropLevels,
        recessLiftLevels, recessDropLevels,
      ]);
}
