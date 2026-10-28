import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/widgets/horizontal_mouse_scrollable.dart';
import 'package:streamlink_gui/widgets/vods_grid.dart';

TwitchVideo vod(int i, List<String> games) => TwitchVideo(
      id: 'vod$i',
      title: 'VOD $i',
      duration: '1h0m0s',
      thumbnailUrl: '', // no network in tests
      viewCount: '1',
      publishedAt: DateTime(2026, 1, 1),
      games: games,
    );

/// The real VOD grid inside the real kind of page scroller it lives in: the
/// game-chip strip is a SliverToBoxAdapter at the top of the channel page's
/// CustomScrollView, which is exactly where the wheel used to die.
Widget page(List<TwitchVideo> vods, ScrollController outer,
    TextEditingController search) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) {
        return CustomScrollView(
          controller: outer,
          slivers: [
            VodsGrid(
              vods: vods,
              isLoading: false,
              vodsError: null,
              vodScale: 300,
              vodTitleFontSize: 14,
              showGamesOnThumbnails: false,
              selectedGamesFilter: const {},
              vodSearchController: search,
              theme: Theme.of(context),
              isMultiSelectMode: false,
              selectedVodIds: const {},
              isPlaying: (_) => false,
              isDownloaded: (_) => false,
              getDownloadStatus: (_) => null,
              getDownloadProgress: (_) => null,
              pulseController: null,
              watchedThreshold: 90,
              activeProgressColor: Colors.purple,
              watchedProgressColor: Colors.green,
              onGameFilterSelected: (_) {},
              onClearGameFilter: () {},
              onPlay: (_) {},
              onDownload: (_) {},
              onDeleteDownload: (_) {},
              onCancelDownload: (_) {},
              onVodSelectedChange: (_, _) {},
            ),
          ],
        );
      }),
    ),
  );
}

/// A mouse wheel notch (or [dy] worth of them) at [at].
Future<void> wheel(WidgetTester tester, Offset at, double dy) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  group('horizontalWheelTarget', () {
    test('a strip that fits claims nothing', () {
      expect(
          horizontalWheelTarget(
              offset: 0,
              minExtent: 0,
              maxExtent: 0,
              scrollDelta: const Offset(0, 120)),
          isNull);
    });

    test('a strip at its end lets the wheel past in that direction only', () {
      expect(
          horizontalWheelTarget(
              offset: 400,
              minExtent: 0,
              maxExtent: 400,
              scrollDelta: const Offset(0, 120)),
          isNull);
      expect(
          horizontalWheelTarget(
              offset: 400,
              minExtent: 0,
              maxExtent: 400,
              scrollDelta: const Offset(0, -120)),
          280);
    });

    test('a strip at its start lets an upward wheel past', () {
      expect(
          horizontalWheelTarget(
              offset: 0,
              minExtent: 0,
              maxExtent: 400,
              scrollDelta: const Offset(0, -120)),
          isNull);
    });

    test('travel is clamped to the strip, and still claimed', () {
      expect(
          horizontalWheelTarget(
              offset: 350,
              minExtent: 0,
              maxExtent: 400,
              scrollDelta: const Offset(0, 120)),
          400);
    });

    test('a horizontal delta is used only when there is no vertical one', () {
      expect(
          horizontalWheelTarget(
              offset: 100,
              minExtent: 0,
              maxExtent: 400,
              scrollDelta: const Offset(30, 0)),
          130);
      expect(
          horizontalWheelTarget(
              offset: 100,
              minExtent: 0,
              maxExtent: 400,
              scrollDelta: const Offset(30, 50)),
          150);
      expect(
          horizontalWheelTarget(
              offset: 100,
              minExtent: 0,
              maxExtent: 400,
              scrollDelta: Offset.zero),
          isNull);
    });
  });

  group('the VOD page scrolls with the pointer over the game chips', () {
    late ScrollController outer;
    late TextEditingController search;

    setUp(() {
      outer = ScrollController();
      search = TextEditingController();
    });

    tearDown(() {
      outer.dispose();
      search.dispose();
    });

    void sized(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    ScrollPosition chipStrip(WidgetTester tester) => tester
        .state<ScrollableState>(find.descendant(
          of: find.byType(HorizontalMouseScrollable),
          matching: find.byType(Scrollable),
        ))
        .position;

    testWidgets('chips that fit no longer swallow the wheel', (tester) async {
      // Regression: with the chips fitting (maxScrollExtent 0) the strip
      // still registered for the wheel, won the resolver, and did nothing -
      // the grid underneath would not move until the pointer left the strip.
      sized(tester, const Size(1000, 700));
      final vods = [
        for (var i = 0; i < 40; i++) vod(i, i.isEven ? ['Chess'] : ['Art']),
      ];
      await tester.pumpWidget(page(vods, outer, search));
      await tester.pump();
      expect(chipStrip(tester).maxScrollExtent, 0);

      await wheel(tester, tester.getCenter(find.text('All Games')), 120);

      expect(outer.offset, greaterThan(0),
          reason: 'the page should scroll under a strip that cannot');
    });

    testWidgets('overflowing chips take the wheel until their end, then pass it on',
        (tester) async {
      sized(tester, const Size(500, 700));
      final vods = [
        for (var i = 0; i < 40; i++) vod(i, ['A long category name $i']),
      ];
      await tester.pumpWidget(page(vods, outer, search));
      await tester.pump();
      final strip = chipStrip(tester);
      expect(strip.maxScrollExtent, greaterThan(0));

      final overChips = tester.getCenter(find.text('All Games'));

      // While the strip can move, the wheel is the strip's - the page holds.
      await wheel(tester, overChips, 120);
      expect(strip.pixels, 120);
      expect(outer.offset, 0);

      // Run it to the end. Still the strip's: it moved.
      await wheel(tester, overChips, 1e6);
      expect(strip.pixels, strip.maxScrollExtent);
      expect(outer.offset, 0);

      // At the end the next notch is the page's.
      await wheel(tester, overChips, 120);
      expect(strip.pixels, strip.maxScrollExtent);
      expect(outer.offset, greaterThan(0));
    });
  });
}
