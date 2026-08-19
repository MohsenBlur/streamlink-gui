import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/widgets/twitch_video_card.dart';
import 'package:streamlink_gui/widgets/vods_grid.dart';

TwitchVideo fakeVod(int i) => TwitchVideo(
      id: 'vod$i',
      title: 'VOD $i',
      duration: '1h0m0s',
      thumbnailUrl: '', // no network in tests
      viewCount: '1',
      publishedAt: DateTime(2026, 1, 1),
    );

Widget harness(List<TwitchVideo> vods, TextEditingController search) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(builder: (context) {
        return CustomScrollView(
          slivers: [
            VodsGrid(
              vods: vods,
              isLoading: false,
              vodsError: null,
              vodScale: 350,
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
              onVodSelectedChange: (_, __) {},
            ),
          ],
        );
      }),
    ),
  );
}

void main() {
  testWidgets('sliver grid culls off-screen cards and reaches the end',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final search = TextEditingController();
    addTearDown(search.dispose);

    final vods = List.generate(120, fakeVod);
    await tester.pumpWidget(harness(vods, search));
    await tester.pump();

    // The whole point of the sliver conversion: with 120 VODs on an 800x600
    // viewport only the visible rows (plus cache extent) may exist. The old
    // shrinkWrap GridView materialized all 120.
    final materialized =
        find.byType(TwitchVideoCard, skipOffstage: false).evaluate().length;
    expect(materialized, greaterThan(0));
    expect(materialized, lessThan(30),
        reason: 'off-screen cards must not materialize');

    // Scrolling still reaches the very last card.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('vod119'), skipOffstage: false),
      600,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 300,
    );
    expect(find.byKey(const ValueKey('vod119'), skipOffstage: false),
        findsOneWidget);
  });
}
