import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/desktop_shell.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/widgets/activity_pill.dart';
import 'package:streamlink_gui/widgets/twitch_video_card.dart';

import 'support/main_screen_harness.dart';

/// What the player service reports, and what the screen does with each
/// report: the activity pill, the cards, the messages and the toasts. The
/// service's own side - when it reports what - is the player_* and
/// download_* tests'.
void main() {
  late Directory folder;
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
    folder = Directory.systemTemp.createTempSync('streamlink_gui_screen_events_');
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

  Finder inPill(String text) => find.descendant(
      of: find.byType(ActivityPill), matching: find.textContaining(text));

  TwitchVideoCard card(WidgetTester tester, String title) =>
      tester.widget<TwitchVideoCard>(find.byWidgetPredicate(
          (w) => w is TwitchVideoCard && w.vod.title == title));

  Future<void> play(WidgetTester tester, ScreenHarness h, String title) async {
    await tester.tap(find.descendant(
        of: find.byType(TwitchVideoCard), matching: find.text(title)));
    await h.settle(tester);
  }

  group('a player', () {
    testWidgets('playing is named in the activity pill, and leaves it when it '
        'stops', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final vod = h.helix.addVideo('alpha', title: 'Long VOD');
      await h.launch(tester,
          favorites: ['alpha'], settings: ScreenHarness.playbackSettings());
      await h.openChannel(tester, 'alpha');
      expect(inPill('Long VOD'), findsNothing);

      await play(tester, h, 'Long VOD');
      expect(inPill('Long VOD'), findsOneWidget);
      expect(card(tester, 'Long VOD').isPlaying, isTrue);

      await h.playerExits(tester, vod);
      expect(inPill('Long VOD'), findsNothing);
      expect(card(tester, 'Long VOD').isPlaying, isFalse);
      expect(find.textContaining('Playback failed'), findsNothing,
          reason: 'a clean exit');

      await h.close(tester);
    });

    testWidgets(
        'that fails says so, with its log a tap away; with the window in the '
        'tray, a toast says so too; a Stop is not a failure', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final first = h.helix.addVideo('alpha', title: 'First');
      final second = h.helix.addVideo('alpha', title: 'Second');
      final third = h.helix.addVideo('alpha', title: 'Third');
      await h.launch(tester,
          favorites: ['alpha'], settings: ScreenHarness.playbackSettings());
      await h.openChannel(tester, 'alpha');

      await play(tester, h, 'First');
      await h.playerExits(tester, first, exitCode: 1);
      await h.settleRoute(tester);
      expect(find.text('Playback failed for VOD: First'), findsOneWidget);
      expect(h.notifications.titles, isEmpty,
          reason: 'the user is looking at the message already');
      await tester.tap(find.text('View log'));
      await h.settleRoute(tester);
      expect(find.text('Diagnostics log'), findsOneWidget);
      await tester.tap(find.text('Close').last);
      await h.settleRoute(tester);

      await play(tester, h, 'Second');
      h.tray.choose('Hide App');
      await h.settle(tester);
      await h.playerExits(tester, second, exitCode: 1);
      expect(h.notifications.titles, ['Playback failed']);

      h.tray.fire(TrayEvent.click);
      await h.settle(tester);
      await play(tester, h, 'Third');
      unawaited(h.player.killProcess(third));
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
      await h.settleRoute(tester);
      expect(h.player.playingVodIds, isEmpty);
      expect(find.text('Playback failed for VOD: Third'), findsNothing);

      await h.close(tester);
    });
  });

  group('a download', () {
    Future<(ScreenHarness, String)> queued(WidgetTester tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final id = h.helix.addVideo('alpha', title: 'Big VOD');
      await h.launch(tester, favorites: ['alpha'], settings: withFolder());
      await h.openChannel(tester, 'alpha');
      h.player.queueVodDownload(
          card(tester, 'Big VOD').vod, 'alpha', withFolder());
      await h.settle(tester);
      expect(h.launcher.launched, hasLength(1),
          reason: 'precondition: its yt-dlp is running');
      return (h, id);
    }

    /// The VODs the config's saved download queue lists: what the next
    /// launch queues again (DownloadsController).
    List<Object?> savedQueue(ScreenHarness h) {
      final settings = h.storage.config!['settings'] as Map;
      return [
        for (final entry in settings['unfinished_downloads'] as List)
          ((entry as Map)['vod'] as Map)['id'],
      ];
    }

    testWidgets("reports its progress on its card and in the pill",
        (tester) async {
      final (h, id) = await queued(tester);
      h.launcher.launched.single
          .printOut('[download]  42.0% of 1.00GiB at 2.00MiB/s ETA 00:10\n');
      await h.settle(tester);
      expect(card(tester, 'Big VOD').downloadStatus,
          'Downloading: 42.0% (2.00MiB/s)');
      expect(card(tester, 'Big VOD').downloadProgress, closeTo(0.42, 1e-9));
      expect(inPill('42% · Big VOD'), findsOneWidget);

      await h.close(tester);
    });

    testWidgets(
        'that completes is registered and saved, and said, with a toast, and '
        'leaves the saved queue', (tester) async {
      final (h, id) = await queued(tester);
      await h.advance(tester, const Duration(seconds: 2));
      expect(savedQueue(h), [id],
          reason: 'precondition: saved while it runs, so a crash keeps it');
      final file = File(p.join(folder.path, 'alpha', 'Big VOD - $id.mp4'))
        ..createSync(recursive: true)
        ..writeAsStringSync('video');
      unawaited(h.launcher.launched.single.exit(0));
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
      await h.settleRoute(tester);
      expect(find.text('Download completed: Big VOD'), findsOneWidget);
      expect(h.notifications.titles, ['VOD Download Completed']);
      expect(inPill('Big VOD'), findsNothing);

      await h.advance(tester, const Duration(seconds: 2));
      expect((h.storage.config!['downloaded_vods'] as Map)[id], file.path);
      expect(h.storage.config!['download_history'], contains(id));
      expect(savedQueue(h), isEmpty,
          reason: 'the next launch would download it again');

      await h.close(tester);
    });

    testWidgets(
        'that fails says so, with its log, and with a toast, and leaves the '
        'saved queue', (tester) async {
      final (h, id) = await queued(tester);
      await h.advance(tester, const Duration(seconds: 2));
      expect(savedQueue(h), [id], reason: 'precondition: saved while it runs');
      unawaited(h.launcher.launched.single.exit(1));
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
      await h.settleRoute(tester);
      expect(find.text('Download failed for: Big VOD (Exit code 1)'),
          findsOneWidget);
      expect(find.text('View log'), findsOneWidget);
      expect(h.notifications.titles, ['VOD Download Failed']);
      expect(card(tester, 'Big VOD').downloadStatus, isNull);
      await h.advance(tester, const Duration(seconds: 2));
      expect(savedQueue(h), isEmpty,
          reason: 'a failure is not retried at every launch');

      await h.close(tester);
    });

    testWidgets('that fails toasts only with download notifications on',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Big VOD');
      final quiet = withFolder()..notifyDownloadComplete = false;
      await h.launch(tester, favorites: ['alpha'], settings: quiet);
      await h.openChannel(tester, 'alpha');
      h.player.queueVodDownload(card(tester, 'Big VOD').vod, 'alpha', quiet);
      await h.settle(tester);
      unawaited(h.launcher.launched.single.exit(1));
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
      expect(h.notifications.titles, isEmpty);

      await h.close(tester);
    });
  });
}
