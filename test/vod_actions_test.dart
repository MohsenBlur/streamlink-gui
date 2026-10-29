import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
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
          required VoidCallback changed}) =>
      VodActions(
        // No callbacks bound: nothing reports the cancel to the screen but
        // the action itself.
        player: PlayerService(),
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

  test('a cancel repaints the screen itself, and not once it has gone',
      () async {
    var repaints = 0;
    var mounted = true;
    final vods = actions(mounted: () => mounted, changed: () => repaints++);

    await vods.cancelDownload('v1', 'alpha');
    expect(repaints, 1);

    mounted = false;
    await vods.cancelDownload('v2', 'alpha');
    expect(repaints, 1);
  });
}
