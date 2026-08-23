import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_button.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_checkbox.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_led_indicator.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_switch.dart';

Widget host(Widget child, {Brightness brightness = Brightness.dark}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('NeuButton', () {
    testWidgets('stays centered while pressed (transformAlignment)', (tester) async {
      // Regression: the scale transform had no transformAlignment, so its
      // origin was the top-left corner and every button drifted down-right on
      // hover and collapsed toward the corner on press.
      await tester.pumpWidget(host(
        NeuButton(onPressed: () {}, child: const Text('Press me')),
      ));

      final before = tester.getCenter(find.byType(NeuButton));

      final gesture = await tester.startGesture(before);
      await tester.pump(const Duration(milliseconds: 200));

      final during = tester.getCenter(find.text('Press me'));
      expect((during - before).distance, lessThan(0.5),
          reason: 'content must scale about its center, not drift');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('disabled button ignores taps and shows no pressed state',
        (tester) async {
      await tester.pumpWidget(host(
        const NeuButton(onPressed: null, child: Text('Disabled')),
      ));

      // Tap must not throw and must not toggle any pressed visuals.
      await tester.tap(find.byType(NeuButton), warnIfMissed: false);
      await tester.pumpAndSettle();

      // Disabled is expressed by the calibrated ink, not by fading the label.
      // This used to assert an Opacity(0.45) wrapper, which stacked on top of
      // an already-dim colour and drove the label under 1.5:1 in light mode.
      final style = tester
          .widget<DefaultTextStyle>(find
              .ancestor(
                  of: find.text('Disabled'),
                  matching: find.byType(DefaultTextStyle))
              .first)
          .style;
      expect(style.color, isNotNull);
      expect(style.color, isNot(NeuTheme.text(true)));
      expect(find.byType(Opacity), findsNothing,
          reason: 'disabled must not be dimmed on top of disabledText');
    });

    testWidgets('a disabled label stays legible on both themes', (tester) async {
      for (final isDark in [false, true]) {
        final ratio = NeuTheme.contrastRatio(
          NeuTheme.disabledText(isDark),
          NeuTheme.surface(isDark),
        );
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: '${isDark ? 'dark' : 'light'} disabled ink measured '
                '${ratio.toStringAsFixed(2)}:1');
      }
    });

    testWidgets('enabled button invokes onPressed', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(host(
        NeuButton(onPressed: () => pressed++, child: const Text('Go')),
      ));
      await tester.tap(find.byType(NeuButton));
      expect(pressed, 1);
    });
  });

  group('NeuCheckbox', () {
    testWidgets('hit target is at least 28px despite the 18px visual',
        (tester) async {
      var value = false;
      await tester.pumpWidget(host(
        StatefulBuilder(
          builder: (context, setState) => NeuCheckbox(
            value: value,
            activeColor: Colors.blue,
            onChanged: (v) => setState(() => value = v ?? false),
          ),
        ),
      ));

      final size = tester.getSize(find.byType(NeuCheckbox));
      expect(size.width, greaterThanOrEqualTo(28));
      expect(size.height, greaterThanOrEqualTo(28));

      await tester.tap(find.byType(NeuCheckbox));
      await tester.pumpAndSettle();
      expect(value, isTrue);
    });

    testWidgets('resolves theme brightness when isDark is omitted', (tester) async {
      await tester.pumpWidget(host(
        NeuCheckbox(value: true, activeColor: Colors.blue, onChanged: (_) {}),
        brightness: Brightness.light,
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('NeuSwitch', () {
    testWidgets('toggles and lays out without overflow', (tester) async {
      final overflows = <FlutterErrorDetails>[];
      final oldHandler = FlutterError.onError;
      FlutterError.onError = overflows.add;

      var value = false;
      await tester.pumpWidget(host(
        StatefulBuilder(
          builder: (context, setState) => NeuSwitch(
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ));
      await tester.tap(find.byType(NeuSwitch));
      await tester.pumpAndSettle();

      FlutterError.onError = oldHandler;
      expect(value, isTrue);
      expect(overflows, isEmpty,
          reason: 'the old NeuSwitch knob overflowed its padded track');
    });

    testWidgets('disabled switch ignores taps', (tester) async {
      await tester.pumpWidget(host(
        const NeuSwitch(value: false, onChanged: null),
      ));
      await tester.tap(find.byType(NeuSwitch), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('NeuLedIndicator', () {
    testWidgets('starts pulsing when isLive flips to true after first build',
        (tester) async {
      // Regression: the controller was only created in initState, so a LED
      // whose channel went live later never pulsed (and one that went offline
      // kept pulsing).
      //
      // Scoped to the LED's own subtree: MaterialApp's route transitions are
      // FadeTransitions too.
      Finder ledFade() => find.descendant(
            of: find.byType(NeuLedIndicator),
            matching: find.byType(FadeTransition),
          );

      await tester.pumpWidget(host(const NeuLedIndicator(isLive: false)));
      await tester.pumpAndSettle();
      expect(ledFade(), findsNothing);

      await tester.pumpWidget(host(const NeuLedIndicator(isLive: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(ledFade(), findsOneWidget);

      await tester.pumpWidget(host(const NeuLedIndicator(isLive: false)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(ledFade(), findsNothing);
    });
  });

  group('NeuTheme.onAccent', () {
    // Every accent the picker offers, light palette then dark.
    const shippedAccents = <String, Color>{
      'Soft Pink': Color(0xFFFF6584),
      'Twitch Purple': Color(0xFF7C3AED),
      'Cyan': Color(0xFF00F2FE),
      'Emerald': Color(0xFF10B981),
      'Orange': Color(0xFFFF7A00),
      'Rose': Color(0xFFF43F5E),
      'Vibrant Red': Color(0xFFFF3B30),
      'Electric Purple': Color(0xFF8B5CF6),
      'Sky Blue': Color(0xFF38BDF8),
      'Magenta': Color(0xFFFF2A85),
      'Gold': Color(0xFFF59E0B),
    };

    test('every shipped accent gets a readable ink', () {
      // This asserts the PROPERTY, not the colour. The previous version listed
      // which accents "need white" and which "need dark ink", which encoded
      // the output of the old implementation - including five accents where
      // white measured below AA (Soft Pink 2.82, Magenta 3.55, Vibrant Red
      // 3.55, Rose 3.67, Electric Purple 4.23). The test passed while the app
      // shipped unreadable labels.
      shippedAccents.forEach((name, accent) {
        final ratio = NeuTheme.contrastRatio(NeuTheme.onAccent(accent), accent);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '$name: ink on accent measured ${ratio.toStringAsFixed(2)}:1');
      });
    });

    test('holds for adversarial values a hand-edited config could contain', () {
      // lightAccentColorHex is a plain string in channels_config.json, so the
      // picker is not the only way a value arrives here.
      const hostile = <Color>[
        Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFF7F7F7F),
        Color(0xFFEBECF0), Color(0xFF808080), Color(0xFF767676),
      ];
      for (final accent in hostile) {
        final ratio = NeuTheme.contrastRatio(NeuTheme.onAccent(accent), accent);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '$accent measured ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('picks whichever ink actually contrasts more', () {
      for (final accent in shippedAccents.values) {
        final chosen = NeuTheme.onAccent(accent);
        final other = chosen == Colors.white ? const Color(0xFF0B0D12) : Colors.white;
        expect(NeuTheme.contrastRatio(chosen, accent),
            greaterThanOrEqualTo(NeuTheme.contrastRatio(other, accent)),
            reason: 'a better ink than $chosen was available for $accent');
      }
    });
  });

  group('NeuFocusable', () {
    testWidgets('keyboard reaches and activates neumorphic controls',
        (tester) async {
      var pressed = 0;
      var switched = false;
      await tester.pumpWidget(host(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NeuButton(onPressed: () => pressed++, child: const Text('Go')),
          const SizedBox(height: 8),
          NeuSwitch(value: false, onChanged: (v) => switched = v),
        ],
      )));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(pressed, 1, reason: 'Tab+Enter must press the button');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(switched, isTrue, reason: 'Tab+Space must flip the switch');
    });
  });
}
