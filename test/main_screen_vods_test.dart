import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_button.dart';
import 'package:streamlink_gui/widgets/twitch_video_card.dart';

import 'support/held_file_picker.dart';
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
        "a card's Delete download asks first, then removes the file, forgets "
        'it, and says how many went', (tester) async {
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

      // Deleted for good, and maybe the only copy left: asked, as the
      // Library's Delete download is.
      await fromMenu(tester, h, 'To delete', 'Delete download');
      expect(find.text('Delete download?'), findsOneWidget);
      expect(
          find.text('Delete the downloaded file for "To delete"? This cannot '
              'be undone.'),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await h.settleRoute(tester);
      expect(file.existsSync(), isTrue, reason: 'kept, as asked');
      expect(card(tester, 'To delete').isDownloaded, isTrue);

      await fromMenu(tester, h, 'To delete', 'Delete download');
      await tester.tap(find.text('Delete'));
      await h.settleRoute(tester);
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

  group('narrowing and selecting', () {
    /// alpha's four VODs, by title, with the games their chapters name.
    Future<ScreenHarness> openAlpha(WidgetTester tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.user('beta');
      h.helix.addVideo('beta', title: 'Elsewhere');
      for (final (title, games) in [
        ('Opening prep', ['Chess']),
        ('Endgame study', ['Chess']),
        ('Any% run', ['Mario']),
        ('Mixed night', ['Chess', 'Mario']),
      ]) {
        h.helix.videoGames[h.helix.addVideo('alpha', title: title)] = games;
      }
      await h.launch(tester, favorites: ['alpha', 'beta'], settings: withFolder());
      await h.openChannel(tester, 'alpha');
      return h;
    }

    Set<String> shown(WidgetTester tester) => {
          for (final card
              in tester.widgetList<TwitchVideoCard>(find.byType(TwitchVideoCard)))
            card.vod.title,
        };

    Future<void> tapText(
        WidgetTester tester, ScreenHarness h, String text) async {
      await tester.tap(find.text(text).first);
      await h.settle(tester);
    }

    Future<void> chip(WidgetTester tester, ScreenHarness h, String game) async {
      await tester.tap(find.widgetWithText(NeuButton, game).first);
      await h.settle(tester);
    }

    Future<void> search(
        WidgetTester tester, ScreenHarness h, String text) async {
      await tapText(tester, h, 'Display');
      await h.settleRoute(tester);
      await tester.enterText(
          find.byWidgetPredicate((w) =>
              w is TextField && w.decoration?.hintText == 'Filter VODs...'),
          text);
      await h.settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await h.settleRoute(tester);
    }

    testWidgets(
        'a game, the search and All: All selects what both leave on show, '
        'and All Games lets the search alone narrow it', (tester) async {
      final h = await openAlpha(tester);
      expect(shown(tester), hasLength(4));

      await chip(tester, h, 'Mario');
      expect(shown(tester), {'Any% run', 'Mixed night'});
      await search(tester, h, 'night');
      expect(shown(tester), {'Mixed night'}, reason: 'both narrow it');

      await tapText(tester, h, 'Select');
      await tapText(tester, h, 'All');
      expect(find.text('1 selected'), findsOneWidget,
          reason: 'All is what is on show, not the whole list');

      await chip(tester, h, 'All Games');
      expect(shown(tester), {'Mixed night'}, reason: 'the search still holds');
      await tapText(tester, h, 'All');
      expect(find.text('1 selected'), findsOneWidget);

      // The search lives in Display, which selection mode replaces; leaving
      // it drops the selection.
      await tester.tap(find.byTooltip('Leave selection mode (Esc)'));
      await h.settle(tester);
      await search(tester, h, '');
      expect(shown(tester), hasLength(4));

      // Two games are either.
      await chip(tester, h, 'Chess');
      await chip(tester, h, 'Mario');
      expect(shown(tester), hasLength(4));
      await chip(tester, h, 'Mario');
      expect(shown(tester), {'Opening prep', 'Endgame study', 'Mixed night'});
      await tapText(tester, h, 'Select');
      expect(find.text('Select videos'), findsOneWidget,
          reason: 'nothing kept from before');
      await tapText(tester, h, 'All');
      expect(find.text('3 selected'), findsOneWidget);
      await tapText(tester, h, 'Opening prep');
      expect(find.text('2 selected'), findsOneWidget);
      await tapText(tester, h, 'None');
      expect(find.text('Select videos'), findsOneWidget);

      await h.close(tester);
    });

    testWidgets(
        'another channel starts with no game filter and nothing selected',
        (tester) async {
      final h = await openAlpha(tester);
      await chip(tester, h, 'Mario');
      await tapText(tester, h, 'Select');
      await tapText(tester, h, 'Any% run');
      expect(find.text('1 selected'), findsOneWidget);

      await h.openChannel(tester, 'beta');
      expect(shown(tester), {'Elsewhere'});
      await h.openChannel(tester, 'alpha');
      expect(shown(tester), hasLength(4), reason: 'the filter went');
      expect(find.text('Select videos'), findsOneWidget,
          reason: 'the selection went; selection mode stays');

      await h.close(tester);
    });

    testWidgets('Esc leaves selection mode, as its exit button says',
        (tester) async {
      final h = await openAlpha(tester);
      await tapText(tester, h, 'Select');
      await tapText(tester, h, 'Any% run');
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byTooltip('Leave selection mode (Esc)'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await h.settle(tester);
      expect(find.text('1 selected'), findsNothing);
      expect(find.text('Select'), findsOneWidget,
          reason: 'the toolbar is back');
      expect(card(tester, 'Any% run').isMultiSelectMode, isFalse);

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

    testWidgets(
        "a running download's card Cancel asks first, as the Library's does",
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Half way');
      final settings = withFolder();
      await h.launch(tester, favorites: ['alpha'], settings: settings);
      await h.openChannel(tester, 'alpha');
      h.player.queueVodDownload(card(tester, 'Half way').vod, 'alpha', settings);
      await h.settle(tester);
      final ytDlp = h.launcher.launched.single;
      ytDlp.printOut('[download]  50.0% of 1.00GiB at 2.00MiB/s ETA 04:00\n');
      await h.settle(tester);

      // Its partial file goes with it.
      await fromMenu(tester, h, 'Half way', 'Cancel download');
      expect(find.text('Cancel this download?'), findsOneWidget);
      await tester.tap(find.text('Keep running'));
      await h.settleRoute(tester);
      expect(ytDlp.hasExited, isFalse, reason: 'kept, as asked');
      expect(card(tester, 'Half way').downloadStatus, isNotNull);

      await fromMenu(tester, h, 'Half way', 'Cancel download');
      await tester.tap(find.text('Cancel download').last);
      await h.settleRoute(tester);
      // taskkill's yt-dlp ends on a zero-length timer.
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
      expect(ytDlp.hasExited, isTrue);
      expect(find.text('Download cancelled.'), findsOneWidget);
      expect(card(tester, 'Half way').downloadStatus, isNull);

      await h.close(tester);
    });

    group('to a folder that cannot be made', () {
      // An unplugged drive, a share gone away, a parent that is a file. The
      // download used to be queued anyway, and fail with exit code -1. The
      // folder prompt it asks with instead was otherwise never seen: an
      // empty folder setting is always filled in with Downloads\TwitchVODs.
      late String unusable;
      setUp(() {
        final blocker = File(p.join(folder.path, 'not a folder'))
          ..writeAsStringSync('');
        unusable = p.join(blocker.path, 'VODs');
      });

      Future<(ScreenHarness, String)> askedWhere(WidgetTester tester) async {
        final h = ScreenHarness();
        h.helix.user('alpha');
        final id = h.helix.addVideo('alpha', title: 'Somewhere else');
        await h.launch(tester,
            favorites: ['alpha'],
            settings: withFolder()..vodDownloadFolder = unusable);
        await h.openChannel(tester, 'alpha');
        await fromMenu(tester, h, 'Somewhere else', 'Download');
        expect(find.text('Where should VODs be saved?'), findsOneWidget);
        expect(find.textContaining(unusable), findsOneWidget,
            reason: 'it says which folder could not be used');
        return (h, id);
      }

      testWidgets('asks for another, and downloads there', (tester) async {
        final picker = HeldFilePicker.install();
        final (h, id) = await askedWhere(tester);
        await tester.tap(find.text('Choose folder'));
        await tester.pump();
        picker.folders.single.complete(folder.path);
        await h.settleRoute(tester);

        expect(find.text('Where should VODs be saved?'), findsNothing);
        expect(h.storage.savedSettings?.vodDownloadFolder, folder.path);
        expect(h.player.downloadQueue, [id]);
        // Queued by hand, it waits for its archive line to be taken out,
        // which is real file I/O.
        for (var i = 0; i < 100 && h.launcher.launched.isEmpty; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await h.settle(tester);
        }
        expect(h.launcher.launched.single.arguments,
            contains(startsWith('${folder.path}/alpha/')),
            reason: "yt-dlp writes into the new folder's channel folder");

        await h.close(tester);
      });

      testWidgets('Cancel downloads nothing and keeps the folder setting',
          (tester) async {
        HeldFilePicker.install();
        final (h, _) = await askedWhere(tester);
        await tester.tap(find.text('Cancel'));
        await h.settleRoute(tester);

        expect(find.text('Download cancelled: the download folder could not '
            'be used.'), findsOneWidget);
        expect(h.player.downloadQueue, isEmpty);
        expect(h.launcher.launched, isEmpty);
        await h.advance(tester, const Duration(seconds: 2));
        expect(h.storage.savedSettings?.vodDownloadFolder ?? unusable,
            unusable,
            reason: 'kept, for when the drive is back');

        await h.close(tester);
      });
    });
  });
}
