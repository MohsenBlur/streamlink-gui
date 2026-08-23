import 'package:flutter/widgets.dart';

import 'app_material.dart';

/// Broadcast rack — a 19-inch milled aluminium faceplate.
///
/// Dark is graphite hard-anodise; light is 1970s champagne silver-face, the
/// finish on a Technics or Marantz front panel. Horizontal brush grain,
/// recessed dial windows, engraved-and-infilled legends.
///
/// It is the domain-native metaphor rather than a decorative one: this app is a
/// control surface for a broadcast receiver, and it already owns a real LED, a
/// real toggle and a lens bezel. Those three stop being oddities here and
/// become the house style.
///
/// **Light comes from directly above.** Rack is the one material that cannot
/// take a diagonal: the brush grain runs horizontally, and a diagonal key light
/// puts the sheen band across the grain, which reads as a smear rather than as
/// metal.
///
/// Every number below is derived rather than eyeballed, and the contrast at the
/// worst point of each fill is recorded in `rack_test.dart` rather than in a
/// comment, so it cannot drift.
const MaterialSpec rackSpec = MaterialSpec(
  id: AppMaterial.rack,
  name: 'Broadcast rack',
  blurb: 'Milled aluminium, engraved legends, indicator lamps.',
  light: _rackLight,
  dark: _rackDark,
  // No screws and no edge groove, and this is a finding rather than a taste
  // call. Both shipped in v1.7.0 and both were wrong on this window.
  //
  // The screws sat in the four window corners, 12px across with a horizontal
  // slot - which at that size is indistinguishable from a minimise button. The
  // top-right one landed immediately beside the real close button and read as
  // a fourth, disabled window control. "No ornament obscuring a control" was
  // the rule; the one it needed was "no ornament IMITATING a control".
  //
  // The groove was a hairline rectangle inset from the window edge, painted as
  // a foregroundDecoration over everything. A milled groove reads as a groove
  // because it is cut into a plate with a margin around it. This window's
  // chrome reaches its own edges - the sidebar starts at x=0 and the title bar
  // spans the full width - so there is no margin for it to be cut into, and it
  // read as a stray line drawn across the UI.
  //
  // The tell was there during implementation and I explained it away: the
  // screws collided with the close button, and I "fixed" that by insetting the
  // title bar's contents by 26px. Needing to move the chrome to make room for
  // ornament is the ornament telling you it does not belong.
  //
  // `plates` and `bezels` stay: those are drawn ON surfaces that genuinely
  // have margins - the engraved legend on the title bar, the rim around a
  // recessed thumbnail - rather than on the window.
  furniture: Furniture(plates: true, bezels: true),
  type: MaterialType(
    labelFamily: 'Bahnschrift',
    labelWidth: 87.5,
    // Light-on-dark strokes bloom, so the dark theme reads heavier at the same
    // nominal weight. Real panel lettering compensates; so does this.
    labelWeightLight: 400,
    labelWeightDark: 375,
    labelTracking: 0.8,
  ),
);

/// The brush, shared by both brightnesses.
///
/// Two streak frequencies plus a blue-noise micro-grain, because a single
/// frequency reads as corduroy. Non-square tile: a 256-square tile cannot carry
/// a streak long enough to look drawn rather than dotted.
///
/// Amplitude is in sRGB levels, not alpha, and it is not a free parameter — it
/// is the largest value the worst-texel contrast assertion permits given the
/// inks below. Three levels, and only on surfaces that carry a fill; chips and
/// screens take none, because at 18px the structure aliases into something that
/// reads as JPEG damage.
const TextureSpec _brushed = TextureSpec(
  kind: TextureKind.brushed,
  amplitude: {
    SurfaceRole.panel: 3,
    SurfaceRole.raised: 2,
    SurfaceRole.sunken: 2,
  },
  grainAngleDeg: 0,
  tileDevicePx: Size(512, 128),
  dropBelowPx: 40,
  secondTileScale: 0.75,
  secondTileAngleDeg: 29,
);

const MaterialPalette _rackDark = MaterialPalette(
  canvas: Color(0xFF16181C),
  surface: Color(0xFF2A2E35),
  well: Color(0xFF171A1F),
  screen: Color(0xFF0C0F13),
  screenIsEmissive: true,
  text: Color(0xFFE8EBEF),
  // Both lightened after `worstGround` learned about the elevation overlay.
  //
  // This palette carries its depth by blending white INTO the base before the
  // gradient sees it - up to 11% at depth 8 - so an elevated surface paints far
  // lighter than its token. The contrast model did not know that, so it
  // measured #444850 where a NeuCard actually paints #55585E: subtext read
  // 5.17:1 against the answer and 3.69:1 against the pixel, and disabledText
  // 2.28:1 against a 3:1 bar.
  //
  // These are the measured minima on the worst ground the app can produce, not
  // round numbers - see the note on `worstGround`.
  subtext: Color(0xFFD0D7E1),
  disabledText: Color(0xFFA8B0BC),
  border: Color(0xFF737A88),
  // The legacy highlight/shadow pair, still read by eight sites outside the
  // engine - the switch knob, the LED collar, the avatar frame. Graphite
  // lifted toward the light, and the same near-black the cast layers use.
  highlight: Color(0xFF3A404A),
  shadow: Color(0xFF0B0E13),
  // 90 degrees in this file's convention: counter-clockwise from +x, naming
  // the direction of the source, so this is straight above.
  lightAzimuthDeg: 90,
  // Three stops, and the middle one is *lighter* than the base. A ramp that
  // only darkens reads as a painted panel; a real faceplate catches a sheen
  // band where it faces the light and falls away above and below it.
  fill: [
    (at: 0.00, dh: 3.8, ds: 0.0062, dl: -0.0255),
    (at: 0.38, dh: 3.4, ds: -0.0084, dl: 0.0510),
    (at: 1.00, dh: 1.8, ds: -0.0099, dl: -0.0196),
  ],
  // 22% white, not 12%. The lit edge is the single strongest "machined" cue a
  // dark panel has, and it is the one lever with no contrast cost: the bevel
  // is a ring one logical pixel wide at the box edge, and every surface in the
  // app carries at least four pixels of padding, so no glyph ever sits on it.
  // The fill, the grain and the gloss all have to be paid for against the
  // worst-pixel matrix; this does not.
  bevelLight: Color(0x38FFFFFF),
  // The dark side is left alone. On a near-black canvas a shadow has nowhere
  // to go - black at 50% over #16181C reaches 1.23:1 - which is the whole
  // reason this palette carries its depth on the light side.
  bevelShade: Color(0x59000000),
  // Swept, not uniform: a constant-alpha ring is a CSS border. Real reflectance
  // is nearly flat to about 60 degrees off the light and then climbs steeply.
  bevelSweepExponent: 2.5,
  bevelAmbientFloor: 0.15,
  gloss: 0.06,
  glossBreak: 0.38,
  glossColour: Color(0xFFFFFFFF),
  texture: _brushed,
  // Three layers, not one: contact, key and ambient. One shadow looks flat;
  // three look machined. Depth-relative, authored against depth 5.
  contact: [
    ShadowLayer(color: Color(0x8C0B0E13), dx: 0, dy: 0.6, blur: 0.4, spread: -0.4),
    ShadowLayer(color: Color(0x6B0B0E13), dx: 0, dy: 1.0, blur: 1.0, spread: 0.2),
    ShadowLayer(color: Color(0x4D0B0E13), dx: 0, dy: 0.4, blur: 1.4, spread: 0.4),
  ],
  // Authored against depth 3, which is what `sunken()` defaults to.
  inset: [
    ShadowLayer(color: Color(0x8C0B0E13), dx: 0, dy: 0.667, blur: 1.333),
    ShadowLayer(color: Color(0x1AFFFFFF), dx: 0, dy: -0.667, blur: 1.333),
  ],
  darkDepth: DarkDepth.elevationOverlay,
  elevationOverlay: {2: 0.05, 3: 0.07, 5: 0.08, 8: 0.11},
  boundaryStrategy: BoundaryStrategy.explicitBorder,
);

const MaterialPalette _rackLight = MaterialPalette(
  canvas: Color(0xFFCFC9BE),
  surface: Color(0xFFE4DDCE),
  well: Color(0xFFCDC6B8),
  // A lit readout stays dark in a lit room, so the screen and its ink are the
  // dark pair in both brightnesses. Without this the light material's own text
  // measured 1.08:1 here, because both are dark.
  screen: Color(0xFF2B2E33),
  screenIsEmissive: true,
  screenText: Color(0xFFE8EBEF),
  screenSubtext: Color(0xFFB9C3D2),
  text: Color(0xFF2B2823),
  subtext: Color(0xFF454138),
  // #6B665D measured 2.66:1 against this palette's own worst ground - the well
  // at the bottom of its fill, #B3B1AB. The researched value was checked
  // against the flat well, which is not where text lands.
  disabledText: Color(0xFF635E55),
  border: Color(0xFF6F6A5F),
  highlight: Color(0xFFFFFFFF),
  shadow: Color(0xFF383124),
  lightAzimuthDeg: 90,
  // Champagne swings hue as well as lightness: warm at the sheen, cool in the
  // shade. A lightness-only ramp on this base renders as beige paint, which is
  // the difference between anodised aluminium and a painted panel.
  fill: [
    (at: 0.00, dh: 0.0, ds: 0.0248, dl: 0.0118),
    (at: 0.38, dh: -3.8, ds: 0.1573, dl: 0.0569),
    (at: 1.00, dh: 6.5, ds: -0.1243, dl: -0.0765),
  ],
  bevelLight: Color(0x9EFFFFFF),
  bevelShade: Color(0x21000000),
  bevelSweepExponent: 2.5,
  bevelAmbientFloor: 0.15,
  gloss: 0.10,
  glossBreak: 0.38,
  glossColour: Color(0xFFFFFFFF),
  texture: _brushed,
  // Warm shadows, not black. A neutral-black shadow on a warm ground reads as
  // a hole; the shadow of a champagne panel is the panel's own hue, darker.
  contact: [
    ShadowLayer(color: Color(0x33383124), dx: 0, dy: 0.6, blur: 0.4, spread: -0.4),
    ShadowLayer(color: Color(0x24383124), dx: 0, dy: 1.0, blur: 1.0, spread: 0.2),
    ShadowLayer(color: Color(0x1F383124), dx: 0, dy: 0.4, blur: 1.4, spread: 0.4),
  ],
  inset: [
    ShadowLayer(color: Color(0x38383124), dx: 0, dy: 0.667, blur: 1.333),
    ShadowLayer(color: Color(0xB3FFFFFF), dx: 0, dy: -0.667, blur: 1.333),
  ],
  // Light mode carries depth on the dark side, where it has room.
  darkDepth: DarkDepth.lightSideCast,
  boundaryStrategy: BoundaryStrategy.explicitBorder,
);
