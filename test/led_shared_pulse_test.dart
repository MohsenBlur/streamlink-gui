import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_led_indicator.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_pulse.dart';

/// The LED breathes with the app's one heartbeat instead of a controller of
/// its own.
///
/// Every pulsing LED used to run a private 1.2s `repeat()`: out of phase with
/// the shell's 1s pulse and with every other LED (a dashboard LED and the
/// avatar LED beside it, mounted at different moments, never lined up), and
/// outside the shell's gate - something live, window visible, motion allowed.
/// The LED outside any heartbeat (a dialog, a preview tool) keeps its own, and
/// the existing LED tests in `motion_test` and `neu_controls_test` hold that
/// path; this file holds the shared one.
void main() {
  Widget host(Widget child,
      {Animation<double>? pulse, bool reduceMotion = false}) {
    Widget body = Scaffold(body: Center(child: child));
    if (pulse != null) body = NeuPulse(pulse: pulse, child: body);
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: body,
      ),
    );
  }

  // Scoped to the LED's own subtree: MaterialApp's route transitions are
  // FadeTransitions too.
  FadeTransition fadeOf(WidgetTester tester, [Key? led]) =>
      tester.widget<FadeTransition>(find.descendant(
        of: led == null ? find.byType(NeuLedIndicator) : find.byKey(led),
        matching: find.byType(FadeTransition),
      ));

  AnimationController heartbeat(WidgetTester tester) {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 1000),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  testWidgets('under a parked heartbeat an LED sits bright and ticks nothing '
      'of its own', (tester) async {
    // Parked exactly as the shell parks it when nothing is live or the window
    // is hidden: stopped at 1.0.
    final pulse = heartbeat(tester)..value = 1.0;
    await tester.pumpWidget(
        host(const NeuLedIndicator(isLive: true), pulse: pulse));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.binding.transientCallbackCount, 0,
        reason: 'the LED is animating a controller of its own while the '
            "app's heartbeat is parked - a frame every vsync that the shell's "
            'gate exists to prevent');
    expect(fadeOf(tester).opacity.value, 1.0,
        reason: 'a parked heartbeat must leave the lamp at full brightness');
  });

  testWidgets('the LED follows the shared heartbeat through its own breath',
      (tester) async {
    final pulse = heartbeat(tester);
    await tester.pumpWidget(
        host(const NeuLedIndicator(isLive: true), pulse: pulse));

    for (final t in [0.0, 0.25, 0.5, 1.0]) {
      pulse.value = t;
      await tester.pump();
      expect(
          fadeOf(tester).opacity.value,
          closeTo(
              NeuLedIndicator.pulseFloor +
                  (1 - NeuLedIndicator.pulseFloor) *
                      Curves.easeInOut.transform(t),
              1e-9),
          reason: 'at heartbeat $t the LED is not on the shared breath');
    }
    expect(fadeOf(tester).opacity.value, 1.0);
  });

  testWidgets('LEDs mounted at different moments breathe in phase',
      (tester) async {
    // The defect a private controller cannot avoid: each one starts its
    // cycle when its LED mounts, so a second LED appearing 300ms after the
    // first stays 300ms out of phase for as long as both are on screen.
    final pulse = heartbeat(tester)..repeat(reverse: true);
    const first = ValueKey('first');
    const second = ValueKey('second');

    await tester.pumpWidget(host(
        const Column(mainAxisSize: MainAxisSize.min, children: [
          NeuLedIndicator(key: first, isLive: true),
        ]),
        pulse: pulse));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(host(
        const Column(mainAxisSize: MainAxisSize.min, children: [
          NeuLedIndicator(key: first, isLive: true),
          NeuLedIndicator(key: second, isLive: true),
        ]),
        pulse: pulse));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 70));
      expect(fadeOf(tester, second).opacity.value,
          fadeOf(tester, first).opacity.value,
          reason: 'frame $i: the later LED is out of phase with the first');
    }
    pulse.stop();
  });

  testWidgets('an explicit pulse wins over the inherited one', (tester) async {
    // Mid-breath on purpose: a private controller starts at 0 and the
    // inherited heartbeat is parked at 1, so neither can pass for it.
    final inherited = heartbeat(tester)..value = 1.0;
    final explicit = heartbeat(tester)..value = 0.5;
    await tester.pumpWidget(host(
        NeuLedIndicator(isLive: true, pulse: explicit), pulse: inherited));
    expect(
        fadeOf(tester).opacity.value,
        closeTo(
            NeuLedIndicator.pulseFloor +
                (1 - NeuLedIndicator.pulseFloor) *
                    Curves.easeInOut.transform(0.5),
            1e-9));
  });

  testWidgets('reduced motion builds no transition even under a heartbeat',
      (tester) async {
    final pulse = heartbeat(tester)..value = 0.0;
    await tester.pumpWidget(host(const NeuLedIndicator(isLive: true),
        pulse: pulse, reduceMotion: true));
    expect(
        find.descendant(
            of: find.byType(NeuLedIndicator),
            matching: find.byType(FadeTransition)),
        findsNothing,
        reason: 'a heartbeat stuck at its floor would dim a reduced-motion '
            'LED to 75% permanently');
  });

  testWidgets('an LED that leaves the heartbeat falls back to its own',
      (tester) async {
    final pulse = heartbeat(tester)..value = 1.0;
    await tester.pumpWidget(
        host(const NeuLedIndicator(isLive: true), pulse: pulse));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(host(const NeuLedIndicator(isLive: true)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'outside any heartbeat the LED must still pulse on its own');
    expect(fadeOf(tester).opacity.value, lessThan(1.0));
  });
}
