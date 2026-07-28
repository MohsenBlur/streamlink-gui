import 'package:flutter/material.dart';

class NeuTheme {
  // Master Color Tokens (Extracted directly from reference Neumorphic design)
  static const Color lightBg = Color(0xFFEBECF0);
  static const Color lightSurface = Color(0xFFEBECF0);
  static const Color lightText = Color(0xFF2D3748);
  static const Color lightSubtext = Color(0xFF718096);
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

  // Dynamic Color Token Getters
  static Color background(bool isDark) => isDark ? darkBg : lightBg;
  static Color surface(bool isDark) => isDark ? darkSurface : lightSurface;
  static Color text(bool isDark) => isDark ? darkText : lightText;
  static Color subtext(bool isDark) => isDark ? darkSubtext : lightSubtext;
  static Color disabledText(bool isDark) => isDark ? const Color(0xFF64748B) : const Color(0xFFA0AEC0);
  static Color highlight(bool isDark) => isDark ? darkHighlight : lightHighlight;
  static Color shadow(bool isDark) => isDark ? darkShadow : lightShadow;
  static Color border(bool isDark) => isDark ? const Color(0xFF334155).withOpacity(0.4) : const Color(0xFFA3B1C6).withOpacity(0.5);
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
          color: highlight(isDark).withOpacity(isDark ? 0.5 : 0.9),
          offset: const Offset(-5, -5),
          blurRadius: 10,
        ),
        BoxShadow(
          color: shadow(isDark).withOpacity(isDark ? 0.7 : 0.8),
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
        color: isDark ? Colors.black.withOpacity(0.3) : Colors.black.withOpacity(0.04),
        width: 1.0,
      ),
      boxShadow: [
        BoxShadow(
          color: shadow(isDark).withOpacity(isDark ? 0.6 : 0.6),
          offset: const Offset(3, 3),
          blurRadius: 6,
          spreadRadius: -1,
        ),
        BoxShadow(
          color: highlight(isDark).withOpacity(isDark ? 0.4 : 0.8),
          offset: const Offset(-3, -3),
          blurRadius: 6,
          spreadRadius: -1,
        ),
      ],
    );
  }
}
