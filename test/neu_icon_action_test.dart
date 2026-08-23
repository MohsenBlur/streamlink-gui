import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_icon_action.dart';

Widget host(Widget child) => MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: NeuTheme.defaultDarkAccent,
      ),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('NeuIconAction', () {
    testWidgets('every size keeps a 40x40 hit target', (tester) async {
      // Several IconButtons set `constraints: const BoxConstraints()` with zero
      // padding, which collapses the target down to the 20px glyph. The visual
      // face may be small; the thing you have to hit must not be.
      for (final size in NeuActionSize.values) {
        await tester.pumpWidget(host(NeuIconAction(
          icon: Icons.close,
          tooltip: 'Close',
          onPressed: () {},
          size: size,
        )));
        final box = tester.getSize(find.byType(NeuIconAction));
        expect(box.width, greaterThanOrEqualTo(40), reason: '$size width');
        expect(box.height, greaterThanOrEqualTo(40), reason: '$size height');
      }
    });

    testWidgets('the whole target is tappable, not just the visible face',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(NeuIconAction(
        icon: Icons.close,
        tooltip: 'Close',
        onPressed: () => taps++,
        size: NeuActionSize.sm, // 28px face inside a 40px target
      )));

      // A corner of the target, outside the 28px face.
      final rect = tester.getRect(find.byType(NeuIconAction));
      await tester.tapAt(Offset(rect.left + 3, rect.top + 3));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('is always tooltipped', (tester) async {
      // tooltip is a required parameter: this app leans on icon-only controls
      // and hover-reveals, and an icon with no label and no tooltip is a guess.
      await tester.pumpWidget(host(NeuIconAction(
        icon: Icons.folder_open,
        tooltip: 'Show in Explorer',
        onPressed: () {},
      )));
      final tip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tip.message, 'Show in Explorer');
    });

    testWidgets('a disabled control says why, and does nothing', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(NeuIconAction(
        icon: Icons.download,
        tooltip: 'Download',
        onPressed: null,
        disabledReason: 'select a VOD first',
      )));

      await tester.tap(find.byType(NeuIconAction), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(taps, 0);

      final tip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tip.message, contains('select a VOD first'),
          reason: 'a dimmed control that does not say why is a dead end');
    });

    testWidgets('disabled uses the calibrated ink, not a faded one',
        (tester) async {
      await tester.pumpWidget(host(const NeuIconAction(
        icon: Icons.download,
        tooltip: 'Download',
        onPressed: null,
      )));
      final icon = tester.widget<Icon>(find.byIcon(Icons.download));
      expect(icon.color, NeuTheme.disabledText(true));
    });

    testWidgets('tone drives the ink', (tester) async {
      await tester.pumpWidget(host(NeuIconAction(
        icon: Icons.delete,
        tooltip: 'Delete',
        onPressed: () {},
        tone: NeuActionTone.danger,
      )));
      expect(tester.widget<Icon>(find.byIcon(Icons.delete)).color,
          NeuTheme.dangerText(true));
    });

    testWidgets('is reachable and activatable from the keyboard',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(NeuIconAction(
        icon: Icons.refresh,
        tooltip: 'Refresh',
        onPressed: () => taps++,
      )));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('a disabled control is not a keyboard trap', (tester) async {
      await tester.pumpWidget(host(const NeuIconAction(
        icon: Icons.refresh,
        tooltip: 'Refresh',
        onPressed: null,
      )));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
