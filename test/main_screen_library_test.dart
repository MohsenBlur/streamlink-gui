import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';

import 'support/main_screen_harness.dart';

/// The Library, through the pumped screen (see [ScreenHarness]): opening and
/// leaving it, what it lists, and what its rows' buttons do. Building the
/// rows is library_entries_test's; the row widget is library_view's own.
void main() {
  late Directory folder;
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
    folder = Directory.systemTemp.createTempSync('streamlink_gui_screen_lib_');
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

  File downloaded(String id, String title) =>
      File(p.join(folder.path, 'alpha', '$title - $id.mp4'))
        ..createSync(recursive: true)
        ..writeAsStringSync('video');

  TwitchVideo streamed(String id, String title) => TwitchVideo(
        id: id,
        title: title,
        duration: '1h0m0s',
        thumbnailUrl: '',
        viewCount: '3',
        publishedAt: DateTime.utc(2026, 10, 1),
        watchPosition: 600,
        watchProgress: 600 / 3600,
      );

  Future<void> openLibrary(WidgetTester tester, ScreenHarness h) async {
    h.tray.choose('Open Library');
    await h.settle(tester);
    expect(find.text('Library'), findsWidgets);
  }

  testWidgets(
      'lists the downloads and the streamed history, and plays each the way '
      'it can be played', (tester) async {
    final h = ScreenHarness();
    final file = downloaded('8001', 'Great run');
    await h.launch(tester,
        settings: withFolder(),
        config: {
          'downloaded_vods': {'8001': file.path},
        },
        recents: [streamed('8002', 'Watched online')]);
    await openLibrary(tester, h);
    expect(find.text('Great run'), findsOneWidget);
    expect(find.text('Watched online'), findsOneWidget);
    expect(find.byTooltip('Back to Home (Esc)'), findsOneWidget,
        reason: 'opened over the welcome screen');

    await tester.tap(find.byTooltip('Play local file'));
    await h.settle(tester);
    expect(h.launcher.launched.single.arguments.last, file.path);

    await tester.tap(find.byTooltip('Stream from Twitch'));
    await h.settle(tester);
    expect(h.launcher.launched, hasLength(2));
    expect(h.launcher.launched.last.arguments, contains('twitch.tv/videos/8002'));
    expect(h.player.playingVodIds, {'8001', '8002'});

    await h.close(tester);
  });

  testWidgets(
      'Delete download asks first: Cancel keeps the file, Delete removes it '
      'and its row', (tester) async {
    final h = ScreenHarness();
    final file = downloaded('8003', 'Old run');
    await h.launch(tester,
        settings: withFolder(),
        config: {
          'downloaded_vods': {'8003': file.path},
        });
    await openLibrary(tester, h);

    await tester.tap(find.byTooltip('Delete download'));
    await h.settleRoute(tester);
    expect(find.text('Delete download?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await h.settleRoute(tester);
    expect(file.existsSync(), isTrue);
    expect(find.text('Old run'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete download'));
    await h.settleRoute(tester);
    await tester.tap(find.text('Delete'));
    await h.settleRoute(tester);
    expect(file.existsSync(), isFalse);
    expect(find.text('Old run'), findsNothing, reason: 'the rows are rebuilt');
    expect(find.text('Deleted 1 file(s) for VOD 8003.'), findsOneWidget);
    expect((h.storage.config!['downloaded_vods'] as Map), isEmpty);

    await h.close(tester);
  });

  testWidgets('Show in Explorer hands the file to the shell', (tester) async {
    final h = ScreenHarness();
    final file = downloaded('8004', 'Keeper');
    await h.launch(tester,
        settings: withFolder(),
        config: {
          'downloaded_vods': {'8004': file.path},
        });
    await openLibrary(tester, h);
    await tester.tap(find.byTooltip('Show in Explorer'));
    await h.settle(tester);
    expect(h.shell.revealed, [file.path]);

    await h.close(tester);
  });

  testWidgets(
      'a download that completes while it is open joins it, and one deleted '
      'behind its back goes at the next rescan', (tester) async {
    final h = ScreenHarness();
    final gone = downloaded('8005', 'Deleted elsewhere');
    await h.launch(tester,
        settings: withFolder(),
        config: {
          'downloaded_vods': {'8005': gone.path},
        });
    await openLibrary(tester, h);
    expect(find.text('Deleted elsewhere'), findsOneWidget);

    final vod = TwitchVideo(
      id: '8006',
      title: 'Fresh download',
      duration: '1h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime.utc(2026, 10, 20),
    );
    h.player.queueVodDownload(vod, 'alpha', withFolder());
    await h.settle(tester);
    final ytDlp = h.launcher.launched.single;
    downloaded('8006', 'Fresh download');
    unawaited(ytDlp.exit(0));
    await h.advance(tester, const Duration(milliseconds: 50),
        step: const Duration(milliseconds: 10));
    expect(find.text('Fresh download'), findsOneWidget);

    gone.deleteSync();
    await tester.tap(find.byTooltip('Rescan the download folder'));
    await h.settle(tester);
    expect(find.text('Deleted elsewhere'), findsNothing,
        reason: 'a row is only built for a file that is there');

    await h.close(tester);
  });

  testWidgets(
      'a channel picked in the sidebar replaces it; and while it shows, the '
      "open channel's new VOD is announced", (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.addVideo('alpha', title: 'Older broadcast');
    await h.launch(tester, favorites: ['alpha']);
    await h.openChannel(tester, 'alpha');
    await openLibrary(tester, h);
    expect(find.byTooltip('Back to alpha (Esc)'), findsOneWidget);

    // The grid is behind the Library: nothing on screen shows the VOD
    // arriving, so the toast does.
    h.helix.addVideo('alpha',
        title: 'Published meanwhile',
        publishedAt: h.helix.now.add(const Duration(minutes: 1)));
    await h.advance(tester, const Duration(minutes: 5));
    expect(h.notifications.titles, contains('New VOD from alpha'));

    await h.openChannel(tester, 'alpha');
    expect(find.byTooltip('Back to alpha (Esc)'), findsNothing);
    expect(find.text('Published meanwhile'), findsOneWidget);

    await h.close(tester);
  });
}

