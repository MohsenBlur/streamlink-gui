import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/widgets/twitch_video_card.dart';

import 'support/main_screen_harness.dart';

/// What a VOD's own buttons do, through the pumped screen (see
/// [ScreenHarness]): playing one, streamed or from disk, downloading it,
/// cancelling and deleting a download, and the same for a selection.
///
/// The player and the queue are the real PlayerService over fake processes
/// (player_*_test and download_queue_test have their rules); this is which
/// of them a button reaches, with what, and what the user is told.
void main() {
  late Directory folder;
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
    folder = Directory.systemTemp.createTempSync('streamlink_gui_screen_vods_');
  });
  tearDown(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
    try {
      folder.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppSettings withFolder() =>
      ScreenHarness.playbackSettings()..vodDownloadFolder = folder.path;

  /// A finished download of [id] on alpha, where yt-dlp leaves one.
  File downloaded(String id) =>
      File(p.join(folder.path, 'alpha', 'VOD $id - $id.mp4'))
        ..createSync(recursive: true)
        ..writeAsStringSync('video');

  /// Right-clicks [title]'s card and picks [item] from its menu.
  Future<void> fromMenu(
      WidgetTester tester, ScreenHarness h, String title, String item) async {
    await tester.tap(find.text(title).first, buttons: kSecondaryMouseButton);
    // The menu grows open; until it has, its items are clipped away.
    await h.advance(tester, const Duration(milliseconds: 500),
        step: const Duration(milliseconds: 100));
    await tester.tap(find.text(item).last);
    await h.settleRoute(tester);
  }

  TwitchVideoCard card(WidgetTester tester, String title) =>
      tester.widget<TwitchVideoCard>(find.ancestor(
          of: find.text(title).first, matching: find.byType(TwitchVideoCard)));

  /// Runs the clock until the downloaded-file scan has badged [title]'s
  /// card: the scan runs on an isolate, so real time has to pass for it.
  Future<void> untilBadged(
      WidgetTester tester, ScreenHarness h, String title) async {
    for (var i = 0; i < 200 && !card(tester, title).isDownloaded; i++) {
      await h.advance(tester, const Duration(seconds: 1));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await h.settle(tester);
    }
    expect(card(tester, title).isDownloaded, isTrue,
        reason: 'the scan found the file');
  }

  group('playing a VOD', () {
    testWidgets('streams it from Twitch, from where it was left',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', id: '7001', title: 'Long VOD', duration: '3h0m0s');
      await h.launch(tester,
          favorites: ['alpha'],
          settings: ScreenHarness.playbackSettings()
            ..seekableVodStreaming = false,
          watchProgress: {
            '7001': {'p': 1200, 'u': 0, 'b': 1200, 'ba': 0, 'r': <dynamic>[]},
          });
      await h.openChannel(tester, 'alpha');
      await tester.tap(find.text('Long VOD'));
      await h.settle(tester);

      final run = h.launcher.launched.single;
      expect(run.arguments,
          containsAllInOrder(['--hls-start-offset', '1200s', 'twitch.tv/videos/7001']));
      expect(h.player.playingVodIds, {'7001'});

      // Played again from Continue watching while it plays: said, not
      // silently refused.
      h.player.feedPosition('7001', 1300);
      await h.goHome(tester);
      await tester.tap(find.byTooltip('Long VOD\nResume at 12% (3h0m0s)'));
      await h.settleRoute(tester);
      expect(find.text('Already playing "Long VOD".'), findsOneWidget);
      expect(h.launcher.launched, hasLength(1));

      await h.close(tester);
    });

    testWidgets('plays a downloaded copy from disk rather than streaming it',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', id: '7002', title: 'On disk');
      final file = downloaded('7002');
      await h.launch(tester,
          favorites: ['alpha'],
          settings: withFolder(),
          config: {
            'downloaded_vods': {'7002': file.path},
          });
      await h.openChannel(tester, 'alpha');
      await tester.tap(find.text('On disk'));
      await h.settle(tester);

      final run = h.launcher.launched.single;
      expect(run.executable, r'C:\nowhere\player.exe');
      expect(run.arguments.last, file.path);
      expect(h.player.playingVodIds, {'7002'});

      await h.close(tester);
    });
  });

  group('deleting downloads', () {
    testWidgets(
        "a card's Delete download removes the file, forgets it, and says how "
        'many went', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', id: '7003', title: 'To delete');
      final file = downloaded('7003');
      await h.launch(tester,
          favorites: ['alpha'],
          settings: withFolder(),
          config: {
            'downloaded_vods': {'7003': file.path},
          });
      await h.openChannel(tester, 'alpha');
      await untilBadged(tester, h, 'To delete');

      await fromMenu(tester, h, 'To delete', 'Delete download');
      expect(file.existsSync(), isFalse);
      expect(find.text('Deleted 1 file(s) for VOD 7003.'), findsOneWidget);
      expect((h.storage.config!['downloaded_vods'] as Map).containsKey('7003'),
          isFalse);

      await h.close(tester);
    });

    testWidgets(
        "a selection's Delete files asks first, then deletes only what is "
        'downloaded among it', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', id: '7004', title: 'Streamed only');
      h.helix.addVideo('alpha', id: '7005', title: 'Downloaded one');
      final file = downloaded('7005');
      await h.launch(tester,
          favorites: ['alpha'],
          settings: withFolder(),
          config: {
            'downloaded_vods': {'7005': file.path},
          });
      await h.openChannel(tester, 'alpha');
      await tester.tap(find.text('Select'));
      await h.settle(tester);
      await tester.tap(find.text('All'));
      await h.settle(tester);

      await tester.tap(find.text('Delete files'));
      await h.settleRoute(tester);
      expect(find.text('Delete 1 downloaded VOD?'), findsOneWidget);
      await tester.tap(find.text('Keep them'));
      await h.settleRoute(tester);
      expect(file.existsSync(), isTrue, reason: 'kept, as asked');
      expect(find.text('2 selected'), findsOneWidget,
          reason: 'the selection stays for another go');

      await tester.tap(find.text('Delete files'));
      await h.settleRoute(tester);
      await tester.tap(find.text('Delete files').last);
      await h.settleRoute(tester);
      expect(file.existsSync(), isFalse);
      expect(find.text('Deleted 1 downloaded VOD files.'), findsOneWidget);
      expect(find.text('Select'), findsOneWidget, reason: 'selection ends');
      expect((h.storage.config!['downloaded_vods'] as Map), isEmpty);

      await h.close(tester);
    });

    testWidgets('a selection with nothing downloaded in it says so',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Streamed only');
      await h.launch(tester, favorites: ['alpha'], settings: withFolder());
      await h.openChannel(tester, 'alpha');
      await tester.tap(find.text('Select'));
      await h.settle(tester);
      await tester.tap(find.text('All'));
      await h.settle(tester);

      await tester.tap(find.text('Delete files'));
      await h.settleRoute(tester);
      expect(find.text('No fully downloaded VODs found among selection.'),
          findsOneWidget);

      await h.close(tester);
    });
  });

  group('downloading', () {
    testWidgets(
        'a selection of several asks for the order, and queues them in it',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final ids = [
        for (var day = 3; day >= 1; day--)
          h.helix.addVideo('alpha',
              title: 'Day $day',
              publishedAt: h.helix.now.subtract(Duration(days: day))),
      ];
      await h.launch(tester, favorites: ['alpha'], settings: withFolder());
      await h.openChannel(tester, 'alpha');
      await tester.tap(find.text('Select'));
      await h.settle(tester);
      await tester.tap(find.text('All'));
      await h.settle(tester);

      await tester.tap(find.text('Download'));
      await h.settleRoute(tester);
      expect(find.text('Download order'), findsOneWidget);
      expect(find.text('Select'), findsOneWidget,
          reason: 'selection ends as the order is asked');
      await tester.tap(find.text('Oldest first'));
      await h.settleRoute(tester);
      expect(find.text('Queueing 3 downloads...'), findsOneWidget);
      expect(h.player.downloadQueue, ids, reason: 'oldest first');
      expect(h.player.downloadChannelNames.values.toSet(), {'alpha'});

      await h.close(tester);
    });

    testWidgets('a selection of one is queued at once', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final id = h.helix.addVideo('alpha', title: 'Only one');
      await h.launch(tester, favorites: ['alpha'], settings: withFolder());
      await h.openChannel(tester, 'alpha');
      await tester.tap(find.text('Select'));
      await h.settle(tester);
      await tester.tap(find.text('Only one'));
      await h.settle(tester);
      await tester.tap(find.text('Download'));
      await h.settleRoute(tester);

      expect(find.text('Download order'), findsNothing);
      expect(h.player.downloadQueue, [id]);
      expect(find.text('Select'), findsOneWidget);

      await h.close(tester);
    });

    testWidgets(
        "a queued download is cancelled from its card's menu, and leaves the "
        'saved queue', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final id = h.helix.addVideo('alpha', title: 'Changed my mind');
      await h.launch(tester, favorites: ['alpha'], settings: withFolder());
      await h.openChannel(tester, 'alpha');
      // The VODs the next launch would queue again (DownloadsController).
      List<Object?> savedQueue() {
        final settings = h.storage.config!['settings'] as Map;
        return [
          for (final entry in settings['unfinished_downloads'] as List)
            ((entry as Map)['vod'] as Map)['id'],
        ];
      }

      await fromMenu(tester, h, 'Changed my mind', 'Download');
      expect(h.player.downloadQueue, [id]);
      expect(card(tester, 'Changed my mind').downloadStatus, isNotNull);
      await h.advance(tester, const Duration(seconds: 2));
      expect(savedQueue(), [id], reason: 'saved, so a crash does not lose it');

      await fromMenu(tester, h, 'Changed my mind', 'Cancel download');
      expect(find.text('Download cancelled.'), findsOneWidget);
      expect(h.player.downloadQueue, isEmpty);
      expect(card(tester, 'Changed my mind').downloadStatus, isNull);
      await h.advance(tester, const Duration(seconds: 2));
      expect(savedQueue(), isEmpty,
          reason: 'a cancelled download is not started again at the next '
              'launch');

      await h.close(tester);
    });
  });
}
