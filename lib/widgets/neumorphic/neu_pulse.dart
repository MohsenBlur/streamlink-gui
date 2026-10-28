import 'package:flutter/widgets.dart';

/// The app's one "this is live" heartbeat, handed down the tree.
///
/// Every pulse in the app means the same thing, so they must breathe
/// together: independent controllers drift out of phase, and a screen of live
/// indicators shimmers instead of breathing. The shell already runs exactly one
/// such controller, gated on something being live, the window being visible
/// and reduced motion being off - but it reached only the widgets it was
/// passed to by hand. `NeuLedIndicator` was not one of them, so every pulsing
/// LED ran a 1.2s controller of its own, out of phase with the badge beside it
/// and outside the visibility gate.
///
/// Wrapping the shell in this lets any pulsing indicator below it share the
/// heartbeat without the call sites between learning about it.
class NeuPulse extends InheritedWidget {
  const NeuPulse({
    super.key,
    required this.pulse,
    required super.child,
  });

  /// Runs 0..1 and back while something is live; settles at 1.0 when it
  /// stops, so a parked indicator sits at full brightness.
  final Animation<double> pulse;

  /// The nearest heartbeat, or null outside one (a dialog test, a preview
  /// tool), in which case an indicator keeps its own.
  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NeuPulse>()?.pulse;

  @override
  bool updateShouldNotify(NeuPulse oldWidget) =>
      !identical(oldWidget.pulse, pulse);
}
