import 'package:flutter/material.dart';

import 'neu_theme.dart';

/// The neumorphic look for the Material controls the app keeps.
///
/// Material [Slider] stays (it provides divisions, labels, semantics and
/// keyboard support a hand-rolled control would have to rebuild), but its
/// styling was copy-pasted at six call sites. This is the single definition.
SliderThemeData neuSliderTheme(BuildContext context, {Color? accent}) {
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  final color = accent ?? theme.primaryColor;
  return SliderTheme.of(context).copyWith(
    trackHeight: 2,
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
    activeTrackColor: color,
    inactiveTrackColor: NeuTheme.border(isDark),
    thumbColor: color,
    overlayColor: color.withValues(alpha: 0.12),
  );
}
