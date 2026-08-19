import 'package:flutter/material.dart';
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

      // The disabled content is wrapped in a dimming Opacity.
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('Disabled'), matching: find.byType(Opacity)).first,
      );
      expect(opacity.opacity, lessThan(1.0));
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
    test('flips to dark ink on bright accents and white on dark ones', () {
      // The shipped accent swatches.
      const darkInkExpected = [
        Color(0xFF00F2FE), // Cyan
        Color(0xFF10B981), // Emerald
        Color(0xFFFF7A00), // Orange
        Color(0xFFF59E0B), // Gold
        Color(0xFF38BDF8), // Sky
      ];
      const whiteExpected = [
        Color(0xFFFF6584), // Soft Pink
        Color(0xFF7C3AED), // Twitch Purple
        Color(0xFFF43F5E), // Rose
        Color(0xFFFF3B30), // Vibrant Red
        Color(0xFF8B5CF6), // Electric Purple
        Color(0xFFFF2A85), // Magenta
      ];
      for (final accent in darkInkExpected) {
        expect(NeuTheme.onAccent(accent), isNot(Colors.white),
            reason: 'bright accent $accent needs dark ink');
      }
      for (final accent in whiteExpected) {
        expect(NeuTheme.onAccent(accent), Colors.white,
            reason: 'dark accent $accent needs white');
      }
    });
  });
}
