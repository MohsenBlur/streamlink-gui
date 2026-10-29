import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/settings_repository.dart';
import 'package:streamlink_gui/state/watch_history_controller.dart';
import 'package:streamlink_gui/widgets/shell/vod_actions.dart';

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
          required VoidCallback changed, PlayerService? player}) =>
      VodActions(
        // No callbacks bound: nothing reports the cancel to the screen but
        // the action itself.
        player: player ?? PlayerService(),
        api: TwitchApiService(),
        history: history,
        settings: () => AppSettings(vodDownloadFolder: folder.path),
        registry: () => <String, String>{},
        context: () => throw StateError('no dialog is asked for'),
        mounted: mounted,
        showMessage: (_, {required isError, action}) {},
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
