import 'package:flutter/widgets.dart';

import 'app_material.dart';
import 'lit_surface.dart';

/// Warm analogue — a hi-fi console in a lamplit listening room.
///
/// Light is paper and blond oak: cream index cards on a parchment desk, the
/// world of a 1970s console's owner's manual. Dark is oiled walnut under a
/// reading lamp — the cabinet itself, not its faceplate. Where Rack is the
/// machine, Analogue is the furniture the machine sits in.
///
/// Three physical decisions separate it from Rack, each carried by a number:
///
/// * **Edges are bullnosed, not machined.** Wood is routed and card is
///   die-cut; neither takes a flat land with two arrises. `chamferProfile: 0`
///   is the single most identity-defining parameter in this file — the same
///   geometry that reads "milled" on Rack reads "moulded" here.
/// * **The room is a lamp, not a studio.** Both environments are warm and the
///   dark one is dim: a listening room at night has one pool of tungsten
///   light and darkness past it, so the sky term is a glow, not a ceiling.
/// * **Shadow warms and saturates.** The oiled-wood rule — shadow on varnish
///   is not grey, it is deeper wood — is what the fill ramp's `dh`/`ds`
///   fields were built for; this palette is their first real user.
const MaterialSpec analogueSpec = MaterialSpec(
  id: AppMaterial.analogue,
  name: 'Warm analogue',
  blurb: 'Lamplit walnut, paper cards, a listening room at night.',
  light: _analogueLight,
  dark: _analogueDark,
  furniture: Furniture(
    plates: true,
    bezels: true,
    // THE signature: the walnut sleeve every silver-face receiver sat in.
    // Four mitred bands with the grain turning each corner; the top band is
    // slim because that is where the faceplate meets the lid - and where
    // the title bar's controls live. The title bar honours edgeClearance so
    // no chrome ever sits under wood.
    chassis: ChassisSpec(
      kind: ChassisKind.woodFrame,
      bandExtent: 10,
      topExtent: 6,
      tone: Color(0xFF7A5A3C),
      toneDark: Color(0xFF352519),
      edgeClearance: 14,
    ),
  ),
  instruments: InstrumentSpec(
    meterStyle: MeterStyle.needle,
    lampCollar: LampCollar.brass,
  ),
  type: MaterialType(
    // A serif, because consoles labelled their furniture in one and their
    // instruments in DIN: the engraving on a walnut cabinet is not the
    // engraving on its meter. Georgia is on every Windows since 2000; it is
    // a static family, so the width axis is declared at its only value and
    // the weights map to the nearest static weight.
    labelFamily: 'Georgia',
    labelWidth: 100,
    labelWeightLight: 400,
    labelWeightDark: 400,
    labelTracking: 1.0,
  ),
);

/// Paper tooth and wood pore for the Canvas fallback path.
///
/// Isotropic speckle rather than the directional brush: paper fibre has no
/// axis, and at these amplitudes wood pore does not read as directional
/// either. The lit path carries its own grain in the shader; this tile only
/// exists so a machine that cannot load the shader still feels the material.
const TextureSpec _fibre = TextureSpec(
  kind: TextureKind.speckle,
  amplitude: {
    SurfaceRole.panel: 3,
    SurfaceRole.raised: 2,
    SurfaceRole.sunken: 2,
  },
  grainAngleDeg: 0,
  tileDevicePx: Size(256, 256),
  dropBelowPx: 40,
  secondTileScale: 0.75,
  secondTileAngleDeg: 29,
);

const MaterialPalette _analogueDark = MaterialPalette(
  canvas: Color(0xFF171210),
  surface: Color(0xFF2C231C),
  well: Color(0xFF191411),
  screen: Color(0xFF100C09),
  screenIsEmissive: true,
  text: Color(0xFFEFE7DA),
  // Lightened the way Rack's were: this palette carries dark-theme depth as
  // an elevation overlay, so the worst ground is the deepest overlay under
  // the lit lift, not the raw token. Values are the measured minima.
  subtext: Color(0xFFD8CDBC),
  disabledText: Color(0xFFAC9F8C),
  border: Color(0xFF7C6F5E),
  accentMetal: Color(0xFFB08D57),
  // The legacy pair, for the switch knob, LED collar and avatar frame:
  // walnut lifted toward the lamp, and the room's warm black.
  highlight: Color(0xFF3E332A),
  shadow: Color(0xFF0A0705),
  lightAzimuthDeg: 90,
  // The oiled-wood signature, and the first use of dh/ds in anger: the sheen
  // band lifts toward the lamp's amber, and the SHADOW end goes warmer and
  // MORE saturated — grey shadow is the #1 tell of fake wood. dh is degrees
  // toward orange on this base's hue.
  fill: [
    (at: 0.00, dh: 2.0, ds: 0.020, dl: -0.020),
    (at: 0.38, dh: -2.0, ds: -0.010, dl: 0.045),
    (at: 1.00, dh: 4.0, ds: 0.045, dl: -0.022),
  ],
  // A warm lit edge — tungsten on varnish, not white on steel. Same alpha
  // discipline as Rack: the bevel is the free lever, no glyph sits on it.
  bevelLight: Color(0x30FFE8C4),
  bevelShade: Color(0x59000000),
  bevelSweepExponent: 2.5,
  bevelAmbientFloor: 0.15,
  gloss: 0.05,
  glossBreak: 0.38,
  glossColour: Color(0xFFFFF6E6),
  texture: _fibre,
  // Warm-black casts. Same three-layer structure as Rack's dark, slightly
  // softer: wood furniture sits in softer light than a rack in a machine
  // room.
  contact: [
    ShadowLayer(color: Color(0x8C0A0705), dx: 0, dy: 0.6, blur: 0.5, spread: -0.4),
    ShadowLayer(color: Color(0x6B0A0705), dx: 0, dy: 1.0, blur: 1.1, spread: 0.2),
    ShadowLayer(color: Color(0x4D0A0705), dx: 0, dy: 0.4, blur: 1.5, spread: 0.4),
  ],
  inset: [
    ShadowLayer(color: Color(0x8C0A0705), dx: 0, dy: 0.667, blur: 1.333),
    ShadowLayer(color: Color(0x17FFE8C4), dx: 0, dy: -0.667, blur: 1.333),
  ],
  darkDepth: DarkDepth.elevationOverlay,
  elevationOverlay: {2: 0.06, 3: 0.09, 5: 0.11, 8: 0.11},
  boundaryStrategy: BoundaryStrategy.explicitBorder,
  lit: _analogueDarkLit,
  litScreen: _analogueDarkGlass,
);

/// Oiled walnut under a reading lamp.
///
/// A varnished dielectric: low metalness, a soft mid roughness — oil and wax
/// give wood a sheen, never a mirror — and REAL anisotropy, because wood
/// fibre stretches every highlight along the grain exactly as brushed metal
/// does, just softer. The bullnose profile is the identity: this material has
/// no machined arris anywhere.
const LitSpec _analogueDarkLit = LitSpec(
  f0: Color(0xFFFFF0DC),
  metalness: 0.06,
  roughness: 0.38,
  anisotropy: 0.55,
  bow: 0.16,
  chamferWidth: 3.5,
  chamferProfile: 0.0,
  lightElevationDeg: 37,
  key: 0.85,
  ambient: 0.50,
  sheen: 0.10,
  // The lamp: warm, dim, and low in the frame. Past its pool the room is
  // genuinely dark — the ground term is nearly black.
  sky: Color(0xFF8C7B62),
  ground: Color(0xFF060403),
  envAmount: 0.28,
  horizon: 0.30,
  softbox: 0.14,
  rim: 0.30,
  // Wood pore: broader wavelength than metal brush, softer tilt.
  grainAmp: 0.22,
  grainAcross: 4.5,
  shadowDyPerDepth: 1.35,
  shadowBlurPerDepth: 2.8,
  shadowOpacity: 0.70,
  aoOpacity: 0.60,
  aoReachPerDepth: 1.1,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.70,
  // Measured through the real painter (probe_analogue_bounds): proud faces
  // peak at +13.4 (the chip) and -7.1 (deep cards, where the overlay lifts
  // the albedo above the shaded floor); the well's lamplit far wall reaches
  // +15.2 on its own darker ground.
  // +2 for the fibre tile the lit path now composites on panels.
  faceLiftLevels: 17,
  faceDropLevels: 8,
  recessLiftLevels: 16,
  recessDropLevels: 5,
);

/// The readout glass, in the lamp's room instead of the studio's.
const LitSpec _analogueDarkGlass = LitSpec(
  f0: Color(0xFFFFFFFF),
  metalness: 0.0,
  roughness: 0.09,
  anisotropy: 0.0,
  bow: 0.05,
  chamferWidth: 2.5,
  lightElevationDeg: 37,
  key: 0.85,
  ambient: 0.05,
  sheen: 0.0,
  sky: Color(0xFF8C7B62),
  ground: Color(0xFF060403),
  envAmount: 0.50,
  horizon: 0.05,
  softbox: 0.35,
  rim: 0.50,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.80,
  // The incandescent lamp behind the dial - warmer and a touch stronger
  // than Rack's blue, because tungsten through amber plastic is the whole
  // mood of a lamplit receiver. Bounds re-measured with the lamp lit.
  patternKind: 2,
  patternStrength: 0.065,
  patternStrength2: 2.0,
  patternColor: Color(0xFFFFCF8F),
  // Re-measured with the lamp lit: tungsten carries the top +29.6.
  faceLiftLevels: 30,
  faceDropLevels: 3,
);

const LitSpec _analogueLightGlass = LitSpec(
  f0: Color(0xFFFFFFFF),
  metalness: 0.0,
  roughness: 0.09,
  anisotropy: 0.0,
  bow: 0.05,
  chamferWidth: 2.5,
  lightElevationDeg: 40,
  key: 0.85,
  ambient: 0.05,
  sheen: 0.0,
  sky: Color(0xFFFFF8E7),
  ground: Color(0xFF8A7A62),
  envAmount: 0.40,
  horizon: 0.05,
  softbox: 0.30,
  rim: 0.50,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.65,
  patternKind: 2,
  patternStrength: 0.055,
  patternStrength2: 2.0,
  patternColor: Color(0xFFFFCF8F),
  // Re-measured with the lamp: +17.3 / -4.0.
  faceLiftLevels: 18,
  faceDropLevels: 1,
);

const MaterialPalette _analogueLight = MaterialPalette(
  canvas: Color(0xFFDDD3C1),
  surface: Color(0xFFF0E8D8),
  well: Color(0xFFD6CBB7),
  // The readout stays dark in a lit room — same reasoning as Rack, warmer
  // rendering: charcoal with wood under it, not blue-grey steel.
  screen: Color(0xFF322B24),
  screenIsEmissive: true,
  screenText: Color(0xFFF0E9DC),
  screenSubtext: Color(0xFFCDBFAC),
  text: Color(0xFF33291E),
  subtext: Color(0xFF4C4133),
  disabledText: Color(0xFF68604F),
  border: Color(0xFF75695A),
  accentMetal: Color(0xFF8F6B36),
  highlight: Color(0xFFFFFFFF),
  shadow: Color(0xFF40301C),
  lightAzimuthDeg: 90,
  // Cream card warms toward its sheen and browns in its shade. Gentler than
  // the walnut's swing: paper is matte, and most of what it does is diffuse.
  fill: [
    (at: 0.00, dh: 0.0, ds: 0.020, dl: 0.010),
    (at: 0.38, dh: -4.0, ds: 0.100, dl: 0.045),
    (at: 1.00, dh: 8.0, ds: 0.020, dl: -0.060),
  ],
  bevelLight: Color(0x96FFFDF4),
  bevelShade: Color(0x241E1206),
  bevelSweepExponent: 2.5,
  bevelAmbientFloor: 0.15,
  gloss: 0.08,
  glossBreak: 0.38,
  glossColour: Color(0xFFFFF6E6),
  texture: _fibre,
  // Umber casts — the shadow of paper on oak is coffee-coloured, and a
  // neutral black would read as a hole in the desk.
  contact: [
    ShadowLayer(color: Color(0x3340301C), dx: 0, dy: 0.6, blur: 0.5, spread: -0.4),
    ShadowLayer(color: Color(0x2440301C), dx: 0, dy: 1.0, blur: 1.1, spread: 0.2),
    ShadowLayer(color: Color(0x1F40301C), dx: 0, dy: 0.4, blur: 1.5, spread: 0.4),
  ],
  inset: [
    ShadowLayer(color: Color(0x3840301C), dx: 0, dy: 0.667, blur: 1.333),
    ShadowLayer(color: Color(0xB3FFFFFF), dx: 0, dy: -0.667, blur: 1.333),
  ],
  darkDepth: DarkDepth.lightSideCast,
  boundaryStrategy: BoundaryStrategy.explicitBorder,
  lit: _analogueLightLit,
  litScreen: _analogueLightGlass,
);

/// Cream card on a lamplit desk.
///
/// Paper is the most diffuse thing this engine renders: near-zero metalness,
/// high roughness, no anisotropy, and almost no environment — its identity
/// lives in the soft bow of a card's face and the warm, translucent shadow it
/// lays on the desk. The camera exposes for paper-white, same as Rack's
/// light theme and for the same tone-map reason.
const LitSpec _analogueLightLit = LitSpec(
  f0: Color(0xFFFFFBEF),
  metalness: 0.0,
  roughness: 0.60,
  anisotropy: 0.0,
  bow: 0.08,
  chamferWidth: 3.0,
  chamferProfile: 0.0,
  lightElevationDeg: 40,
  key: 0.92,
  ambient: 0.62,
  sheen: 0.05,
  sky: Color(0xFFFFF8E7),
  ground: Color(0xFF8A7A62),
  envAmount: 0.22,
  horizon: 0.28,
  softbox: 0.10,
  rim: 0.25,
  // Paper tooth: fine and isotropic.
  grainAmp: 0.12,
  grainAcross: 3.0,
  shadowDyPerDepth: 1.25,
  shadowBlurPerDepth: 2.8,
  shadowOpacity: 0.38,
  aoOpacity: 0.40,
  aoReachPerDepth: 1.1,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.55,
  exposure: 2.2,
  // Measured: every paper face floats ABOVE its albedo - the exposure boost
  // means the shaded side still sits +8 over the token - so the albedo is
  // effectively the darkest thing a card ever paints. One level, not zero:
  // the shader dithers +-1 LSB, and a claim of "lighting can never darken
  // this face at all" is exactly the overclaim the contract rejects.
  faceLiftLevels: 17,
  faceDropLevels: 1,
  recessLiftLevels: 17,
  recessDropLevels: 1,
);
