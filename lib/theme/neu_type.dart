import 'package:flutter/material.dart';

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

  /// 12/400 monospace. Log output, file paths, anything column-aligned.
  static TextStyle mono(bool isDark, {Color? color}) => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        fontFamily: 'Consolas',
        fontFamilyFallback: const ['Courier New', 'monospace'],
        color: color ?? NeuTheme.text(isDark),
      );

  static TextStyle _style(double size, FontWeight weight, Color color) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color);

  /// Every weight the scale uses. `w500` is deliberately absent.
  static final Set<FontWeight> weights = {
    FontWeight.w400,
    FontWeight.w600,
    FontWeight.w700,
  };
}
