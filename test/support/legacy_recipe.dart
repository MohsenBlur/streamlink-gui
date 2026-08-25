library;

import 'package:flutter/material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// The Soft surface recipe, frozen.
///
/// LIGHT is the v1.6.0 recipe verbatim, untouched since it shipped. DARK was
/// deliberately re-frozen on 2026-08-25, in two steps that are both worth
/// recording. The user first judged the original dark recipe "too flat
/// compared to its light counterpart" - measurably true: its cast landed 8
/// sRGB levels below the canvas where light's lands 40+ below its own,
/// because a dark shadow on a dark canvas has almost no headroom. The first
/// fix deepened the highlight/shadow pair AND added an elevation overlay -
/// and the user's second verdict was just as exact: lightened faces read as
/// "floating panels instead of 3d raised portions of the same slab". The
/// overlay was removed; the deepened pair alone carries the depth, in the
/// casts, where extrusion actually lives. This file freezes that recipe.
/// A deliberate re-freeze moving both sides in lockstep is the one
/// sanctioned kind of change here - never a tidy-up chasing a refactor.
///
/// It has to be a copy. Calling the live API would compare the engine against
/// itself and pass for exactly the wrong reason - the failure mode where a test
/// turns green because it stopped testing anything. Only the colour *tokens*
/// are read live, because those are shared by both sides by design.
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
  final b = base ?? NeuTheme.rawSurface(isDark);
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
          color: NeuTheme.rawHighlight(isDark)
              .withValues(alpha: isDark ? 0.12 : 0.60),
          width: 1.0,
        ),
    boxShadow: depth <= 0
        ? const <BoxShadow>[]
        : [
            BoxShadow(
              color: NeuTheme.rawHighlight(isDark)
                  .withValues(alpha: isDark ? 0.70 : 0.90),
              offset: Offset(-depth, -depth),
              blurRadius: bl,
            ),
            BoxShadow(
              color: NeuTheme.rawShadow(isDark)
                  .withValues(alpha: isDark ? 0.90 : 0.80),
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
  final b = base ?? NeuTheme.rawWellSurface(isDark);
  final bl = blur ?? NeuElevation.blurFor(depth);
  return BoxDecoration(
    color: b,
    shape: circle ? BoxShape.circle : BoxShape.rectangle,
    borderRadius: circle ? null : BorderRadius.circular(radius),
    border: border ??
        Border.all(
          color: const Color(0xFF000000)
              .withValues(alpha: isDark ? 0.45 : 0.045),
          width: 1.0,
        ),
    boxShadow: depth <= 0
        ? const <BoxShadow>[]
        : [
            BoxShadow(
              color: NeuTheme.rawShadow(isDark)
                  .withValues(alpha: isDark ? 0.85 : 0.70),
              offset: Offset(depth, depth),
              blurRadius: bl,
              spreadRadius: -depth / 2,
            ),
            BoxShadow(
              color: NeuTheme.rawHighlight(isDark)
                  .withValues(alpha: isDark ? 0.45 : 0.85),
              offset: Offset(-depth, -depth),
              blurRadius: bl,
              spreadRadius: -depth / 2,
            ),
          ],
  );
}
