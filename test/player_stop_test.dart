import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';

import 'support/fake_process.dart';

/// Stopping things: what gets killed, how, and what the exit handlers make of
/// it. Driven through PlayerService's real code with fake children and a fake
/// taskkill, so nothing is started or killed for real.
void main() {
  late Directory temp;
  late FakeLauncher launcher;
  late FakeTaskkill taskkill;
  late PlayerService service;
  final stopped = <String, bool>{};
  final failedDownloads = <String>[];
  final logs = <String, List<String>>{};

  // A player the service has no special knowledge of: no control channel,
  // no mpv bridge, nothing polled.
  AppSettings settings() => AppSettings(
        playerType: 'custom',
        customPlayerPath: r'C:\nowhere\someplayer.exe',
        vodDownloadFolder: temp.path,
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('streamlink_gui_stop_');
    launcher = FakeLauncher();
    taskkill = FakeTaskkill(launcher);
    service =
        PlayerService(startProcess: launcher.start, runProcess: taskkill.run);
    stopped.clear();
    failedDownloads.clear();
    logs.clear();
    service
      ..onPlayerStopped = ((key, code, userInitiated) => stopped[key] = userInitiated)
      ..onDownloadFailed = ((id, title, code) => failedDownloads.add(id))
      ..onPlayerLog = ((key, line) => logs.putIfAbsent(key, () => []).add(line));
  });

  tearDown(() async {
    for (final p in launcher.launched) {
      await p.exit(0);
    }
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('stopAll ends every child with a single taskkill', () async {
    await service.launchStreamlinkForLive('alpha', true, 'Title', 'Game', settings());
    await service.launchStreamlinkForLive('beta', true, 'Title', 'Game', settings());
    service.queueVodDownload(
        TwitchVideo(
          id: '77',
          title: 'A VOD',
          duration: '1h0m0s',
          thumbnailUrl: '',
          viewCount: '0',
          publishedAt: DateTime(2026),
        ),
        'chan',
        settings());
    await pumpEventQueue();
    expect(launcher.launched, hasLength(3));

    await service.stopAll();
    await pumpEventQueue();

    if (Platform.isWindows) {
      // One process start and one process-table walk, not one each - and
      // not on the UI isolate.
      expect(taskkill.calls, [
        [
          '/F', '/T',
          for (final p in launcher.launched) ...['/PID', '${p.pid}'],
        ],
      ]);
    } else {
      expect(taskkill.calls, isEmpty);
      expect(launcher.launched.map((p) => p.killCount), everyElement(1));
    }
    expect(launcher.launched.every((p) => p.hasExited), isTrue);
    // Deliberate stops, not failures.
    expect(stopped, {'stream_alpha': true, 'stream_beta': true});
    expect(failedDownloads, isEmpty);
  });

  test('a Stop that taskkill cannot carry out is logged', () async {
    await service.launchStreamlinkForLive('alpha', true, 'Title', 'Game', settings());
    taskkill
      ..exitCode = 1
      ..stderr = 'ERROR: Access is denied.';

    await service.killLiveStream('alpha');

    if (Platform.isWindows) {
      expect(logs['stream_alpha']!.last,
          contains('Could not end the player process (taskkill exit 1)'));
      expect(logs['stream_alpha']!.last, contains('Access is denied'));
    } else {
      expect(launcher.launched.single.killCount, 1);
    }
  });
}
