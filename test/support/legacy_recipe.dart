library;

import 'package:flutter/material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// The Soft surface recipe, frozen.
///
/// LIGHT is the v1.6.0 recipe verbatim, untouched since it shipped. DARK was
/// deliberately re-frozen on 2026-08-25: the user judged the original dark
/// recipe "too flat compared to its light counterpart", and it measurably
/// was - its cast landed 8 sRGB levels below the canvas where the light
/// theme's lands 40+ below its own, because a dark shadow on a dark canvas
/// has almost no contrast headroom. The dark redesign deepens the
/// highlight/shadow pair, raises the cast alphas, and adds an elevation
/// overlay (raised faces lighten with depth - the same mechanism Rack dark
/// uses), so this file now freezes THAT recipe. This is the one sanctioned
/// kind of change here: a deliberate re-freeze moving both sides in lockstep,
/// never a tidy-up chasing a refactor.
///
/// It has to be a copy. Calling the live API would compare the engine against
/// itself and pass for exactly the wrong reason - the failure mode where a test
/// turns green because it stopped testing anything. Only the colour *tokens*
/// are read live, because those are shared by both sides by design.

/// The engine lifts every dark ground by the elevation overlay before the
/// gradient sees it. Mirrors `MaterialPalette.overlayFor` over Soft dark's
/// declared map - by value, because reading the live palette here would be
/// the self-comparison this file exists to avoid.
Color _darkOverlaid(Color base, double depth) {
  // Int keys: a const map with double keys fails const evaluation - the
  // exact trap the engine's own elevationOverlay hit and documented.
  const map = <int, double>{2: 0.045, 3: 0.06, 5: 0.085, 8: 0.11, 12: 0.13};
  if (depth <= 0) return base;
  final keys = map.keys.toList()..sort();
  double a;
  if (depth <= keys.first) {
    a = map[keys.first]!;
  } else if (depth >= keys.last) {
    a = map[keys.last]!;
  } else {
    a = map[keys.last]!;
    for (var i = 1; i < keys.length; i++) {
      if (depth <= keys[i]) {
        final t = (depth - keys[i - 1]) / (keys[i] - keys[i - 1]);
        a = map[keys[i - 1]]! + (map[keys[i]]! - map[keys[i - 1]]!) * t;
        break;
      }
    }
  }
  return Color.alphaBlend(
      const Color(0xFFFFFFFF).withValues(alpha: a), base);
}
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
  final b0 = base ?? NeuTheme.rawSurface(isDark);
  final b = isDark ? _darkOverlaid(b0, depth) : b0;
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
                  .withValues(alpha: isDark ? 0.60 : 0.90),
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
  final b0 = base ?? NeuTheme.rawWellSurface(isDark);
  final b = isDark ? _darkOverlaid(b0, depth) : b0;
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
