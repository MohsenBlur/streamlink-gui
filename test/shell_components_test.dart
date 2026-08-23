import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/shell/empty_state.dart';
import 'package:streamlink_gui/widgets/shell/section_header.dart';

Widget host(Widget child, {Size? size}) => MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: NeuTheme.defaultDarkAccent,
      ),
      home: Scaffold(body: child),
    );

void main() {
  group('SectionHeader', () {
    testWidgets('inline headings are uppercased at the legible floor',
        (tester) async {
      // Two files wrote this out by hand at fontSize 9.5, below the size where
      // Segoe UI's stems land on whole device pixels.
      await tester.pumpWidget(host(const SectionHeader(
        title: 'In progress',
        density: SectionDensity.inline,
      )));
      final style = tester.widget<Text>(find.text('IN PROGRESS')).style!;
      expect(style.fontSize, 10);
      expect(style.letterSpacing, 0.8);
    });

    testWidgets('page and panel headings are not uppercased', (tester) async {
      await tester.pumpWidget(host(const SectionHeader(title: 'Live now')));
      expect(find.text('Live now'), findsOneWidget);

      await tester.pumpWidget(host(const SectionHeader(
        title: 'Live now',
        density: SectionDensity.panel,
      )));
      expect(find.text('Live now'), findsOneWidget);
    });

    testWidgets('a long title ellipsizes rather than overflowing',
        (tester) async {
      final overflows = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exception.toString().contains('overflowed')) {
          overflows.add(d.exception.toString());
        } else {
          previous?.call(d);
        }
      };
      tester.view.physicalSize = const Size(380, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(const SectionHeader(
        title: 'An extremely long section heading that cannot possibly fit',
        count: 42,
        icon: Icons.live_tv,
      )));
      await tester.pump();
      FlutterError.onError = previous;
      expect(overflows, isEmpty);
    });

    testWidgets('the count renders beside the title', (tester) async {
      await tester.pumpWidget(host(const SectionHeader(
        title: 'Live now',
        count: 3,
      )));
      expect(find.text('3'), findsOneWidget);
    });
  });

  group('EmptyState', () {
    testWidgets('shows what is missing and why', (tester) async {
      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.videocam_off_outlined,
        title: 'No past broadcasts',
        message: 'This channel has no VODs available.',
      )));
      expect(find.text('No past broadcasts'), findsOneWidget);
      expect(find.text('This channel has no VODs available.'), findsOneWidget);
      expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
    });

    testWidgets('offers the way out when there is one', (tester) async {
      // The point of the rewrite: "No entries match the current search or
      // filter" left the user reading a sentence with nothing to click.
      var cleared = 0;
      await tester.pumpWidget(host(EmptyState(
        icon: Icons.search_off,
        title: 'No matches',
        action: TextButton(
          onPressed: () => cleared++,
          child: const Text('Clear filters'),
        ),
      )));
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(cleared, 1);
    });

    testWidgets('reads as calm, not as an error', (tester) async {
      // An empty state is a normal condition; the icon must not be the danger
      // colour that a failure uses.
      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.inbox,
        title: 'Nothing here',
      )));
      final icon = tester.widget<Icon>(find.byIcon(Icons.inbox));
      expect(icon.color, isNot(NeuTheme.danger));
      expect(icon.color, NeuTheme.disabledText(true));
    });

    testWidgets('keeps its message readable on a very wide window',
        (tester) async {
      tester.view.physicalSize = const Size(2560, 1440);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.inbox,
        title: 'Nothing here',
        message: 'A message long enough that, unconstrained, it would stretch '
            'right across a 2560px window and become hard to read.',
      )));
      await tester.pump();
      final width = tester.getSize(find.byType(Text).last).width;
      expect(width, lessThanOrEqualTo(380));
    });

    testWidgets('lays out at the 380px minimum without overflow',
        (tester) async {
      final overflows = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exception.toString().contains('overflowed')) {
          overflows.add(d.exception.toString());
        } else {
          previous?.call(d);
        }
      };
      tester.view.physicalSize = const Size(380, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(const EmptyState(
        icon: Icons.inbox,
        title: 'Nothing here',
        message: 'A reasonably long explanatory sentence goes here.',
      )));
      await tester.pump();
      FlutterError.onError = previous;
      expect(overflows, isEmpty);
    });
  });
}
