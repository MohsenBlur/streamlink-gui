import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_badge.dart';

Widget host(Widget child, {Brightness brightness = Brightness.dark}) {
  return MaterialApp(
    theme: ThemeData(
      brightness: brightness,
      primaryColor: NeuTheme.defaultDarkAccent,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

TextStyle styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

void main() {
  // These widgets read the global themeNotifier rather than Theme.of(context),
  // as the rest of this codebase does, so the theme has to be set there.
  tearDown(() => themeNotifier.setDarkTheme(true));

  group('StatusBadge', () {
    testWidgets('uppercases its label', (tester) async {
      // Callers pass sentence case; the chip owns the presentation, so a label
      // cannot arrive already-shouted from one site and not another.
      await tester.pumpWidget(host(const StatusBadge(label: 'Downloaded')));
      expect(find.text('DOWNLOADED'), findsOneWidget);
    });

    testWidgets('every tone renders at one readable size', (tester) async {
      // Four sites hand-rolled this at fontSize 8.5, below the size where
      // Segoe UI stems land on whole pixels - they grey out whatever colour is
      // chosen.
      for (final tone in BadgeTone.values) {
        await tester.pumpWidget(host(StatusBadge(label: 'x', tone: tone)));
        final style = styleOf(tester, 'X');
        expect(style.fontSize, 10, reason: '$tone');
        expect(style.fontWeight, FontWeight.bold, reason: '$tone');
      }
    });

    testWidgets('tone drives the ink, not the caller', (tester) async {
      await tester.pumpWidget(host(
        const StatusBadge(label: 'ok', tone: BadgeTone.live),
      ));
      expect(styleOf(tester, 'OK').color, NeuTheme.liveText(true));

      await tester.pumpWidget(host(
        const StatusBadge(label: 'ok', tone: BadgeTone.danger),
      ));
      expect(styleOf(tester, 'OK').color, NeuTheme.dangerText(true));
    });

    testWidgets('every tone clears AA against the surface it sits on',
        (tester) async {
      // The chip fill is the tone at 15% over the surface, so the ink is
      // effectively on the surface.
      for (final isDark in [true, false]) {
        themeNotifier.setDarkTheme(isDark);
        final ground = NeuTheme.surface(isDark);
        for (final tone in BadgeTone.values) {
          await tester.pumpWidget(host(
            StatusBadge(label: 'x', tone: tone),
            brightness: isDark ? Brightness.dark : Brightness.light,
          ));
          final ink = styleOf(tester, 'X').color!;
          final ratio = NeuTheme.contrastRatio(ink, ground);
          expect(ratio, greaterThanOrEqualTo(3.0),
              reason: '$tone on ${isDark ? 'dark' : 'light'} = '
                  '${ratio.toStringAsFixed(2)}:1');
        }
      }
    });

    testWidgets('an optional icon sits before the label', (tester) async {
      await tester.pumpWidget(host(
        const StatusBadge(label: 'live', icon: Icons.circle),
      ));
      expect(find.byIcon(Icons.circle), findsOneWidget);
    });
  });

  group('LiveBadge', () {
    testWidgets('the count variant reads "N LIVE"', (tester) async {
      await tester.pumpWidget(host(
        const LiveBadge(variant: LiveVariant.count, count: 3),
      ));
      expect(find.text('3 LIVE'), findsOneWidget);
    });

    testWidgets('the pill variant reads LIVE', (tester) async {
      await tester.pumpWidget(host(const LiveBadge()));
      expect(find.text('LIVE'), findsOneWidget);
    });

    testWidgets('pill and count share one type treatment', (tester) async {
      // The whole point: the app said "live" three ways at once - 10px/1.2
      // tracking in the title bar, 8px solid in sidebar rows, 10px/0.5 in the
      // channel header.
      await tester.pumpWidget(host(const LiveBadge()));
      final pill = styleOf(tester, 'LIVE');
      await tester.pumpWidget(host(
        const LiveBadge(variant: LiveVariant.count, count: 2),
      ));
      final count = styleOf(tester, '2 LIVE');

      expect(count.fontSize, pill.fontSize);
      expect(count.fontWeight, pill.fontWeight);
      expect(count.letterSpacing, pill.letterSpacing);
      expect(count.color, pill.color);
    });

    testWidgets('the dot variant is a fixed 10px circle', (tester) async {
      await tester.pumpWidget(host(const LiveBadge(variant: LiveVariant.dot)));
      expect(tester.getSize(find.byType(LiveBadge)), const Size(10, 10));
      expect(find.text('LIVE'), findsNothing);
    });

    testWidgets('renders static when given no animation', (tester) async {
      // A badge in a dialog, or in a screenshot, should not depend on a ticker.
      await tester.pumpWidget(host(const LiveBadge()));
      expect(
          find.descendant(
              of: find.byType(LiveBadge), matching: find.byType(AnimatedBuilder)),
          findsNothing);
      expect(find.text('LIVE'), findsOneWidget);
    });

    testWidgets('an offline label overrides the text', (tester) async {
      await tester.pumpWidget(host(const LiveBadge(label: 'Offline')));
      expect(find.text('OFFLINE'), findsOneWidget);
    });
  });
}
