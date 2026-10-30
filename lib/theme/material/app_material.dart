import 'package:flutter/widgets.dart';

import '../neu_theme.dart';
import 'material_palette.dart';

export 'material_palette.dart';

/// The app's one material: a palette per brightness.
///
/// There were four - Soft (classic), Broadcast rack, Warm analogue and Retro
/// AV deck - chosen in Settings and stored under the config's `material`
/// key. Only Soft is left, so nothing here is chosen any more and the key is
/// written only for older builds (see `AppSettings.toJson`).
///
/// Kept as a value rather than folded into `NeuTheme` because the contrast
/// tests and the fidelity gate hand a palette straight to the painter, with
/// no widget tree and no theme notifier.
@immutable
class MaterialSpec {
  const MaterialSpec({required this.light, required this.dark});

  final MaterialPalette light, dark;

  MaterialPalette palette(bool isDark) => isDark ? dark : light;
}

// ---------------------------------------------------------------------------
// Soft — the app's look through v1.6.0, preserved exactly.
//
// Every value below is transcribed from `neu_theme.dart` at v1.6.0, and
// `soft_fidelity_test` paints it against a frozen copy of that recipe. Two
// things about it look like mistakes and are not:
//
//   * The recess is an outer shadow pair with a negative spread, not an inset
//     at all - the painter casts the `inset` layers outward.
//   * `diagonalCompensation: false` — Soft's Offset(d, d) genuinely travels
//     1.414 * d, and correcting it would be a redesign rather than a fix.
//
// The shadow layers are depth-relative because the originals were: offsets of
// +-depth with `blurRadius: depth * 2`.
// ---------------------------------------------------------------------------

/// Soft's shadow alphas, exactly as `raised()` and `sunken()` apply them.
///
/// Named rather than inlined so the transcription is one line long and the
/// test can assert against the same names.
const double _raisedHiA = 0.90, _raisedShA = 0.80; // light

/// Dark alphas, raised 2026-08-25. The originals were tuned when the dark
/// pair itself had almost no range (#2B303F highlight, #12151B shadow on a
/// #1D212A canvas) and the user's verdict on the result was "too flat
/// compared to its light counterpart" - which it measurably was: the cast
/// landed 8 sRGB levels below the canvas where the light theme's lands 40+
/// below its own. The pair is deeper now and the alphas carry more of it.
const double _raisedHiADark = 0.70, _raisedShADark = 0.90;
const double _sunkenShA = 0.70, _sunkenHiA = 0.85; // light
const double _sunkenShADark = 0.85, _sunkenHiADark = 0.45;

final MaterialSpec softSpec = MaterialSpec(
  light: _soft(false),
  dark: _soft(true),
);

/// Builds a Soft palette from the **raw** v1.6.0 tokens.
///
/// Raw, not the public accessors: those resolve through this palette, and a
/// palette that read them would recurse on its first colour.
///
/// Deriving instead of copying removes the whole class of transcription bug —
/// and the hand-written version was already wrong: `0xE6` encodes alpha
/// 0.902, not the 0.90 that `withValues` produces, so every shadow would have
/// been a fraction off and the fidelity gate would have reported a diff nobody
/// could explain.
MaterialPalette _soft(bool isDark) {
  final hi = NeuTheme.rawHighlight(isDark);
  final sh = NeuTheme.rawShadow(isDark);
  return MaterialPalette(
    canvas: NeuTheme.rawCanvas(isDark),
    surface: NeuTheme.rawSurface(isDark),
    well: NeuTheme.rawWellSurface(isDark),
    // Soft has no screen of its own; the well is the closest it has to a
    // The frozen v1.6.0 log-pane ground. `Soft` is contracted to be
    // pixel-identical to what shipped, and the only surface the screen role
    // paints is the log pane - which shipped on `terminalBg`. Reusing the well
    // here rendered #D8E0EB where v1.6.0 rendered #F8FAFC (dark: #13151A vs
    // #0F131E), and left `terminalBg` a dead accessor with zero call sites.
    //
    // Nothing looked: `soft_fidelity_test` paints only raised and sunken, and
    // the contract test's raw-token group omitted `screen`.
    screen: NeuTheme.rawTerminalBg(isDark),
    text: NeuTheme.rawText(isDark),
    subtext: NeuTheme.rawSubtext(isDark),
    border: NeuTheme.rawBorder(isDark),
    highlight: hi,
    shadow: sh,
    disabledText: NeuTheme.rawDisabledText(isDark),
    // topLeft -> bottomRight: the key light sits up and to the left.
    lightAzimuthDeg: 135,
    // Soft's Offset(d, d) genuinely travels 1.414 * d. Correcting that would
    // be a redesign, not a fix.
    diagonalCompensation: false,
    // Two stops, not three. Forced through a three-stop ramp Soft would gain a
    // midpoint computed in HSL, which is not the sRGB midpoint a two-stop
    // LinearGradient rasterises - every raised pixel would move a level and
    // the fidelity gate would sit permanently outside "unchanged".
    fill: const [
      (at: 0.0, dh: 0.0, ds: 0.0, dl: 0.0),
      (at: 1.0, dh: 0.0, ds: 0.0, dl: -NeuTheme.fillSpread),
    ],
    bevelLight: hi.withValues(alpha: isDark ? 0.12 : 0.60),
    bevelShade: const Color(0xFF000000).withValues(alpha: isDark ? 0.45 : 0.045),
    // Depth lives in the CASTS, never in the face. The first dark-depth fix
    // added an elevation overlay - raised faces lightening with depth - and
    // the user's verdict was exact: "raised elements look like floating
    // panels instead of 3d raised portions of the same slab". A lighter face
    // on a darker ground is the layered-paper read; EXTRUSION means the face
    // keeps the slab's own value and the edges carry the light. What made
    // the overlay seem necessary was that the original cast had no headroom
    // (#12151B on a #1D212A canvas); with the pair deepened to #07090D /
    // #39415A the dark cast lands ~20 levels below the canvas and the light
    // cast ~25 above it, and the casts alone do what the overlay was
    // compensating for.
    contact: [
      ShadowLayer(
          color: hi.withValues(alpha: isDark ? _raisedHiADark : _raisedHiA),
          dx: -1, dy: -1, blur: 2),
      ShadowLayer(
          color: sh.withValues(alpha: isDark ? _raisedShADark : _raisedShA),
          dx: 1, dy: 1, blur: 2),
    ],
    inset: [
      ShadowLayer(
          color: sh.withValues(alpha: isDark ? _sunkenShADark : _sunkenShA),
          dx: 1, dy: 1, blur: 2, spread: -0.5),
      ShadowLayer(
          color: hi.withValues(alpha: isDark ? _sunkenHiADark : _sunkenHiA),
          dx: -1, dy: -1, blur: 2, spread: -0.5),
    ],
    // Soft pins its semantic inks: "the look the app had before" includes
    // these exact values, each calibrated against Soft's own grounds in the
    // commit that fixed seven WCAG failures. Deriving them would move them a
    // level or two for no gain. Dark needs no pin - the brand colours already
    // clear there, so the derivation returns them untouched.
    inkOverrides: isDark
        ? const <String, Color>{}
        : const <String, Color>{
            'liveText': Color(0xFF006B4B),
            'dangerText': Color(0xFFBB122F),
            'warningText': Color(0xFF8A5000),
            'favoriteText': Color(0xFFA56D00),
          },
  );
}
