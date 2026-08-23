import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

/// Overflow is the one layout fault that is both objectively detectable and
/// completely invisible in a passing test suite — Flutter reports it through
/// FlutterError.onError, which the default test harness does not fail on for
/// widgets that still lay out.
///
/// The app enforces a 380x500 minimum window, so every size below is reachable
/// by a user, not hypothetical.
const sweepSizes = <Size>[
  Size(380, 500), // the enforced minimum
  Size(700, 800), // portrait
  Size(900, 600),
  Size(1179, 720), // just below the wide-controls boundary
  Size(1181, 720), // just above it
  Size(1600, 1000),
];

/// Pumps [build] at [size] and fails if anything overflowed.
Future<void> expectNoOverflow(
  WidgetTester tester,
  Size size,
  Widget Function() build, {
  Brightness brightness = Brightness.dark,
}) async {
  final overflows = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exception.toString();
    if (text.contains('overflowed')) {
      overflows.add(text.split('\n').first);
    } else {
      previous?.call(details);
    }
  };

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  try {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        primaryColor: NeuTheme.defaultDarkAccent,
      ),
      home: AppLayout(
        data: AppLayoutData.fromSize(size),
        child: Scaffold(body: build()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 350));
  } finally {
    FlutterError.onError = previous;
  }

  expect(overflows, isEmpty,
      reason: 'at ${size.width.toInt()}x${size.height.toInt()}:\n'
          '${overflows.join('\n')}');
}

TwitchChannel channel({
  String username = 'a_streamer_with_a_very_long_channel_name',
  bool isLive = true,
}) {
  final c = TwitchChannel(username: username);
  c.isLive = isLive;
  // Deliberately hostile: real Twitch category and title strings run long, and
  // these tiles are only ~160px wide at the minimum window size.
  c.game = 'Tom Clancy’s Rainbow Six Siege Extraction Deluxe Edition';
  c.streamTitle =
      'An extremely long stream title that will not fit in a narrow card at all';
  c.viewerCount = '123456';
  return c;
}

void main() {
  group('the sweep harness itself', () {
    // A detector that never fires is worse than no detector. This pumps the
    // layout as it was BEFORE the fix - a bare Text in a spaceBetween Row -
    // and asserts it does overflow, so the passing tests below mean something.
    testWidgets('detects an overflow when one is present', (tester) async {
      var caught = false;
      try {
        await expectNoOverflow(tester, const Size(380, 500), () {
          return GridView.extent(
            maxCrossAxisExtent: 220,
            childAspectRatio: 220 / 130,
            children: [for (var i = 0; i < 4; i++) _liveCardFooterUnfixed()],
          );
        });
      } on TestFailure {
        caught = true;
      }
      expect(caught, isTrue,
          reason: 'the harness failed to notice a known overflow');
    });
  });

  group('the live-channel card footer', () {
    // Regression: the game Text sat directly in a spaceBetween Row with no
    // Expanded, so `overflow: ellipsis` could never engage - an unbounded Text
    // reports its full intrinsic width and the Row overflowed instead.
    for (final size in sweepSizes) {
      testWidgets('survives ${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        await expectNoOverflow(tester, size, () {
          return GridView.extent(
            maxCrossAxisExtent: 220,
            childAspectRatio: 220 / 130,
            children: [for (var i = 0; i < 4; i++) _liveCardFooter()],
          );
        });
      });
    }
  });

  group('AppLayoutData', () {
    test('bands are exclusive and cover the range', () {
      expect(AppLayoutData.fromSize(const Size(699, 500)).size,
          LayoutSize.compact);
      expect(AppLayoutData.fromSize(const Size(700, 500)).size,
          LayoutSize.medium);
      expect(AppLayoutData.fromSize(const Size(1179, 720)).size,
          LayoutSize.medium);
      expect(AppLayoutData.fromSize(const Size(1180, 720)).size,
          LayoutSize.expanded);
      expect(AppLayoutData.fromSize(const Size(1181, 720)).size,
          LayoutSize.expanded);
    });

    test('portrait is independent of width band', () {
      // A tall-but-wide window is medium AND portrait; the old `isNarrow` and
      // `isCompact` disagreed about exactly this case.
      final tallMedium = AppLayoutData.fromSize(const Size(900, 1200));
      expect(tallMedium.size, LayoutSize.medium);
      expect(tallMedium.isPortrait, isTrue);
      expect(tallMedium.isRail, isTrue);
    });

    test('isRail is compact-or-portrait', () {
      expect(AppLayoutData.fromSize(const Size(500, 400)).isRail, isTrue);
      expect(AppLayoutData.fromSize(const Size(1600, 1000)).isRail, isFalse);
      expect(AppLayoutData.fromSize(const Size(1600, 1700)).isRail, isTrue);
    });

    test('wide controls appear only in the expanded band', () {
      expect(AppLayoutData.fromSize(const Size(1179, 720)).hasWideControls,
          isFalse);
      expect(AppLayoutData.fromSize(const Size(1180, 720)).hasWideControls,
          isTrue);
    });

    test('equal bands compare equal, so a resize within a band is inert', () {
      // AppLayout only notifies dependants when this value changes; dragging
      // 1400 -> 1300 must not rebuild the subtree.
      expect(AppLayoutData.fromSize(const Size(1400, 900)),
          AppLayoutData.fromSize(const Size(1300, 900)));
      expect(AppLayoutData.fromSize(const Size(1400, 900)),
          isNot(AppLayoutData.fromSize(const Size(900, 900))));
    });
  });
}

/// The footer as the welcome screen builds it: a spaceBetween Row carrying a
/// long category name beside a viewer count.
Widget _liveCardFooter() {
  final c = channel();
  return Container(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                c.game ?? 'Unknown Game',
                style: const TextStyle(fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.remove_red_eye, size: 10),
                const SizedBox(width: 4),
                Text('${c.viewerCount}', style: const TextStyle(fontSize: 10)),
              ],
            ),
          ],
        ),
      ],
    ),
  );
}

/// The same footer as it was before the fix: the category Text sits directly
/// in the Row with no Expanded, so it claims its full intrinsic width.
///
/// Kept deliberately, as the control case for the harness above.
Widget _liveCardFooterUnfixed() {
  final c = channel();
  return Container(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              c.game ?? 'Unknown Game',
              style: const TextStyle(fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                const Icon(Icons.remove_red_eye, size: 10),
                const SizedBox(width: 4),
                Text('${c.viewerCount}', style: const TextStyle(fontSize: 10)),
              ],
            ),
          ],
        ),
      ],
    ),
  );
}
