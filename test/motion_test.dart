import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_led_indicator.dart';
import 'package:streamlink_gui/widgets/shell/motion.dart';

Widget host(Widget child, {bool reduceMotion = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('NeuMotion', () {
    testWidgets('reports the platform setting', (tester) async {
      late bool seen;
      await tester.pumpWidget(host(
        Builder(builder: (context) {
          seen = NeuMotion.reduced(context);
          return const SizedBox();
        }),
        reduceMotion: true,
      ));
      expect(seen, isTrue);

      await tester.pumpWidget(host(
        Builder(builder: (context) {
          seen = NeuMotion.reduced(context);
          return const SizedBox();
        }),
      ));
      expect(seen, isFalse);
    });

    testWidgets('collapses durations to zero when motion is reduced',
        (tester) async {
      late Duration reduced;
      late Duration normal;
      await tester.pumpWidget(host(
        Builder(builder: (context) {
          reduced = NeuMotion.duration(context);
          return const SizedBox();
        }),
        reduceMotion: true,
      ));
      await tester.pumpWidget(host(
        Builder(builder: (context) {
          normal = NeuMotion.duration(context);
          return const SizedBox();
        }),
      ));
      expect(reduced, Duration.zero);
      expect(normal, NeuMotion.normal);
    });
  });

  group('continuous loops respect reduced motion', () {
    testWidgets('the live LED does not pulse when motion is reduced',
        (tester) async {
      // The app previously honoured this setting nowhere at all: a 1s pulse, a
      // 4s rainbow sweep and per-card LEDs all ran unconditionally.
      Finder ledFade() => find.descendant(
            of: find.byType(NeuLedIndicator),
            matching: find.byType(FadeTransition),
          );

      await tester.pumpWidget(host(
        const NeuLedIndicator(isLive: true),
        reduceMotion: true,
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // The widget still renders; it simply does not animate.
      expect(find.byType(NeuLedIndicator), findsOneWidget);

      // Under reduced motion at FIRST build the animation is never created at
      // all, so there is no FadeTransition. That is the correct behaviour and
      // it is what this half asserts - the `for (final t in transitions)` loop
      // that used to be here iterated zero times and asserted nothing, in a
      // test whose name promised otherwise.
      expect(ledFade(), findsNothing,
          reason: 'reduced motion must not merely stop the pulse, it must not '
              'build the transition at all');
    });

    testWidgets('an LED that had been pulsing settles BRIGHT when motion is '
        'switched off mid-cycle', (tester) async {
      Finder ledFade() => find.descendant(
            of: find.byType(NeuLedIndicator),
            matching: find.byType(FadeTransition),
          );
      // The case the previous version claimed to cover and could not reach:
      // the FadeTransition already exists and is somewhere in its travel when
      // reduced motion arrives. The controller is stopped, and it has to be
      // parked at 1.0 rather than wherever the tween happened to be - a lamp
      // frozen at its floor reads as offline.
      //
      // Mutating `_controller?.value = 1.0` to `0.4` left all 614 tests green
      // before this existed.
      await tester.pumpWidget(host(const NeuLedIndicator(isLive: true)));
      await tester.pump(const Duration(milliseconds: 600));
      expect(ledFade(), findsOneWidget, reason: 'precondition: it was pulsing');

      await tester.pumpWidget(host(
        const NeuLedIndicator(isLive: true),
        reduceMotion: true,
      ));
      await tester.pump(const Duration(milliseconds: 16));

      final still = tester.widgetList<FadeTransition>(ledFade()).toList();
      expect(still, isNotEmpty,
          reason: 'the transition survives the switch, so its value matters');
      for (final t in still) {
        expect(t.opacity.value, 1.0,
            reason: 'a stopped LED must settle bright, not at its floor - '
                'a dimmed dot reads as offline');
      }
    });

    testWidgets('the live LED still pulses normally otherwise', (tester) async {
      await tester.pumpWidget(host(const NeuLedIndicator(isLive: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
          find.descendant(
              of: find.byType(NeuLedIndicator),
              matching: find.byType(FadeTransition)),
          findsOneWidget);
    });
  });
}
