import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';

enum NeuStyle {
  raised,
  sunken,
  flat,
  well, // Button inside recessed socket
}

/// The base neumorphic surface.
///
/// Reads its palette from [NeuTheme] so every widget built on it shares one
/// source of truth. It previously hardcoded its own highlight/shadow/well
/// colors, which had silently diverged from the tokens the rest of the app
/// used.
class NeuContainer extends StatelessWidget {
  final Widget? child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius? borderRadius;
  final NeuStyle style;
  final Color? color;
  final Color? highlightColor;
  final Color? shadowColor;
  final double depth;
  final double blurRadius;
  final bool isCircle;
  final Gradient? gradient;
  final Border? border;

  const NeuContainer({
    Key? key,
    this.child,
    this.width,
    this.height,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.borderRadius,
    this.style = NeuStyle.raised,
    this.color,
    this.highlightColor,
    this.shadowColor,
    this.depth = 6.0,
    this.blurRadius = 12.0,
    this.isCircle = false,
    this.gradient,
    this.border,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final baseColor = color ?? theme.cardColor;

    // Light source from Top-Left (-1, -1). Same recipe as
    // NeuTheme.raisedDecoration so surfaces built from either path match.
    final defaultHighlight = highlightColor ??
        NeuTheme.highlight(isDark).withValues(alpha: isDark ? 0.5 : 0.9);
    final defaultShadow = shadowColor ??
        NeuTheme.shadow(isDark).withValues(alpha: isDark ? 0.7 : 0.8);

    final effectiveRadius = isCircle
        ? null
        : (borderRadius ?? BorderRadius.circular(16));

    Decoration decoration;

    if (style == NeuStyle.sunken) {
      // Inset / Sunken style simulation
      decoration = BoxDecoration(
        color: baseColor,
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: effectiveRadius,
        border: border ??
            Border.all(
              color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.05),
              width: 1.0,
            ),
        boxShadow: [
          // Top-Left inner shadow effect (simulated via dark outer border and subtle inset glow)
          BoxShadow(
            color: defaultShadow,
            offset: Offset(depth / 2, depth / 2),
            blurRadius: blurRadius / 2,
            spreadRadius: -depth / 2,
          ),
          BoxShadow(
            color: defaultHighlight,
            offset: Offset(-depth / 2, -depth / 2),
            blurRadius: blurRadius / 2,
            spreadRadius: -depth / 2,
          ),
        ],
      );
    } else if (style == NeuStyle.well) {
      // Double-layered well (Recessed socket)
      decoration = BoxDecoration(
        color: color ?? NeuTheme.wellSurface(isDark),
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: effectiveRadius,
        border: border,
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.7)
                : NeuTheme.shadow(isDark).withValues(alpha: 0.9),
            offset: const Offset(2, 2),
            blurRadius: 4,
            spreadRadius: 0,
          ),
          BoxShadow(
            color: NeuTheme.highlight(isDark)
                .withValues(alpha: isDark ? 0.05 : 0.9),
            offset: const Offset(-2, -2),
            blurRadius: 4,
            spreadRadius: 0,
          ),
        ],
      );
    } else if (style == NeuStyle.flat) {
      decoration = BoxDecoration(
        color: baseColor,
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: effectiveRadius,
        border: border,
      );
    } else {
      // Raised Convex / Soft Extrusion style
      final effectiveGradient = gradient ??
          LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              baseColor,
              _adjustColor(baseColor, isDark ? -10 : -8),
            ],
          );

      decoration = BoxDecoration(
        gradient: effectiveGradient,
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: effectiveRadius,
        border: border ??
            Border.all(
              color: NeuTheme.highlight(isDark)
                  .withValues(alpha: isDark ? 0.06 : 0.6),
              width: 1.0,
            ),
        boxShadow: [
          BoxShadow(
            color: defaultHighlight,
            offset: Offset(-depth, -depth),
            blurRadius: blurRadius,
            spreadRadius: 0,
          ),
          BoxShadow(
            color: defaultShadow,
            offset: Offset(depth, depth),
            blurRadius: blurRadius,
            spreadRadius: 0,
          ),
        ],
      );
    }

    return Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding,
      decoration: decoration,
      child: child,
    );
  }

  static Color _adjustColor(Color color, int amount) {
    final argb = color.toARGB32();
    final a = (argb >> 24) & 0xFF;
    final r = (((argb >> 16) & 0xFF) + amount).clamp(0, 255);
    final g = (((argb >> 8) & 0xFF) + amount).clamp(0, 255);
    final b = ((argb & 0xFF) + amount).clamp(0, 255);
    return Color.fromARGB(a, r, g, b);
  }
}
