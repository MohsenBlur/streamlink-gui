import 'package:flutter/widgets.dart';

import 'app_material.dart';
import 'lit_surface.dart';

/// Retro AV deck — a cassette deck on a shelf, mid-1980s.
///
/// Dark is the bakelite-and-black-ABS machine itself; light is the same
/// machine in its grey-plastic silver-face trim. Both carry the era's one
/// unmistakable signature: the **VFD** — every readout glows vacuum-
/// fluorescent cyan, in both brightnesses, because a fluorescent display
/// does not care what colour the room is.
///
/// Against its two siblings the identity is MOULDED PLASTIC:
///
/// * **Glossier than both.** Injection-moulded ABS and phenolic are
///   semi-gloss out of the tool: a higher environment response and a lower
///   roughness than wood or anodise, so deck faces visibly catch the room.
/// * **A moulded edge, not a machined or routed one.** `chamferProfile`
///   sits between Analogue's bullnose and Rack's flat land — a draft angle
///   with a tool radius, which is what a moulding actually produces.
/// * **No fibre.** Plastic has no grain axis; what texture it has is the
///   tool's fine pebble, isotropic and subtle.
const MaterialSpec deckSpec = MaterialSpec(
  id: AppMaterial.deck,
  name: 'Retro AV deck',
  blurb: 'Moulded bakelite, grey ABS, a fluorescent readout.',
  light: _deckLight,
  dark: _deckDark,
  furniture: Furniture(
    plates: true,
    bezels: true,
    // The machine breathes through its bottom edge: a perforated vent strip,
    // the black deck's most recognisable non-control feature.
    chassis: ChassisSpec(
      kind: ChassisKind.ventStrip,
      bandExtent: 8,
      tone: Color(0xFFC4C6C3),
      toneDark: Color(0xFF1B1917),
    ),
  ),
  instruments: InstrumentSpec(
    meterStyle: MeterStyle.vfdSegments,
    vfdReadout: true,
  ),
  type: MaterialType(
    // The same DIN family as Rack at deliberately different axes: full
    // width and near-bold, which is the lettering the black decks actually
    // wore - DOLBY NR, HIGH SPEED DUBBING - wide, heavy, tracked out.
    // Sharing the family keeps the fallback discipline already proven for
    // Bahnschrift; the axes are what make it read as a different machine.
    labelFamily: 'Bahnschrift',
    labelWidth: 100,
    labelWeightLight: 600,
    labelWeightDark: 550,
    labelTracking: 1.4,
  ),
);

/// Mould pebble for the Canvas fallback path: the fine isotropic texture an
/// EDM-finished tool leaves in plastic. The lit path carries its grain in
/// the shader; this exists so the no-shader fallback still feels moulded.
const TextureSpec _pebble = TextureSpec(
  kind: TextureKind.speckle,
  amplitude: {
    SurfaceRole.panel: 2,
    SurfaceRole.raised: 2,
    SurfaceRole.sunken: 2,
  },
  grainAngleDeg: 0,
  tileDevicePx: Size(256, 256),
  dropBelowPx: 40,
  secondTileScale: 0.75,
  secondTileAngleDeg: 29,
);

const MaterialPalette _deckDark = MaterialPalette(
  // Bakelite's brown-black, a shade warmer than neutral - true black
  // phenolic always carries a little brown, and a dead-neutral dark reads
  // as a modern OLED app rather than a machine.
  canvas: Color(0xFF141110),
  surface: Color(0xFF272321),
  well: Color(0xFF171413),
  // The VFD: green-black glass, lit from within.
  screen: Color(0xFF0A0D0C),
  screenIsEmissive: true,
  screenText: Color(0xFFA5F2E3),
  screenSubtext: Color(0xFF5FB8AA),
  // The transport strip: every black deck wore a silver control band. Dark
  // theme gets bounded GUNMETAL rather than mirror silver - the ceiling is
  // set so the light text ink still clears 4.5:1 against the band plus its
  // lit face lift; true silver needs band-scoped inks, deferred.
  chrome: Color(0xFF43474D),
  text: Color(0xFFEDEBE7),
  // Lifted for the elevation overlay, same discipline as Rack and Analogue:
  // the worst ground is the deepest overlay under the lit lift.
  subtext: Color(0xFFD4D0C9),
  disabledText: Color(0xFFA9A49C),
  border: Color(0xFF7A756D),
  // The legacy pair for the switch knob, LED collar and avatar frame.
  highlight: Color(0xFF3A3532),
  shadow: Color(0xFF0A0807),
  lightAzimuthDeg: 90,
  // Glossy plastic's ramp: a sheen band that lifts hard and falls off fast,
  // with barely any hue movement - plastic does not warm in shadow the way
  // varnished wood does, it just darkens.
  fill: [
    (at: 0.00, dh: 1.0, ds: 0.008, dl: -0.020),
    (at: 0.38, dh: 0.5, ds: -0.004, dl: 0.052),
    (at: 1.00, dh: 1.5, ds: 0.010, dl: -0.018),
  ],
  // A cool-white lit edge: the moulded rim catches the room, not a lamp.
  bevelLight: Color(0x34FFFFFF),
  bevelShade: Color(0x59000000),
  bevelSweepExponent: 2.5,
  bevelAmbientFloor: 0.15,
  gloss: 0.07,
  glossBreak: 0.38,
  glossColour: Color(0xFFFFFFFF),
  texture: _pebble,
  contact: [
    ShadowLayer(color: Color(0x8C0A0807), dx: 0, dy: 0.6, blur: 0.4, spread: -0.4),
    ShadowLayer(color: Color(0x6B0A0807), dx: 0, dy: 1.0, blur: 1.0, spread: 0.2),
    ShadowLayer(color: Color(0x4D0A0807), dx: 0, dy: 0.4, blur: 1.4, spread: 0.4),
  ],
  inset: [
    ShadowLayer(color: Color(0x8C0A0807), dx: 0, dy: 0.667, blur: 1.333),
    ShadowLayer(color: Color(0x1FFFFFFF), dx: 0, dy: -0.667, blur: 1.333),
  ],
  darkDepth: DarkDepth.elevationOverlay,
  elevationOverlay: {2: 0.06, 3: 0.09, 5: 0.11, 8: 0.11},
  boundaryStrategy: BoundaryStrategy.explicitBorder,
  lit: _deckDarkLit,
  litScreen: _deckDarkVfd,
);

/// Black moulded plastic, lit.
///
/// A polished dielectric: metalness stays at zero - plastic's reflection is
/// neutral 4% however shiny it gets - and the gloss comes from a LOW
/// roughness with a HIGH environment response. That pairing is the whole
/// difference from Analogue's walnut: wood diffuses the lamp, plastic
/// mirrors the room. The moulded profile (0.35) gives the edge a soft land
/// with rounded arrises - a draft angle through a tool radius.
const LitSpec _deckDarkLit = LitSpec(
  f0: Color(0xFFFFFFFF),
  metalness: 0.0,
  roughness: 0.30,
  anisotropy: 0.0,
  // Nearly flat. A pressed steel face bows; a moulded plastic one is held
  // flat by its ribs, and at this material's low roughness a real bow
  // creases along the diagonals where the radial tilt changes direction -
  // the first render read as a picture frame, not a deck front.
  bow: 0.07,
  chamferWidth: 3.2,
  chamferProfile: 0.35,
  landAngle: 0.5,
  lightElevationDeg: 37,
  key: 0.85,
  ambient: 0.52,
  sheen: 0.06,
  // A neutral evening room: cooler and brighter than Analogue's lamp,
  // dimmer than Rack's studio.
  sky: Color(0xFF7E838A),
  ground: Color(0xFF060607),
  envAmount: 0.38,
  horizon: 0.24,
  softbox: 0.12,
  rim: 0.42,
  // The tool's pebble: fine, isotropic, just enough to keep the gloss from
  // reading as wet.
  grainAmp: 0.14,
  grainAcross: 2.8,
  shadowDyPerDepth: 1.35,
  shadowBlurPerDepth: 2.6,
  shadowOpacity: 0.72,
  aoOpacity: 0.62,
  aoReachPerDepth: 1.1,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.72,
  // Measured through the real painter (probe_lit_bounds): gloss black
  // plastic keeps a near-still face - lift peaks at 3.1, drop at 6.6 -
  // because with the bow flattened and the land closed the drama lives
  // entirely on the moulded edge and in the casts, which no glyph ever
  // sits on.
  faceLiftLevels: 3,
  faceDropLevels: 7,
  recessLiftLevels: 4,
  recessDropLevels: 5,
);

/// The VFD's glass: darker and tighter than the dial windows of the other
/// materials - fluorescent displays sat behind smoked filters precisely so
/// the room would vanish and only the glow would survive.
const LitSpec _deckDarkVfd = LitSpec(
  f0: Color(0xFFFFFFFF),
  metalness: 0.0,
  roughness: 0.07,
  anisotropy: 0.0,
  bow: 0.04,
  chamferWidth: 2.5,
  lightElevationDeg: 37,
  key: 0.85,
  ambient: 0.04,
  sheen: 0.0,
  sky: Color(0xFF7E838A),
  ground: Color(0xFF060607),
  envAmount: 0.40,
  horizon: 0.04,
  softbox: 0.30,
  rim: 0.50,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.80,
  // The raster: 3-device-px rows with a whisper of aperture grille. It
  // multiplies the albedo, so it can only DARKEN - the safe direction for
  // the cyan ink - and the period is device pixels, so it stays crisp at
  // every window scale.
  patternKind: 1,
  patternPeriodPx: 3,
  patternStrength: 0.30,
  patternStrength2: 0.05,
  // Re-measured with the raster: it darkens (-4.5 peak lift, 14.3 drop).
  faceLiftLevels: 1,
  faceDropLevels: 15,
);

const LitSpec _deckLightVfd = LitSpec(
  f0: Color(0xFFFFFFFF),
  metalness: 0.0,
  roughness: 0.07,
  anisotropy: 0.0,
  bow: 0.04,
  chamferWidth: 2.5,
  lightElevationDeg: 40,
  key: 0.85,
  ambient: 0.04,
  sheen: 0.0,
  sky: Color(0xFFFDFDFB),
  ground: Color(0xFF7E7C76),
  // Dimmer than the other materials' dial glass: a VFD sat behind a smoked
  // filter precisely so the room would vanish. First draft used the dial-
  // window numbers and the daylight washed the pane +17 levels - a lit
  // room in a display whose point is that the room is not there.
  envAmount: 0.16,
  horizon: 0.04,
  softbox: 0.14,
  rim: 0.45,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.65,
  patternKind: 1,
  patternPeriodPx: 3,
  patternStrength: 0.30,
  patternStrength2: 0.05,
  // Re-measured with the raster: +5.6 / -7.2.
  faceLiftLevels: 6,
  faceDropLevels: 8,
);

const MaterialPalette _deckLight = MaterialPalette(
  // The grey-ABS trim: cool neutral plastic, deliberately away from both
  // Rack's champagne warmth and Analogue's cream.
  canvas: Color(0xFFD2D3D0),
  surface: Color(0xFFE7E8E5),
  well: Color(0xFFCFD0CC),
  // The VFD does not change with the room - same green-black glass, same
  // glow. This is R9's screenIsEmissive case in its purest form.
  screen: Color(0xFF0F1211),
  screenIsEmissive: true,
  screenText: Color(0xFFA5F2E3),
  screenSubtext: Color(0xFF5FB8AA),
  chrome: Color(0xFFCDCFD2),
  text: Color(0xFF262723),
  subtext: Color(0xFF41433E),
  disabledText: Color(0xFF5D6058),
  border: Color(0xFF6E716A),
  highlight: Color(0xFFFFFFFF),
  shadow: Color(0xFF2A2C28),
  lightAzimuthDeg: 90,
  fill: [
    (at: 0.00, dh: 0.0, ds: 0.004, dl: 0.010),
    (at: 0.38, dh: -1.0, ds: 0.010, dl: 0.050),
    (at: 1.00, dh: 1.5, ds: 0.006, dl: -0.055),
  ],
  bevelLight: Color(0x9BFFFFFF),
  bevelShade: Color(0x24222420),
  bevelSweepExponent: 2.5,
  bevelAmbientFloor: 0.15,
  gloss: 0.09,
  glossBreak: 0.38,
  glossColour: Color(0xFFFFFFFF),
  texture: _pebble,
  // Neutral-cool casts: grey plastic in daylight shadows grey, and warming
  // them would drag the whole trim toward Analogue.
  contact: [
    ShadowLayer(color: Color(0x332A2C28), dx: 0, dy: 0.6, blur: 0.4, spread: -0.4),
    ShadowLayer(color: Color(0x242A2C28), dx: 0, dy: 1.0, blur: 1.0, spread: 0.2),
    ShadowLayer(color: Color(0x1F2A2C28), dx: 0, dy: 0.4, blur: 1.4, spread: 0.4),
  ],
  inset: [
    ShadowLayer(color: Color(0x382A2C28), dx: 0, dy: 0.667, blur: 1.333),
    ShadowLayer(color: Color(0xB3FFFFFF), dx: 0, dy: -0.667, blur: 1.333),
  ],
  darkDepth: DarkDepth.lightSideCast,
  boundaryStrategy: BoundaryStrategy.explicitBorder,
  lit: _deckLightLit,
  litScreen: _deckLightVfd,
);

/// Grey ABS in daylight: the same moulded-plastic physics as the dark spec
/// with the light theme's exposure discipline, and a slightly duller finish
/// - the silver-face trims were matte-textured where the black decks were
/// polished.
const LitSpec _deckLightLit = LitSpec(
  f0: Color(0xFFFFFFFF),
  metalness: 0.0,
  roughness: 0.36,
  anisotropy: 0.0,
  // Flat for the same reason as the dark spec.
  bow: 0.06,
  chamferWidth: 3.0,
  chamferProfile: 0.35,
  landAngle: 0.5,
  lightElevationDeg: 40,
  key: 0.92,
  ambient: 0.62,
  sheen: 0.06,
  sky: Color(0xFFFDFDFB),
  ground: Color(0xFF7E7C76),
  envAmount: 0.30,
  horizon: 0.24,
  softbox: 0.10,
  rim: 0.32,
  grainAmp: 0.12,
  grainAcross: 2.8,
  shadowDyPerDepth: 1.25,
  shadowBlurPerDepth: 2.6,
  shadowOpacity: 0.40,
  aoOpacity: 0.40,
  aoReachPerDepth: 1.1,
  innerBlurPerDepth: 2.2,
  innerOpacity: 0.55,
  exposure: 2.2,
  // Measured: daylight ABS floats high - +17.4 at the sheen - and, like
  // Analogue's paper, never paints below its albedo; one level for the
  // dither.
  faceLiftLevels: 18,
  faceDropLevels: 1,
  recessLiftLevels: 17,
  recessDropLevels: 1,
);
