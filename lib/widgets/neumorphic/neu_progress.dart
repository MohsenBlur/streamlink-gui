import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// Bar thickness. The app used 2, 3, 3 and the Material default (4) for the
/// same idea, and rounded two of them but not the others.
enum NeuProgressSize {
  /// 2px — inside the title-bar activity pill, where vertical room is scarce.
  xs,

  /// 3px — list rows: the Library, the activity popover.
  sm,

  /// 4px — the default.
  md,

  /// 6px — a progress bar that is the point of its container.
  lg,
}

extension on NeuProgressSize {
  double get thickness => switch (this) {
        NeuProgressSize.xs => 2,
        NeuProgressSize.sm => 3,
        NeuProgressSize.md => 4,
        NeuProgressSize.lg => 6,
      };

  /// Kept at 2 for every size: the radius reads as "rounded" rather than
  /// scaling with thickness, which is what the two rounded call sites chose.
  double get radius => 2;
}

/// A determinate or indeterminate progress bar.
///
/// Owns the `ClipRRect(borderRadius: circular(2))` that was duplicated verbatim
/// at the call sites that bothered to round it, and the track colour that all
/// of them spelled out as `NeuTheme.border(isDark)`.
///
/// The fill uses the raw accent rather than `accentInk`: this is a filled
/// shape, not a foreground, so its legibility comes from the track behind it.
class NeuProgressBar extends StatelessWidget {
  const NeuProgressBar({
    Key? key,
    this.value,
    this.size = NeuProgressSize.md,
    this.color,
    this.trackColor,
    this.width,
    this.semanticLabel,
  }) : super(key: key);

  /// 0..1, or null for indeterminate.
  final double? value;

  final NeuProgressSize size;
  final Color? color;
  final Color? trackColor;

  /// Fixed width, when the bar sits somewhere unbounded. Prefer letting the
  /// parent constrain it.
  final double? width;

  /// Announced to assistive tech. Without one a bare progress bar tells a
  /// screen reader nothing about what is progressing.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    Widget bar = ClipRRect(
      borderRadius: BorderRadius.circular(size.radius),
      child: LinearProgressIndicator(
        value: value,
        minHeight: size.thickness,
        backgroundColor: trackColor ?? NeuTheme.border(isDark),
        valueColor: AlwaysStoppedAnimation<Color>(
          color ?? Theme.of(context).primaryColor,
        ),
      ),
    );

    if (width != null) bar = SizedBox(width: width, child: bar);

    if (semanticLabel != null) {
      bar = Semantics(
        label: semanticLabel,
        value: value == null ? null : '${(value! * 100).round()}%',
        child: ExcludeSemantics(child: bar),
      );
    }
    return bar;
  }
}

/// Circular counterpart, for the "working…" spinners.
enum NeuProgressRingSize { xs, sm, md, lg }

extension on NeuProgressRingSize {
  double get extent => switch (this) {
        NeuProgressRingSize.xs => 12,
        NeuProgressRingSize.sm => 16,
        NeuProgressRingSize.md => 20,
        NeuProgressRingSize.lg => 28,
      };

  /// Stroke tracks the diameter instead of the four hand-picked values
  /// (1.5, 1.8, 2, 2) that were in use.
  double get stroke => switch (this) {
        NeuProgressRingSize.xs => 1.5,
        NeuProgressRingSize.sm => 2,
        NeuProgressRingSize.md => 2.5,
        NeuProgressRingSize.lg => 3,
      };
}

class NeuProgressRing extends StatelessWidget {
  const NeuProgressRing({
    Key? key,
    this.value,
    this.size = NeuProgressRingSize.md,
    this.color,
    this.semanticLabel,
  }) : super(key: key);

  final double? value;
  final NeuProgressRingSize size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    Widget ring = SizedBox(
      width: size.extent,
      height: size.extent,
      child: CircularProgressIndicator(
        value: value,
        strokeWidth: size.stroke,
        color: color ?? Theme.of(context).primaryColor,
      ),
    );

    if (semanticLabel != null) {
      ring = Semantics(
        label: semanticLabel,
        child: ExcludeSemantics(child: ring),
      );
    }
    return ring;
  }
}
