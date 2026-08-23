import 'package:flutter/material.dart';

/// The app's motion vocabulary.
///
/// Durations and curves were picked per call site: 150ms, 180ms, 200ms, 220ms
/// and 250ms all appear, and two `AnimatedContainer`s shipped with no curve at
/// all - so they ran `Curves.linear` while every sibling used easeOutCubic.
///
/// Also the one place reduced-motion is honoured. The app had no handling of
/// it anywhere: every animation ran unconditionally, including several
/// continuous loops.
abstract final class NeuMotion {
  /// A press, a checkbox tick - something the user just did. Short enough to
  /// feel like a response rather than a transition.
  static const Duration fast = Duration(milliseconds: 120);

  /// Hover, selection, colour changes. The house default.
  static const Duration normal = Duration(milliseconds: 180);

  /// A thumb sliding, a panel expanding - a change of state with distance.
  static const Duration slow = Duration(milliseconds: 240);

  /// The house curve. Decelerating: fast to start, settling at the end, which
  /// is what a physical control does.
  static const Curve curve = Curves.easeOutCubic;

  /// Whether the user has asked for less motion.
  ///
  /// Windows exposes this as "Show animations in Windows"; Flutter surfaces it
  /// through MediaQuery. Continuous loops in particular must respect it - the
  /// app runs a 1s pulse, a 4s rainbow sweep and per-card LEDs, none of which
  /// could previously be turned off.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [normal], or [Duration.zero] when the user has asked for less motion.
  static Duration duration(BuildContext context, [Duration? value]) =>
      reduced(context) ? Duration.zero : (value ?? normal);
}
