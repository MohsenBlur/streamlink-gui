import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/widgets/interactive_popover.dart';
import 'package:streamlink_gui/widgets/shell/selection_bar.dart';

/// The selection bar's two ends - the count with All and None on the left,
/// the actions (or the Actions menu) on the right - sharing one row.
///
/// They used to share it two parts to one whatever each needed, so the
/// smaller side was cut short while the row still had room for both. The
/// sweeps (test/layout) hold that nothing overflows at any size; these hold
/// that nothing is cut before it has to be.
void main() {
  group('splitTwoEnds', () {
    test('gives each end what it wants while both fit', () {
      expect(splitTwoEnds(500, 280, 130), (start: 280.0, end: 130.0));
      expect(splitTwoEnds(410, 280, 130), (start: 280.0, end: 130.0));
    });

    test('past that, the end wanting less than its share keeps it', () {
      // The start's share of 400 is 266.7; it wants less, so the end has
      // the rest rather than a third.
      expect(splitTwoEnds(400, 200, 300), (start: 200.0, end: 200.0));
      // The end's share is 133.3; it wants 100, and the start gives way.
      expect(splitTwoEnds(300, 280, 100), (start: 200.0, end: 100.0));
    });

    test('and with both over their shares, two parts to one', () {
      final split = splitTwoEnds(300, 280, 130);
      expect(split.start, closeTo(200, 1e-9));
      expect(split.end, closeTo(100, 1e-9));
    });
  });

  group('the bar', () {
    final actions = [
      for (final label in ['Watched', 'Unwatched', 'Download', 'Delete files'])
        SelectionAction(label: label, icon: Icons.check, onPressed: () {}),
    ];

    Future<void> pumpAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = const Size(1200, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SelectionBar(
                selectedCount: 2,
                onSelectAllVisible: () {},
                onClear: () {},
                onExit: () {},
                actions: actions,
              ),
            ),
          ),
        ),
      ));
    }

    Finder countSide() => find
        .ancestor(of: find.text('2 selected'), matching: find.byType(Row))
        .first;
    Finder menu() => find.byType(InteractivePopover);
    bool cut(WidgetTester tester, String text) =>
        tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

    testWidgets('cuts neither end while the row holds both', (tester) async {
      // Measured where both have room to spare, with the Actions menu in
      // place of the actions (the bar shows them all from 820px).
      await pumpAt(tester, 800);
      final want = tester.getSize(countSide()).width + tester.getSize(menu()).width;
      final around = 800 - tester.getSize(find.byType(Expanded)).width;
      expect(cut(tester, '2 selected'), isFalse);
      expect(cut(tester, 'Actions'), isFalse);

      // Room for both and a pixel more: the old split gave the count's side
      // two thirds of this, too little for it.
      await pumpAt(tester, want + around + 1);
      expect(tester.takeException(), isNull);
      expect(cut(tester, '2 selected'), isFalse,
          reason: 'the count has the room the menu does not use');
      expect(cut(tester, 'Actions'), isFalse);

      // And every width the menu shows at, down to well under the narrowest
      // window's: nothing overflows, and nothing is cut while both fit.
      for (var width = 320.0; width < 820; width += 4) {
        await pumpAt(tester, width);
        expect(tester.takeException(), isNull, reason: 'at $width');
        if (width < want + around) continue;
        expect(cut(tester, '2 selected'), isFalse, reason: 'at $width');
        expect(cut(tester, 'Actions'), isFalse, reason: 'at $width');
      }
    });

    testWidgets('keeps its ends at the edges, and gives way without '
        'overflowing when the row is too narrow', (tester) async {
      await pumpAt(tester, 330);
      expect(tester.takeException(), isNull);
      expect(cut(tester, '2 selected'), isTrue);
      final row = tester.getRect(find.byType(Expanded));
      expect(tester.getRect(countSide()).left, row.left);
      expect(tester.getRect(menu()).right, row.right);
    });
  });
}
