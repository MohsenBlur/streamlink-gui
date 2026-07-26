import 'package:flutter/material.dart';

enum NeuStyle {
  raised,
  sunken,
  flat,
  well, // Button inside recessed socket
}

class NeuContainer extends StatelessWidget {
  final Widget? child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius? borderRadius;
  final ShapeBorder? shape;
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
    this.shape,
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
    
    // Light source from Top-Left (-1, -1)
    final defaultHighlight = highlightColor ?? 
        (isDark ? Colors.white.withOpacity(0.08) : Colors.white.withOpacity(0.9));
    final defaultShadow = shadowColor ?? 
        (isDark ? const Color(0xFF0D0E12) : const Color(0xFFA3B1C6).withOpacity(0.8));

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
        border: border ?? Border.all(
          color: isDark ? Colors.black.withOpacity(0.4) : Colors.black.withOpacity(0.05),
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
        color: isDark ? const Color(0xFF13151A) : const Color(0xFFD1D9E6),
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: effectiveRadius,
        boxShadow: [
          BoxShadow(
            color: isDark ? Colors.black.withOpacity(0.7) : const Color(0xFFA3B1C6).withOpacity(0.9),
            offset: const Offset(2, 2),
            blurRadius: 4,
            spreadRadius: 0,
          ),
          BoxShadow(
            color: isDark ? Colors.white.withOpacity(0.05) : Colors.white.withOpacity(0.9),
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
      final effectiveGradient = gradient ?? LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          baseColor.withOpacity(isDark ? 1.0 : 1.0),
          _adjustColor(baseColor, isDark ? -10 : -8),
        ],
      );

      decoration = BoxDecoration(
        gradient: effectiveGradient,
        shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: effectiveRadius,
        border: border ?? Border.all(
          color: isDark ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.6),
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
    final r = (color.red + amount).clamp(0, 255);
    final g = (color.green + amount).clamp(0, 255);
    final b = (color.blue + amount).clamp(0, 255);
    return Color.fromARGB(color.alpha, r, g, b);
  }
}
