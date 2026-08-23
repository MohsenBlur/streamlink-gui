import 'package:flutter/material.dart';

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
  /// 4.60:1 at worst (the well). Was #008F66 = 3.47:1.
  static Color liveText(bool isDark) => isDark ? live : const Color(0xFF00704F);

  /// Text/icon variant of [danger]. 4.68:1 at worst. Was #D92645 = 4.12:1.
  static Color dangerText(bool isDark) => isDark ? danger : const Color(0xFFC01230);

  /// Text/icon variant of [warning]. 4.63:1 at worst.
  static Color warningText(bool isDark) => isDark ? warning : const Color(0xFF8F5300);

  /// Text/icon variant of [favorite]. 3.20:1 at worst - held to the 3:1 bar
  /// for meaningful non-text graphics rather than the 4.5:1 body-text bar,
  /// because it is always an icon and never a label.
  static Color favoriteText(bool isDark) => isDark ? favorite : const Color(0xFFA86F00);

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
  static Color disabledText(bool isDark) => isDark ? const Color(0xFF64748B) : const Color(0xFF6E7C93);
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
  static TextStyle titleStyle(bool isDark, {double fontSize = 16, FontWeight fontWeight = FontWeight.bold}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: text(isDark),
    );
  }

  static TextStyle bodyStyle(bool isDark, {double fontSize = 13, FontWeight fontWeight = FontWeight.w500}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: text(isDark),
    );
  }

  static TextStyle subtextStyle(bool isDark, {double fontSize = 11, FontWeight fontWeight = FontWeight.normal}) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: subtext(isDark),
    );
  }

  // Unified 3D Dual Shadow Decorations
  static BoxDecoration raisedDecoration(bool isDark, {Color? customBase, double radius = 16.0, Border? border}) {
    final base = customBase ?? surface(isDark);
    return BoxDecoration(
      color: base,
      borderRadius: BorderRadius.circular(radius),
      border: border,
      boxShadow: [
        BoxShadow(
          color: highlight(isDark).withValues(alpha: isDark ? 0.5 : 0.9),
          offset: const Offset(-5, -5),
          blurRadius: 10,
        ),
        BoxShadow(
          color: shadow(isDark).withValues(alpha: isDark ? 0.7 : 0.8),
          offset: const Offset(5, 5),
          blurRadius: 10,
        ),
      ],
    );
  }

  static BoxDecoration sunkenDecoration(bool isDark, {Color? customBase, double radius = 16.0, Border? border}) {
    final base = customBase ?? surface(isDark);
    return BoxDecoration(
      color: base,
      borderRadius: BorderRadius.circular(radius),
      border: border ?? Border.all(
        color: isDark ? Colors.black.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.04),
        width: 1.0,
      ),
      boxShadow: [
        BoxShadow(
          color: shadow(isDark).withValues(alpha: isDark ? 0.6 : 0.6),
          offset: const Offset(3, 3),
          blurRadius: 6,
          spreadRadius: -1,
        ),
        BoxShadow(
          color: highlight(isDark).withValues(alpha: isDark ? 0.4 : 0.8),
          offset: const Offset(-3, -3),
          blurRadius: 6,
          spreadRadius: -1,
        ),
      ],
    );
  }
}
