import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/widgets/twitch_video_card.dart';

import 'support/main_screen_harness.dart';

/// The watch history, through the pumped screen (see [ScreenHarness]): what
/// happens to a position a playing VOD reports, when it reaches the disk, the
/// offer to go back to the furthest point, the recently-watched list, and the
/// three ways of taking progress away again.
///
/// The rules underneath are tested where they live - which position the
/// store keeps in watch_progress_store_test, when the files are written in
/// settings_repository_test, the tracker in watch_progress_sync_test - and
/// this is the screen's part: which of them a position goes through, and
/// what the user sees of it.
void main() {
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });
  tearDown(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });

  /// A three-hour VOD on alpha, played from its card.
  Future<String> playLongVod(WidgetTester tester, ScreenHarness h,
      {Map<String, dynamic> watchProgress = const <String, dynamic>{},
      List<TwitchVideo> recents = const <TwitchVideo>[],
      List<TwitchChannel> channels = const <TwitchChannel>[],
      Map<String, dynamic> config = const <String, dynamic>{},
      int maxRecent = 8,
      String? id}) async {
    h.helix.user('alpha');
    final vod = h.helix.addVideo('alpha',
        id: id, title: 'Long VOD', duration: '3h0m0s');
    await h.launch(tester,
        favorites: ['alpha'],
        channels: channels,
        settings: ScreenHarness.playbackSettings()
          ..maxRecentlyWatched = maxRecent,
        config: config,
        watchProgress: watchProgress,
        recents: recents);
    await h.openChannel(tester, 'alpha');
    await tester.tap(find.text('Long VOD'));
    await h.settle(tester);
    expect(h.player.playingVodIds, {vod}, reason: 'precondition: it plays');
    return vod;
  }

  TwitchVideo watched(String id, String title) => TwitchVideo(
        id: id,
        title: title,
        duration: '1h0m0s',
        thumbnailUrl: '',
        viewCount: '3',
        publishedAt: DateTime.utc(2026, 10, 1),
        watchPosition: 600,
        watchProgress: 600 / 3600,
      );

  group('a position a playing VOD reports', () {
    testWidgets(
        'is kept, shown in Continue watching, and written within the '
        'progress delay rather than on every tick', (tester) async {
      final h = ScreenHarness();
      final vod = await playLongVod(tester, h);
      final progress = h.storage.progressWrites;
      final recents = h.storage.recentsWrites;

      expect(h.player.feedPosition(vod, 1800), isTrue);
      expect(h.player.feedPosition(vod, 1802), isTrue);
      await h.settle(tester);
      expect(h.storage.progressWrites, progress, reason: 'not on every tick');

      await h.advance(tester, const Duration(seconds: 20));
      expect(h.storage.progressWrites, progress + 1);
      expect(h.storage.watchProgress[vod], containsPair('p', 1802));
      expect(h.storage.watchProgress[vod], containsPair('b', 1802));
      expect(
          (h.storage.config!['local_vods_progress'] as Map)[vod], 1802,
          reason: 'the flat copy an older build reads, in the config');
      expect(h.storage.recentsWrites, recents + 1);
      expect(h.storage.recents.first['id'], vod);

      await h.goHome(tester);
      expect(find.text('Continue watching'), findsOneWidget);
      expect(find.byTooltip('Long VOD\nResume at 16% (3h0m0s)'),
          findsOneWidget);

      await h.close(tester);
    });

    testWidgets('is written at once when the player stops', (tester) async {
      final h = ScreenHarness();
      final vod = await playLongVod(tester, h);
      h.player.feedPosition(vod, 2400);
      await h.settle(tester);
      final progress = h.storage.progressWrites;

      await h.playerExits(tester, vod);
      await h.settle(tester);
      expect(h.player.playingVodIds, isEmpty);
      expect(h.storage.progressWrites, progress + 1,
          reason: 'where playback stopped is the position to keep');
      expect(h.storage.watchProgress[vod], containsPair('p', 2400));

      await h.close(tester);
    });

    testWidgets('reaches the disk with an Exit', (tester) async {
      final h = ScreenHarness();
      final vod = await playLongVod(tester, h);
      h.player.feedPosition(vod, 3000);
      await h.settle(tester);

      await h.exitFromTray(tester);
      expect(h.window.destroyed, isTrue);
      expect(h.storage.watchProgress[vod], containsPair('p', 3000));
      expect(h.storage.recents.first['id'], vod);

      await h.close(tester);
    });

    testWidgets(
        'that looks like a failed resume is refused, and the furthest point '
        'stays', (tester) async {
      // A player that came up at the top of a VOD stored at two hours used
      // to write its way over the position within seconds.
      final h = ScreenHarness();
      final vod = await playLongVod(tester, h);
      expect(h.player.feedPosition(vod, 7200), isTrue);
      expect(
          h.player.feedPosition(vod, 4,
              sessionAge: const Duration(seconds: 3)),
          isFalse,
          reason: 'two hours back, three seconds into the session');
      await h.advance(tester, const Duration(seconds: 20));
      expect(h.storage.watchProgress[vod], containsPair('p', 7200));
      expect(
          (h.storage.config!['local_vods_progress'] as Map)[vod], 7200);

      await h.close(tester);
    });
  });

  group('the furthest point', () {
    // Stored at two hours, though the VOD last stopped ten minutes in.
    Map<String, dynamic> behind(String id) => {
          id: {'p': 600, 'u': 0, 'b': 7200, 'ba': 0, 'r': <dynamic>[]},
        };

    testWidgets(
        'a VOD opened behind it is offered the jump, and a player that cannot '
        'seek says so', (tester) async {
      final h = ScreenHarness();
      await playLongVod(tester, h, id: '5150', watchProgress: behind('5150'));
      expect(find.textContaining('You had reached'), findsNothing,
          reason: 'not before the player can take a seek');

      await h.advance(tester, const Duration(seconds: 6),
          step: const Duration(seconds: 1));
      await h.settleRoute(tester);
      expect(find.text('You had reached 2:00:00 in this VOD.'), findsOneWidget);

      await tester.tap(find.text('Jump there'));
      await h.settleRoute(tester);
      expect(
          find.text('Could not reach the player to jump; seek there manually.'),
          findsOneWidget,
          reason: 'this player has no interface to seek through');

      await h.close(tester);
    });

    testWidgets('is not offered once playback has passed it', (tester) async {
      final h = ScreenHarness();
      await playLongVod(tester, h, id: '5150', watchProgress: behind('5150'));
      // The player is past it before the offer would go up: read again then,
      // there is nothing to offer.
      h.player.feedPosition('5150', 7300);
      await h.advance(tester, const Duration(seconds: 8),
          step: const Duration(seconds: 1));
      await h.settleRoute(tester);
      expect(find.textContaining('You had reached'), findsNothing);

      await h.close(tester);
    });

    testWidgets(
        'comes from the sidecar, not from the flat copy in the config, and '
        'stays where it is when playback goes on behind it', (tester) async {
      final h = ScreenHarness();
      await playLongVod(tester, h,
          id: '5150',
          watchProgress: behind('5150'),
          config: {
            'local_vods_progress': {'5150': 600},
          });
      expect(h.player.feedPosition('5150', 700), isTrue,
          reason: 'five minutes in, going back is the user rewatching');
      await h.advance(tester, const Duration(seconds: 20));
      expect(h.storage.watchProgress['5150'], containsPair('p', 700));
      expect(h.storage.watchProgress['5150'], containsPair('b', 7200),
          reason: 'the flat copy knows only 600');

      await h.close(tester);
    });
  });

  group('the recently-watched list', () {
    testWidgets(
        'comes back on the next launch, takes a VOD that plays to its front, '
        'and holds at most the configured number', (tester) async {
      final h = ScreenHarness();
      final older = watched('801', 'Older session');
      final newer = watched('802', 'Newer session');
      final vod = await playLongVod(tester, h,
          recents: [newer, older], maxRecent: 2);

      await h.goHome(tester);
      expect(find.byTooltip('Newer session\nResume at 16% (1h0m0s)'),
          findsOneWidget);
      expect(find.byTooltip('Older session\nResume at 16% (1h0m0s)'),
          findsOneWidget);

      h.player.feedPosition(vod, 5400);
      await h.advance(tester, const Duration(seconds: 20));
      expect([for (final r in h.storage.recents) r['id']], [vod, '802'],
          reason: 'newest first, and the oldest one goes');
      expect(find.byTooltip('Long VOD\nResume at 50% (3h0m0s)'),
          findsOneWidget);
      expect(find.byTooltip('Older session\nResume at 16% (1h0m0s)'),
          findsNothing);

      await h.close(tester);
    });

    testWidgets(
        'a VOD removed from it in the Library loses its position too, and '
        'all three files are written', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final gone = watched('901', 'Streamed once');
      final kept = watched('902', 'Streamed twice');
      await h.launch(tester,
          favorites: ['alpha'],
          recents: [gone, kept],
          watchProgress: {
            '901': {'p': 600, 'u': 0, 'b': 600, 'ba': 0, 'r': <dynamic>[]},
            '902': {'p': 600, 'u': 0, 'b': 600, 'ba': 0, 'r': <dynamic>[]},
          });
      h.tray.choose('Open Library');
      await h.settle(tester);
      expect(find.text('Streamed once'), findsOneWidget);

      final config = h.storage.configWrites;
      await tester.tap(find.byTooltip('Remove from watch history').first);
      await h.settle(tester);
      expect(find.text('Streamed once'), findsNothing);
      expect(find.text('Streamed twice'), findsOneWidget);
      expect([for (final r in h.storage.recents) r['id']], ['902']);
      expect(h.storage.watchProgress.keys, ['902']);
      expect(h.storage.configWrites, config + 1);
      expect(
          (h.storage.config!['local_vods_progress'] as Map).containsKey('901'),
          isFalse);

      await h.close(tester);
    });
  });

  group('taking progress away', () {
    testWidgets('Unwatched on a selection clears the furthest point too',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final vod = h.helix.addVideo('alpha', title: 'Seen it');
      await h.launch(tester, favorites: ['alpha'], watchProgress: {
        vod: {'p': 3000, 'u': 0, 'b': 3500, 'ba': 0, 'r': <dynamic>[]},
      });
      await h.openChannel(tester, 'alpha');

      await tester.tap(find.text('Select'));
      await h.settle(tester);
      await tester.tap(find.text('Seen it'));
      await h.settle(tester);
      await tester.tap(find.text('Unwatched'));
      await h.settleRoute(tester);
      expect(find.textContaining('Marked 1 VODs unwatched here'),
          findsOneWidget,
          reason: 'it said "watched" for an Unwatched without a browser token');
      expect(h.storage.watchProgress.containsKey(vod), isFalse,
          reason: '"unwatched" has to mean unwatched');
      expect((h.storage.config!['local_vods_progress'] as Map)[vod], 0);

      await h.close(tester);
    });

    testWidgets(
        'Clear watch history in Settings empties every position, on disk and '
        'on the cards', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final vod = h.helix.addVideo('alpha', title: 'Half seen');
      await h.launch(tester,
          favorites: ['alpha'],
          size: const Size(1400, 1000),
          watchProgress: {
            vod: {'p': 1800, 'u': 0, 'b': 1800, 'ba': 0, 'r': <dynamic>[]},
            'elsewhere': {'p': 60, 'u': 0, 'b': 60, 'ba': 0, 'r': <dynamic>[]},
          });
      await h.openChannel(tester, 'alpha');
      double? onCard() =>
          tester.widget<TwitchVideoCard>(find.byType(TwitchVideoCard)).vod.watchProgress;
      expect(onCard(), 0.5, reason: 'precondition: the card shows how far');

      await tester.tap(find.byTooltip('Settings').first);
      await h.settleRoute(tester);
      await tester.ensureVisible(find.text('System'));
      await tester.tap(find.text('System'));
      await h.settleRoute(tester);
      await tester.ensureVisible(find.text('Clear Local Watch History'));
      await tester.tap(find.text('Clear Local Watch History'));
      await h.settleRoute(tester);
      await tester.tap(find.text('Clear history'));
      await h.settleRoute(tester);

      expect(find.text('Local watch progress history cleared!'),
          findsOneWidget);
      expect(h.storage.watchProgress, isEmpty);
      expect(h.storage.config!['local_vods_progress'], isEmpty);
      expect(onCard(), 0.0);

      await h.close(tester);
    });
  });

  testWidgets(
      'a VOD playing holds auto-play back, and stopping it lets the next pass '
      'play', (tester) async {
    // The map of playing VODs used never to be cleared, so the first VOD of a
    // session held auto-play and auto-download back until a restart.
    final h = ScreenHarness();
    h.helix.user('beta');
    final vod = await playLongVod(tester, h,
        channels: [TwitchChannel(username: 'beta', autoPlayLive: true)]);

    h.helix.goLive('beta');
    await h.advance(tester, const Duration(seconds: 61));
    expect(h.notifications.titles, contains('beta is now LIVE!'));
    expect(h.player.runningChannels, isEmpty,
        reason: 'the VOD on screen comes first');

    await h.playerExits(tester, vod);
    await h.advance(tester, const Duration(seconds: 61));
    expect(h.player.runningChannels, ['beta']);

    await h.close(tester);
  });
}
