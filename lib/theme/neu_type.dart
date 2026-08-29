import 'package:flutter/material.dart';

import 'material/app_material.dart';
import 'neu_theme.dart';

/// The type scale.
///
/// The app had **17 distinct font sizes across 271 call sites** - 11 x78,
/// 12 x66, 13 x56, 10 x24, down through 9.5, 9, 8.5 and 8. The three helpers
/// that existed (`titleStyle`, `bodyStyle`, `subtextStyle`) each took an
/// overridable `fontSize`, and *every* call site overrode it, so the tokens
/// unified colour and nothing else.
///
/// Twelve named steps over seven sizes. [headingSm] and [body] share 13px and
/// separate on weight, which is what the codebase was already doing by hand.
///
/// **400, 600 and 700 only.** Segoe UI ships Light / Semilight / Regular /
/// Semibold / Bold / Black - there is **no Medium**, so `bodyStyle`'s default
/// `w500` (about 59 sites) silently fell back to and rendered as `w400`. The
/// app believed it had a weight step it does not have.
///
/// Every step takes `isDark` and returns a style already carrying the right
/// ink. Pass [color] only for a genuinely different colour - an accent, a
/// danger red - not to re-state the default.
abstract final class NeuType {
  /// 24/700. The one-per-screen page title.
  static TextStyle display(bool isDark, {Color? color}) =>
      _style(24, FontWeight.w700, color ?? NeuTheme.text(isDark));

  /// 20/700. Screen headings - the channel name, "Library".
  static TextStyle headingLg(bool isDark, {Color? color}) =>
      _style(20, FontWeight.w700, color ?? NeuTheme.text(isDark));

  /// 16/700. Dialog titles, card headings.
  static TextStyle headingMd(bool isDark, {Color? color}) =>
      _style(16, FontWeight.w700, color ?? NeuTheme.text(isDark));

  /// 13/700. Section headings inside a panel - "Default Video Quality".
  static TextStyle headingSm(bool isDark, {Color? color}) =>
      _style(13, FontWeight.w700, color ?? NeuTheme.text(isDark));

  /// 13/400. Running text. The default for anything read as prose.
  static TextStyle body(bool isDark, {Color? color}) =>
      _style(13, FontWeight.w400, color ?? NeuTheme.text(isDark));

  /// 13/600. A body line that carries weight - a list row's title.
  static TextStyle bodyStrong(bool isDark, {Color? color}) =>
      _style(13, FontWeight.w600, color ?? NeuTheme.text(isDark));

  /// 12/600. Control labels, buttons, tabs.
  static TextStyle label(bool isDark, {Color? color}) =>
      _style(12, FontWeight.w600, color ?? NeuTheme.text(isDark));

  /// 12/400. Dense running text - input values, dropdown values, the inline
  /// labels beside a control.
  ///
  /// A twelfth step where the plan called for eleven, and deliberately so.
  /// 12/400 is the app's second most common style (33 call sites); the eleven
  /// -step scale had no 12/400, so every one of those would have had to move
  /// to 13 or 11. Both are visible density changes on the densest surfaces,
  /// made blind across 33 sites. With this step every mapping in the sweep is
  /// size-preserving, and the sizes still collapse from seventeen to seven -
  /// which was the point. It pairs with [label] exactly as [body] pairs with
  /// [bodyStrong] and [caption] with [captionStrong]: same size, split on
  /// weight.
  static TextStyle bodySm(bool isDark, {Color? color}) =>
      _style(12, FontWeight.w400, color ?? NeuTheme.text(isDark));

  /// 11/400. Secondary information - dates, sizes, descriptions.
  static TextStyle caption(bool isDark, {Color? color}) =>
      _style(11, FontWeight.w400, color ?? NeuTheme.subtext(isDark));

  /// 11/600. A caption that names something rather than describing it.
  static TextStyle captionStrong(bool isDark, {Color? color}) =>
      _style(11, FontWeight.w600, color ?? NeuTheme.subtext(isDark));

  /// 10/700, +0.6 tracking, ALL CAPS. Badges and status chips.
  ///
  /// **The floor.** Below 10px Segoe UI's stems go sub-pixel and grey out
  /// whatever colour they are given, which is why the 8, 8.5, 9 and 9.5px
  /// labels this replaces looked washed out no matter what ink they carried.
  /// Every caller must uppercase its own text - a style cannot.
  static TextStyle micro(bool isDark, {Color? color}) => TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: color ?? NeuTheme.subtext(isDark),
      );

  /// The material's own label face, applied to a style that already exists.
  ///
  /// A treatment, like [readout], and for the same reason: it swaps the face
  /// and leaves the size, the weight and the tracking exactly where the step
  /// put them, so adopting it cannot move a pixel of layout. Returns [style]
  /// untouched on any material that declares no label family, which is how
  /// Soft opts out without the call site knowing Soft exists.
  ///
  /// ## Why this binds through font axes and not a family name
  ///
  /// Windows lists twelve `Bahnschrift *` families — Condensed, SemiBold
  /// SemiCondensed, and so on. Those are **GDI aliases**, and Flutter does not
  /// resolve fonts through GDI; Skia asks DirectWrite, which holds exactly one
  /// family called `Bahnschrift`. Measured in a built app at 40px, asking for
  /// `'Bahnschrift SemiBold Condensed'` at w600 lays out at advance 435.449
  /// with 4385 ink pixels — byte for byte what `'Segoe UI'` w600 produces. It
  /// silently renders as Segoe UI Semibold, and nothing anywhere says so.
  ///
  /// The axis path is the one that works: the same family string at
  /// `wght 600` and `wdth 75` lays out at 290.449, thirty percent narrower,
  /// which is the DIN condensed a panel legend is actually asking for.
  ///
  /// ## The weight is deliberately stated twice, and differently
  ///
  /// `fontVariations` carries the material's weight for Bahnschrift;
  /// `fontWeight` is left as the step's own, which is what Segoe UI gets when
  /// the family does not resolve. They disagree on purpose — Bahnschrift's
  /// DIN at 400 is sturdy where Segoe at 400 and 10px goes sub-pixel and greys
  /// out. Forcing them to agree would make one of the two faces wrong.
  ///
  /// **Nothing can detect the fall-through at runtime**, so every size and
  /// tracking here has to work in plain Segoe UI. The material face buys
  /// character and horizontal headroom; it is never load-bearing for fit.
  /// Forces the fallback, for checking that the app is legible without the
  /// material face.
  ///
  /// `flutter run -d windows --dart-define=SKEUO_NO_BAHNSCHRIFT=true`
  ///
  /// It exists because nothing detects the fall-through at runtime: a machine
  /// without the face renders plain Segoe UI and says nothing about it. This
  /// is the only way to see that layout before shipping it, and it is a
  /// compile-time constant so it costs nothing when off.
  static const bool suppressMaterialFace =
      bool.fromEnvironment('SKEUO_NO_BAHNSCHRIFT', defaultValue: false);

  static TextStyle plated(TextStyle style, bool isDark,
      {AppMaterial? material}) {
    if (suppressMaterialFace) return style;
    final type = MaterialSpec.of(material ?? NeuTheme.activeMaterial).type;
    final family = type.labelFamily;
    if (family == null) return style;
    return style.copyWith(
      fontFamily: family,
      fontFamilyFallback: const ['Segoe UI'],
      fontVariations: [
        FontVariation('wght', type.weightFor(isDark)),
        FontVariation('wdth', type.labelWidth),
      ],
    );
  }

  /// 10/700 caps in the material's label face. Engraved panel legends.
  ///
  /// [micro] re-skinned, at the same size — a material may change what a
  /// legend is made of, never how big it is or where it sits. The tracking is
  /// the one thing it does own, because letterfit is a property of the face
  /// and 0.6 was measured on Segoe.
  ///
  /// Every caller must uppercase its own text; a style cannot.
  static TextStyle plate(bool isDark, {Color? color, AppMaterial? material}) {
    final type = MaterialSpec.of(material ?? NeuTheme.activeMaterial).type;
    return plated(
      micro(isDark, color: color).copyWith(letterSpacing: type.labelTracking),
      isDark,
      material: material,
    );
  }

  /// Lining, fixed-width figures on top of whatever step is already in use.
  ///
  /// A treatment, not a step, and that distinction is the point: counts,
  /// durations, sizes and percentages keep the size, weight and face they
  /// already have, so every adoption is size-preserving. It exists because
  /// `9.7 GB` and `20.1 GB` in a right-aligned column start at different
  /// x positions with proportional figures, and a column of numbers that does
  /// not line up reads as a rendering fault.
  ///
  /// [mono] adopts nothing: `tnum` on a fixed-pitch face is a no-op.
  static TextStyle readout(TextStyle style) {
    // Deck's readouts spread like a fluorescent display's fixed cells: the
    // figures gain tracking, never size (panel_type_test holds that line
    // for every material treatment).
    final vfd = !suppressMaterialFace &&
        MaterialSpec.of(NeuTheme.activeMaterial).instruments.vfdReadout;
    return style.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
      letterSpacing: vfd ? 1.1 : style.letterSpacing,
    );
  }

  /// 12/400 monospace. Log output, file paths, anything column-aligned.
  static TextStyle mono(bool isDark, {Color? color}) => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        fontFamily: 'Consolas',
        fontFamilyFallback: const ['Courier New', 'monospace'],
        color: color ?? NeuTheme.text(isDark),
      );

  // ------------------------------------------------------------------
  // Ink-free metrics.
  //
  // For text inside a control that supplies its own foreground colour -
  // TextButton, OutlinedButton, ElevatedButton, TabBar. Giving those an
  // explicit colour overrides the control's disabled and hover states, so
  // they take the size and weight of a step and nothing else.

  /// 13/400, no ink. See above.
  static const TextStyle bodyMetrics =
      TextStyle(fontSize: 13, fontWeight: FontWeight.w400);

  /// 12/400, no ink. See above.
  static const TextStyle bodySmMetrics =
      TextStyle(fontSize: 12, fontWeight: FontWeight.w400);

  /// 12/600, no ink. See above.
  static const TextStyle labelMetrics =
      TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

  /// 11/400, no ink. See above.
  static const TextStyle captionMetrics =
      TextStyle(fontSize: 11, fontWeight: FontWeight.w400);

  /// 10/700 with tracking, no ink. See above.
  static const TextStyle microMetrics = TextStyle(
      fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.6);

  /// 11/600, no ink. See above.
  static const TextStyle captionStrongMetrics =
      TextStyle(fontSize: 11, fontWeight: FontWeight.w600);

  static TextStyle _style(double size, FontWeight weight, Color color) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color);

  /// Every weight the scale uses. `w500` is deliberately absent.
  static final Set<FontWeight> weights = {
    FontWeight.w400,
    FontWeight.w600,
    FontWeight.w700,
  };
}
