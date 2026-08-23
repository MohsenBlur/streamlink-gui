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

    final effectiveRadius = isCircle
        ? null
        : (borderRadius ?? BorderRadius.circular(16));

    // One recipe, shared with NeuTheme.raised/sunken. This file used to carry
    // its own divergent copy under a comment claiming they matched.
    final Decoration decoration;
    switch (style) {
      case NeuStyle.sunken:
        decoration = NeuTheme.sunken(
          isDark,
          base: color ?? baseColor,
          radius: effectiveRadius?.topLeft.x ?? NeuRadius.r12,
          depth: depth / 2,
          blur: blurRadius / 2,
          border: border,
          circle: isCircle,
        );
      case NeuStyle.well:
        decoration = NeuTheme.sunken(
          isDark,
          base: color,
          radius: effectiveRadius?.topLeft.x ?? NeuRadius.r12,
          depth: NeuElevation.d1,
          border: border,
          circle: isCircle,
        );
      case NeuStyle.flat:
        decoration = BoxDecoration(
          color: baseColor,
          shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: effectiveRadius,
          border: border,
        );
      case NeuStyle.raised:
        decoration = NeuTheme.raised(
          isDark,
          base: baseColor,
          radius: effectiveRadius?.topLeft.x ?? NeuRadius.r12,
          depth: depth,
          blur: blurRadius,
          border: border,
          gradient: gradient,
          circle: isCircle,
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

}
