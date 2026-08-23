import 'package:flutter/material.dart';

import 'material/app_material.dart';
import 'material/skeuo_decoration.dart';

export 'neu_tokens.dart';
export 'neu_type.dart';

import 'neu_tokens.dart';

class NeuTheme {
  // Master Color Tokens (Extracted directly from reference Neumorphic design)

  /// The page behind the surfaces.
  ///
  /// Deliberately NOT the same as [lightSurface]. They used to be the same hex,
  /// so light mode had zero surface separation (1.000:1) and every raised card
  /// relied entirely on its shadow to be seen at all.
  ///
  /// The canvas is darkened rather than the surface lightened, which matters:
  /// [lightHighlight] is pure white, so a lighter surface would swallow the
  /// top-left bevel and kill the extrusion the whole look depends on. Moving
  /// the canvas instead gives 1.079:1 - mirroring dark's 1.068:1 - while every
  /// existing raised element renders exactly as before.
  static const Color lightBg = Color(0xFFE1E4EA);
  static const Color lightSurface = Color(0xFFEBECF0);
  static const Color lightText = Color(0xFF2D3748);

  /// 5.11:1 on the canvas, 4.89:1 on the well.
  ///
  /// Was #718096, which measured 3.40:1 - below WCAG AA - while being the
  /// default ink of [subtextStyle] at 11px, the most-used size in the app.
  static const Color lightSubtext = Color(0xFF4F5F75);
  static const Color lightHighlight = Color(0xFFFFFFFF);
  static const Color lightShadow = Color(0xFFA3B1C6);
  static const Color defaultLightAccent = Color(0xFFFF6584); // Soft Pink

  static const Color darkBg = Color(0xFF1D212A);
  static const Color darkSurface = Color(0xFF222632);
  static const Color darkText = Color(0xFFE2E8F0);
  static const Color darkSubtext = Color(0xFF94A3B8);
  static const Color darkHighlight = Color(0xFF2B303F);
  static const Color darkShadow = Color(0xFF12151B);
  static const Color defaultDarkAccent = Color(0xFFFF3B30); // Vibrant Red

  // Semantic status colors, previously scattered as inline hexes across the
  // LED indicator, card border and title bar.
  static const Color live = Color(0xFF00E6A5);
  static const Color danger = Color(0xFFFF4565);

  /// Caution / degraded state. Previously re-invented per file as
  /// `Colors.orangeAccent` / `Colors.orange.shade800` at seven sites across
  /// five files - and that idiom measured 2.61:1 in light mode.
  static const Color warning = Color(0xFFFFB020);

  /// "This is favourited" - a distinct semantic from [warning], though both
  /// land in the amber family. Previously a bare `Colors.amber` with no
  /// light/dark branch at all, measuring 1.28:1 on the light canvas.
  static const Color favorite = Color(0xFFFFC24B);

  /// Text/icon variant of [live]: the base mint washes out on light grounds.
  /// 4.55:1 against the fill floor. Was #00704F, which measured 4.60:1 against
  /// the flat well but only 4.25:1 against the well's gradient floor.
  static Color liveText(bool isDark) => isDark ? live : const Color(0xFF006B4B);

  /// Text/icon variant of [danger]. 4.50:1 against the fill floor. Was
  /// #C01230, which measured 4.68:1 flat but 4.33:1 against the floor.
  static Color dangerText(bool isDark) => isDark ? danger : const Color(0xFFBB122F);

  /// Text/icon variant of [warning]. 4.52:1 against the fill floor. Was
  /// #8F5300, which measured 4.63:1 flat but 4.28:1 against the floor.
  static Color warningText(bool isDark) => isDark ? warning : const Color(0xFF8A5000);

  /// Text/icon variant of [favorite]. 3.20:1 at worst - held to the 3:1 bar
  /// for meaningful non-text graphics rather than the 4.5:1 body-text bar,
  /// because it is always an icon and never a label.
  static Color favoriteText(bool isDark) => isDark ? favorite : const Color(0xFFA56D00);

  /// Ink for content rendered ON an accent fill.
  ///
  /// Picks whichever of white or [_onAccentInk] contrasts better, rather than
  /// asking whether the accent is "dark". `estimateBrightnessForColor` answers
  /// that question against a threshold equivalent to about 3.06:1, so it
  /// returned white for five of the eleven shipped accents where white
  /// measures below AA - Soft Pink 2.82, Magenta 3.55, Vibrant Red 3.55,
  /// Rose 3.67, Electric Purple 4.23. All eleven now pass, worst case 4.59.
  static Color onAccent(Color accent) =>
      contrastRatio(Colors.white, accent) >= contrastRatio(_onAccentInk, accent)
          ? Colors.white
          : _onAccentInk;

  /// Deeper than the previous #1A202C, which bought roughly 1.2x more contrast
  /// on every accent that resolves to dark ink.
  static const Color _onAccentInk = Color(0xFF0B0D12);

  /// Foreground-safe variant of [accent], for content drawn *in* the accent
  /// colour on an ordinary surface — text, icons, focus rings, thin strokes.
  ///
  /// [onAccent] solves the opposite problem (ink *on* an accent fill) and does
  /// not help here. Used raw as a foreground, the shipped accents measure as
  /// little as 1.09:1 on the light canvas (Cyan), and even the default Soft
  /// Pink manages only 2.21:1 — so accent-coloured labels and the keyboard
  /// focus ring were effectively invisible in light mode.
  ///
  /// The value is derived rather than the palette being restricted, for three
  /// reasons: restricting deletes user choice, it would invalidate accents
  /// already saved, and it would not even close the hole, since the hex is a
  /// hand-editable string in channels_config.json and the picker is not the
  /// only way a value arrives. Derivation is total — **the stored accent is
  /// never rewritten**, it is only adjusted at render time, so fills, tints
  /// and glows keep the exact colour the user chose.
  ///
  /// Resolved against the *lowest-contrast* ground in the theme (the well in
  /// light mode, the surface in dark), so one value is safe on all of them.
  ///
  /// Cost is a short loop, so callers should cache — see
  /// `AppThemeNotifier.accentInk`.
  static Color accentInk(Color accent, bool isDark) {
    // The worst ground, not the worst *token*. Light ink on a dark theme is
    // hurt by the LIGHTEST ground, and a fill only ever darkens, so dark mode's
    // worst case is the flat surface. Dark ink on a light theme is hurt by the
    // DARKEST ground, which is the well's gradient floor - a fill floor this
    // derivation used to ignore, leaving Soft Pink at 4.38:1 there while
    // reporting it clear.
    final ground = isDark ? darkSurface : fillFloor(wellSurface(false));
    if (contrastRatio(accent, ground) >= _inkTarget) return accent;

    final hsl = HSLColor.fromColor(accent);
    // Darkening desaturates perceptually, so nudge saturation up in light mode
    // to keep the hue recognisable as the colour the user picked.
    final saturation =
        isDark ? hsl.saturation : (hsl.saturation * 1.10).clamp(0.0, 1.0);

    for (var i = 1; i <= 200; i++) {
      final lightness = isDark
          ? (hsl.lightness + i * 0.005).clamp(0.0, 0.97)
          : (hsl.lightness - i * 0.005).clamp(0.03, 1.0);
      final candidate =
          hsl.withSaturation(saturation).withLightness(lightness).toColor();
      if (contrastRatio(candidate, ground) >= _inkTarget) return candidate;
    }
    // A fully achromatic accent can run out of headroom before clearing the
    // bar; fall back to the plain text ink rather than returning something
    // unreadable.
    return text(isDark);
  }

  static const double _inkTarget = 4.5;

  /// WCAG 2.x relative-contrast ratio between two opaque colors.
  ///
  /// `Color.computeLuminance()` already implements the sRGB-linearised
  /// relative luminance the formula calls for.
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Recessed "well" surface (track slots, sockets, sunken fields).
  ///
  /// Canonicalized on the value most widgets already used; NeuContainer's
  /// slightly different light well was the outlier.
  static Color wellSurface(bool isDark) =>
      isDark ? const Color(0xFF13151A) : const Color(0xFFD8E0EB);

  /// Keyboard-focus visual consistent with the neumorphic style: an accent
  /// border with a soft outer glow, readable on both themes' low-contrast
  /// surfaces.
  static BoxDecoration focusRing(bool isDark, Color accent, {double radius = 16}) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: accent, width: 2),
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: 0.35),
          blurRadius: 6,
          spreadRadius: 1,
        ),
      ],
    );
  }

  // Dynamic Color Token Getters

  /// The page behind everything. [background] is kept as an alias so the ~30
  /// existing call sites need no edit.
  static Color canvas(bool isDark) => isDark ? darkBg : lightBg;
  static Color background(bool isDark) => canvas(isDark);
  static Color surface(bool isDark) => isDark ? darkSurface : lightSurface;
  static Color text(bool isDark) => isDark ? darkText : lightText;
  static Color subtext(bool isDark) => isDark ? darkSubtext : lightSubtext;

  /// 3.18:1 at worst in light mode, held to the 3:1 non-text bar.
  ///
  /// Was #A0AEC0 = 1.91:1, which NeuButton then multiplied by `Opacity(0.45)`.
  /// This value is calibrated to be exactly as dim as it should be, so nothing
  /// may dim it further - the disabled affordance is carried by the flat
  /// (shadowless) treatment and the cursor, not by fading the label away.
  static Color disabledText(bool isDark) =>
      isDark ? const Color(0xFF64748B) : const Color(0xFF6C7A91);
  static Color highlight(bool isDark) => isDark ? darkHighlight : lightHighlight;
  static Color shadow(bool isDark) => isDark ? darkShadow : lightShadow;

  /// Component boundaries: 2.19:1 light (was 1.33), 1.74:1 dark (was 1.15).
  ///
  /// Deliberately short of WCAG 1.4.11's 3:1. Reaching it needs a hard
  /// hairline that destroys the soft-material read this app is built on, so
  /// the boundary is strengthened as far as the style allows and the burden of
  /// meeting the standard is carried by the focus ring instead, which is held
  /// to >= 4.5:1.
  static Color border(bool isDark) => isDark
      ? const Color(0xFF49566B).withValues(alpha: 0.8)
      : const Color(0xFF8494AD).withValues(alpha: 0.9);
  static Color terminalBg(bool isDark) => isDark ? const Color(0xFF0F131E) : const Color(0xFFF8FAFC);

  // Unified Typography Tokens
  // titleStyle / bodyStyle / subtextStyle lived here. Each took an overridable
  // fontSize and EVERY call site overrode it, so they unified colour and
  // nothing else - 17 distinct sizes across 271 sites. NeuType replaces them
  // with named steps; see neu_type.dart.

  // ---------------------------------------------------------------------
  // The one neumorphic recipe.
  //
  // There were two, and they did not match. This flat token painted a solid
  // colour with hardcoded +/-5 offsets and no depth parameter; NeuContainer
  // painted a top-left gradient with depth-driven offsets and a highlight
  // border. A comment in neu_container.dart claimed they were "the same
  // recipe" - they differed on three of five properties, so two adjacent
  // raised surfaces built through different paths visibly disagreed.
  //
  // The gradient recipe wins, for three reasons: only it can express state
  // (NeuButton already drives depth on press and hover, and the flat one has
  // no depth parameter at all, so 36 surfaces were frozen at one elevation);
  // the gradient IS the neumorphism, since a flat rectangle with two drop
  // shadows reads as a card WITH a shadow rather than material extruded from
  // the surface; and the flat version is a strict subset of it.
  // ---------------------------------------------------------------------

  /// Shifts a colour's HSL lightness.
  ///
  /// Replaces a flat per-channel RGB offset, which is not perceptually
  /// uniform, clips at 0, and misbehaved on the translucent bases NeuButton
  /// passes for its selected state. On the dark well the old offset landed
  /// near-black; this stays proportional.
  /// How far a raised fill's gradient darkens from its base, in HSL lightness.
  ///
  /// Public because it is not a private styling detail: it is the difference
  /// between the colour a token declares and the colour text actually lands
  /// on, and WCAG F83 judges contrast against the latter.
  static const double fillSpread = 0.030;

  /// The darkest point a raised fill reaches - the real ground under text.
  ///
  /// A gradient means an ink sits on a *range* of colours, and F83's rule is
  /// the worst pixel behind the letter, not the declared base. Checking the
  /// base alone hid seven genuine failures in the light theme: liveText,
  /// dangerText, warningText, disabledText and favoriteText all cleared their
  /// bar against the flat token and missed it by 0.05-0.25 against the floor.
  static Color fillFloor(Color base) => _shade(base, -fillSpread);

  static Color _shade(Color base, double delta) {
    final hsl = HSLColor.fromColor(base);
    return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
  }

  /// The palette the engine paints from.
  ///
  /// `material` defaults to the active one. It is not a convenience: the
  /// Settings picker previews a material that is *not* active, the contrast
  /// matrix iterates all of them, and widget tests call these with a literal
  /// `isDark` and no notifier configured. Global-only dispatch forbids all
  /// three.
  static MaterialPalette palette(bool isDark, {AppMaterial? material}) =>
      MaterialSpec.of(material ?? activeMaterial).palette(isDark);

  /// Which material the app is wearing.
  ///
  /// A plain static rather than a read through the notifier, so `neu_theme`
  /// does not depend on the widget layer. `AppThemeNotifier.setMaterial`
  /// assigns it, in the same call that invalidates the derived-colour cache.
  static AppMaterial activeMaterial = AppMaterial.soft;

  /// A surface extruded from the page.
  ///
  /// Returns a `Decoration`, not a `BoxDecoration`: a material needs seven
  /// paint layers including a true inset shadow, and `BoxDecoration` can carry
  /// two. Every call site assigns into a `decoration:` or
  /// `foregroundDecoration:` slot that already accepts the wider type.
  static Decoration raised(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d3,
    double? blur,
    Border? border,
    Gradient? gradient,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.raised,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
        gradient: gradient,
        blur: blur,
      );

  /// A surface recessed into the page.
  ///
  /// The base defaults to [wellSurface], not [surface]. A sunken thing is a
  /// well; defaulting to the surface colour meant NeuSwitch's off-track was
  /// the exact colour of the panel behind it, so **the off state was invisible
  /// in light mode**. That default now lives in the role table, which routes
  /// `sunken` to `Ground.well`.
  static Decoration sunken(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d2,
    double? blur,
    Border? border,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.sunken,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
        blur: blur,
      );

  /// A faceplate: textured, bevelled, lightly shadowed.
  static Decoration panel(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d2,
    Border? border,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.panel,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
      );

  /// Inset glass — a display set into a bezel.
  static Decoration screen(
    bool isDark, {
    Color? base,
    double radius = NeuRadius.r12,
    double depth = NeuElevation.d2,
    Border? border,
    bool circle = false,
    AppMaterial? material,
  }) =>
      SkeuoDecoration.role(
        palette: palette(isDark, material: material),
        role: SurfaceRole.screen,
        depth: depth,
        radius: radius,
        circle: circle,
        base: base,
        border: border,
      );

  /// Kept so the ~36 existing call sites need no edit. They silently gain the
  /// gradient and a depth parameter.
  static Decoration raisedDecoration(bool isDark,
          {Color? customBase, double radius = NeuRadius.r12, Border? border}) =>
      raised(isDark, base: customBase, radius: radius, border: border);

  /// Kept for the same reason. Note the base default change documented on
  /// [sunken]: call sites that want the panel colour must now say so.
  static Decoration sunkenDecoration(bool isDark,
          {Color? customBase, double radius = NeuRadius.r12, Border? border}) =>
      sunken(isDark, base: customBase, radius: radius, border: border);
}
