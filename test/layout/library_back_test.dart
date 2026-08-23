import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/library_entries.dart';
import 'package:streamlink_gui/widgets/library_view.dart';

Widget host(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: child),
    );

LibraryView build({VoidCallback? onBack, String? backLabel}) => LibraryView(
      entries: const <LibraryEntry>[],
      onRefresh: () {},
      onPlay: (_) {},
      onOpenFolder: (_) {},
      onDelete: (_) {},
      onRemoveFromHistory: (_) {},
      onBack: onBack,
      backLabel: backLabel,
    );

void main() {
  group('the Library is not a dead end', () {
    testWidgets('a back control is shown and invokes onBack', (tester) async {
      // Regression: nothing in library_view.dart's 555 lines was a back
      // control. The only ways out were picking a channel or clicking the
      // sidebar's app title - i.e. going somewhere else, not going back.
      var backs = 0;
      await tester.pumpWidget(host(build(
        onBack: () => backs++,
        backLabel: 'shroud',
      )));

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(backs, 1);
    });

    testWidgets('the control names its destination when there is room',
        (tester) async {
      // A bare arrow does not say where it goes; the label is what makes this
      // a destination rather than a guess. Below 560px it is dropped in favour
      // of the tooltip, which still carries it.
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(build(onBack: () {}, backLabel: 'shroud')));
      expect(find.text('shroud'), findsOneWidget);
    });

    testWidgets('the destination survives in the tooltip when space is tight',
        (tester) async {
      tester.view.physicalSize = const Size(380, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(build(onBack: () {}, backLabel: 'shroud')));
      final tooltip = tester.widget<Tooltip>(find
          .ancestor(of: find.byIcon(Icons.arrow_back), matching: find.byType(Tooltip))
          .first);
      expect(tooltip.message, contains('shroud'));
    });

    testWidgets('a long channel name cannot overflow the header',
        (tester) async {
      final overflows = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exception.toString().contains('overflowed')) {
          overflows.add(d.exception.toString().split('\n').first);
        } else {
          previous?.call(d);
        }
      };
      tester.view.physicalSize = const Size(380, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(build(
        onBack: () {},
        backLabel: 'a_channel_name_far_longer_than_any_header_could_hold',
      )));
      await tester.pump();
      FlutterError.onError = previous;

      expect(overflows, isEmpty);
    });

    testWidgets('no control is shown when there is nowhere to go back to',
        (tester) async {
      await tester.pumpWidget(host(build()));
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });
  });
}
