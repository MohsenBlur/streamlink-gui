import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/desktop_shell.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/widgets/activity_pill.dart';
import 'package:streamlink_gui/widgets/shell/home_view.dart';
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

  group('several downloads at once', () {
    // Simultaneous downloads in Settings. Each surface read the service's
    // maps, which several running at once had never filled.
    List<String> started(ScreenHarness h) => [
          for (final run in h.launcher.launched)
            if (run.arguments.isNotEmpty &&
                run.arguments.last.startsWith('https://twitch.tv/videos/'))
              run.arguments.last.substring('https://twitch.tv/videos/'.length),
        ];

    /// A config whose saved queue holds [titles], in order, on alpha - what
    /// the last run left unfinished. With [holdStarts], each yt-dlp's start
    /// waits at the launcher's gate.
    Future<(ScreenHarness, List<String>)> resumed(
        WidgetTester tester, List<String> titles, AppSettings settings,
        {bool holdStarts = false}) async {
      final h = ScreenHarness();
      if (holdStarts) h.launcher.startGate = Completer<void>();
      h.helix.user('alpha');
      final ids = [for (final title in titles) h.helix.addVideo('alpha', title: title)];
      settings.unfinishedDownloads = [
        for (var i = 0; i < ids.length; i++)
          {
            'vod': TwitchVideo(
              id: ids[i],
              title: titles[i],
              duration: '1h0m0s',
              thumbnailUrl: '',
              viewCount: '0',
              publishedAt: DateTime(2026),
            ).toJson(),
            'channelName': 'alpha',
          },
      ];
      await h.launch(tester, favorites: ['alpha'], settings: settings);
      return (h, ids);
    }

    List<Object?> savedQueue(ScreenHarness h) {
      final settings = h.storage.config!['settings'] as Map;
      return [
        for (final entry in settings['unfinished_downloads'] as List)
          ((entry as Map)['vod'] as Map)['id'],
      ];
    }

    Finder onHome(String text) => find.descendant(
        of: find.byType(HomeView), matching: find.text(text));

    testWidgets(
        'resumed at launch, run as many at once as allowed, each shown on Home '
        'and in the pill; one finishing starts the next and the saved queue '
        'keeps its order', (tester) async {
      final (h, ids) = await resumed(tester, ['One', 'Two', 'Three', 'Four'],
          withFolder()..simultaneousDownloads = 3);

      expect(started(h), ids.take(3).toList());
      for (final run in h.launcher.launched) {
        run.printOut('[download]  10.0% of ~1.00GiB at 2.00MiB/s ETA 05:00\n');
      }
      await h.settle(tester);
      expect(find.byTooltip('3 downloading · 1 queued'), findsOneWidget);
      for (final title in ['One', 'Two', 'Three']) {
        expect(onHome(title), findsOneWidget,
            reason: '"$title" runs, and Home showed only two');
      }
      expect(onHome('Four'), findsNothing, reason: 'queued, not running');

      // The second finishes first.
      File(p.join(folder.path, 'alpha', 'Two - ${ids[1]}.mp4'))
        ..createSync(recursive: true)
        ..writeAsStringSync('video');
      unawaited(h.launcher.launched[1].exit(0));
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
      await h.settleRoute(tester);
      expect(find.text('Download completed: Two'), findsOneWidget);
      expect(h.notifications.titles, ['VOD Download Completed'],
          reason: 'one toast for the one that finished');
      expect(started(h), [...ids.take(3), ids[3]]);
      await h.advance(tester, const Duration(seconds: 2));
      expect(savedQueue(h), [ids[0], ids[2], ids[3]]);

      await h.close(tester);
    });

    testWidgets(
        'each shows as downloading once its yt-dlp starts, before it prints '
        'any progress', (tester) async {
      // yt-dlp prints no progress until it has read the VOD's formats, and
      // slept for as long as a yt-dlp config asks - up to half a minute with
      // some. Until then the pill counted the downloads started at once as
      // queued, and Home listed none of them.
      final (h, ids) = await resumed(tester, ['One', 'Two', 'Three', 'Four'],
          withFolder()..simultaneousDownloads = 3,
          holdStarts: true);
      expect(h.launcher.starting, 3);
      expect(onHome('One'), findsNothing, reason: 'no yt-dlp yet');

      // The screen has drawn everything else by now: these starts are all
      // that is left to show.
      h.launcher.startGate!.complete();
      h.launcher.startGate = null;
      await h.settle(tester);
      expect(started(h), ids.take(3).toList());

      expect(find.byTooltip('3 downloading · 1 queued'), findsOneWidget);
      for (final title in ['One', 'Two', 'Three']) {
        expect(onHome(title), findsOneWidget, reason: '"$title" runs');
      }
      expect(onHome('Four'), findsNothing, reason: 'queued, not running');

      await h.close(tester);
    });

    testWidgets('raised in Settings, more start on Save', (tester) async {
      // Otherwise only a download ending, or another queued, starts one.
      final (h, ids) =
          await resumed(tester, ['One', 'Two', 'Three'], withFolder());
      expect(started(h), [ids[0]], reason: 'one at a time by default');

      await tester.tap(find.byTooltip('Settings').first);
      await h.settleRoute(tester);
      await tester.tap(find.text('Downloads'));
      await h.settleRoute(tester);
      final slider = find.byWidgetPredicate((w) =>
          w is Slider && w.max == AppSettings.maxSimultaneousDownloads);
      await tester.ensureVisible(slider);
      tester.widget<Slider>(slider).onChanged!(3);
      await h.settle(tester);
      expect(find.textContaining('Up to 3 downloads at once.'), findsOneWidget);
      await tester.tap(find.text('Save changes'));
      await h.settleRoute(tester);

      expect(h.storage.savedSettings?.simultaneousDownloads, 3);
      expect(started(h), ids);

      await h.close(tester);
    });
  });
}
