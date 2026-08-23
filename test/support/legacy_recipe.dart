library;

import 'package:flutter/material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// The v1.6.0 surface recipe, frozen.
///
/// A verbatim copy of `NeuTheme.raised()` and `NeuTheme.sunken()` as they stood
/// before either was re-pointed at the material engine.
///
/// It has to be a copy. Calling the live API would compare the engine against
/// itself and pass for exactly the wrong reason - the failure mode where a test
/// turns green because it stopped testing anything. Only the colour *tokens*
/// are read live, because those are shared by both sides by design.
///
/// **Nothing here may be tidied to match a later refactor.** Its whole value is
/// being stale. If a change makes this file look wrong, the change is what
/// needs explaining.
BoxDecoration legacyRaised(
  bool isDark, {
  Color? base,
  double radius = NeuRadius.r12,
  double depth = NeuElevation.d3,
  double? blur,
  Border? border,
  Gradient? gradient,
  bool circle = false,
}) {
  final b = base ?? NeuTheme.surface(isDark);
  final bl = blur ?? NeuElevation.blurFor(depth);
  return BoxDecoration(
    gradient: gradient ??
        LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [b, NeuTheme.fillFloor(b)],
        ),
    shape: circle ? BoxShape.circle : BoxShape.rectangle,
    borderRadius: circle ? null : BorderRadius.circular(radius),
    border: border ??
        Border.all(
          color: NeuTheme.highlight(isDark)
              .withValues(alpha: isDark ? 0.06 : 0.60),
          width: 1.0,
        ),
    boxShadow: depth <= 0
        ? const <BoxShadow>[]
        : [
            BoxShadow(
              color: NeuTheme.highlight(isDark)
                  .withValues(alpha: isDark ? 0.50 : 0.90),
              offset: Offset(-depth, -depth),
              blurRadius: bl,
            ),
            BoxShadow(
              color: NeuTheme.shadow(isDark)
                  .withValues(alpha: isDark ? 0.70 : 0.80),
              offset: Offset(depth, depth),
              blurRadius: bl,
            ),
          ],
  );
}

BoxDecoration legacySunken(
  bool isDark, {
  Color? base,
  double radius = NeuRadius.r12,
  double depth = NeuElevation.d2,
  double? blur,
  Border? border,
  bool circle = false,
}) {
  final b = base ?? NeuTheme.wellSurface(isDark);
  final bl = blur ?? NeuElevation.blurFor(depth);
  return BoxDecoration(
    color: b,
    shape: circle ? BoxShape.circle : BoxShape.rectangle,
    borderRadius: circle ? null : BorderRadius.circular(radius),
    border: border ??
        Border.all(
          color: const Color(0xFF000000)
              .withValues(alpha: isDark ? 0.35 : 0.045),
          width: 1.0,
        ),
    boxShadow: depth <= 0
        ? const <BoxShadow>[]
        : [
            BoxShadow(
              color: NeuTheme.shadow(isDark)
                  .withValues(alpha: isDark ? 0.65 : 0.70),
              offset: Offset(depth, depth),
              blurRadius: bl,
              spreadRadius: -depth / 2,
            ),
            BoxShadow(
              color: NeuTheme.highlight(isDark)
                  .withValues(alpha: isDark ? 0.35 : 0.85),
              offset: Offset(-depth, -depth),
              blurRadius: bl,
              spreadRadius: -depth / 2,
            ),
          ],
  );
}
