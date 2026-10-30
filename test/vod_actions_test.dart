import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/settings_repository.dart';
import 'package:streamlink_gui/state/watch_history_controller.dart';
import 'package:streamlink_gui/widgets/shell/vod_actions.dart';

import 'support/fake_process.dart';
import 'support/memory_storage.dart';

/// VodActions on its own. What each button reaches through the screen is
/// main_screen_vods_test's; this is what the actions promise the screen
/// whatever the player service reports.
void main() {
  late MemoryStorageService storage;
  late SettingsRepository repository;
  late WatchHistoryController history;
  late Directory folder;

  setUp(() {
    storage = MemoryStorageService();
    repository = SettingsRepository(
      writeConfig: () async {},
      writeProgress: () async {},
      writeRecents: () async {},
    );
    history = WatchHistoryController(
      storage: storage,
      repository: repository,
      api: TwitchApiService(),
      settings: AppSettings.new,
      openVods: () => const [],
    );
    folder = Directory.systemTemp.createTempSync('streamlink_gui_vod_actions_');
  });

  tearDown(() {
    history.dispose();
    repository.dispose();
    storage.dispose();
    try {
      folder.deleteSync(recursive: true);
    } catch (_) {}
  });

  VodActions actions({required bool Function() mounted,
          required VoidCallback changed,
          PlayerService? player,
          Map<String, String> registry = const <String, String>{},
          List<String>? messages}) =>
      VodActions(
        // No callbacks bound: nothing reports the cancel to the screen but
        // the action itself.
        player: player ?? PlayerService(),
        api: TwitchApiService(),
        history: history,
        settings: () => AppSettings(vodDownloadFolder: folder.path),
        registry: () => registry,
        context: () => throw StateError('no dialog is asked for'),
        mounted: mounted,
        showMessage: (message, {required isError, action}) =>
            messages?.add(message),
        save: () async {},
        rescan: () {},
        changed: changed,
      );

  /// [id] as the queue holds it, without starting the queue's drain.
  TwitchVideo queued(PlayerService player, String id) =>
      player.queuedDownloadTasks[id] = TwitchVideo(
        id: id,
        title: 'VOD $id',
        duration: '1h0m0s',
        thumbnailUrl: '',
        viewCount: '1',
        publishedAt: DateTime(2026, 1, 1),
      );

  test('a cancel repaints the screen itself, and not once it has gone',
      () async {
    var repaints = 0;
    var mounted = true;
    final player = PlayerService();
    final vods = actions(
        mounted: () => mounted, changed: () => repaints++, player: player);
    queued(player, 'v1');
    queued(player, 'v2');

    await vods.cancelDownload('v1', 'alpha');
    expect(repaints, 1);

    mounted = false;
    await vods.cancelDownload('v2', 'alpha');
    expect(repaints, 1);
  });

  group('a VOD already downloaded', () {
    late FakeLauncher launcher;
    late PlayerService player;
    late File finished;
    setUp(() {
      launcher = FakeLauncher();
      player = PlayerService(
          startProcess: launcher.start, runProcess: FakeTaskkill(launcher).run);
      finished = File(p.join(folder.path, 'chan', 'T5 - v5.mp4'))
        ..createSync(recursive: true)
        ..writeAsStringSync('video');
    });
    tearDown(() async {
      await player.stopAll();
      for (final run in launcher.launched) {
        await run.exit(-1);
      }
    });

    TwitchVideo vod(String id) => TwitchVideo(
          id: id,
          title: 'T$id',
          duration: '1h0m0s',
          thumbnailUrl: '',
          viewCount: '0',
          publishedAt: DateTime(2026),
        );

    test('keeps its file when a queued download of it again is cancelled',
        () async {
      final vods = actions(
          mounted: () => true,
          changed: () {},
          player: player,
          registry: {'5': finished.path});
      final settings = AppSettings(vodDownloadFolder: folder.path);
      player.queueVodDownload(vod('1'), 'chan', settings, byHand: true);
      player.queueVodDownload(vod('5'), 'chan', settings, byHand: true);
      await pumpEventQueue();
      expect(player.downloadQueue, contains('5'));

      await vods.cancelDownload('5', 'chan');

      expect(player.downloadQueue, isNot(contains('5')));
      expect(finished.existsSync(), isTrue,
          reason: 'the extra download was called off, not the copy');
    });

    test('is left out of a selection\'s download, and said so', () async {
      final messages = <String>[];
      final vods = actions(
          mounted: () => true,
          changed: () {},
          player: player,
          registry: {'5': finished.path},
          messages: messages);

      vods.downloadSelection([vod('5'), vod('6')],
          channelName: () => 'chan', endSelection: () {});
      await pumpEventQueue();

      expect(launcher.launched.map((r) => r.arguments.last),
          ['https://twitch.tv/videos/6']);
      expect(messages, ['Queued 1 download; 1 already downloaded.']);
    });
  });

  test('a cancel of a download that is over leaves its file alone',
      () async {
    // A running download's Cancel is asked first, and it can finish while
    // the question is up. The cancel deletes every file of the VOD.
    var repaints = 0;
    final vods = actions(mounted: () => true, changed: () => repaints++);
    final finished = File('${folder.path}/alpha/Done - 9001.mp4')
      ..createSync(recursive: true)
      ..writeAsStringSync('video');

    await vods.cancelDownload('9001', 'alpha');
    expect(finished.existsSync(), isTrue);
    expect(repaints, 0, reason: 'nothing was cancelled');
  });
}
