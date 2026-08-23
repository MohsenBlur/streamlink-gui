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
      final transitions = tester.widgetList<FadeTransition>(ledFade());
      for (final t in transitions) {
        expect(t.opacity.value, 1.0,
            reason: 'a stopped LED must settle bright, not at 40% - '
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
