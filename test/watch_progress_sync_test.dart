import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';

import 'support/fake_process.dart';
import 'support/fake_vlc.dart';

/// Records the positions that would have been pushed to Twitch.
class _RecordingApi extends TwitchApiService {
  final List<int> pushed = [];

  @override
  Future<void> syncSingleVODProgressDirect(
      String videoID, int position, String webToken) async {
    pushed.add(position);
  }
}

/// The real progress tracker, polling a fake VLC, deciding what reaches the
/// local store and what reaches Twitch.
void main() {
  late Directory temp;
  late FakeLauncher launcher;
  late _RecordingApi api;
  late PlayerService service;
  late FakeVlc vlc;
  final vod = TwitchVideo(
    id: '9001',
    title: 'Long VOD',
    duration: '3h0m0s',
    thumbnailUrl: '',
    viewCount: '0',
    publishedAt: DateTime(2026),
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('streamlink_gui_progress_');
    launcher = FakeLauncher();
    api = _RecordingApi();
    service = PlayerService(
      startProcess: launcher.start,
      runProcess: FakeTaskkill(launcher).run,
      progressPollInterval: const Duration(milliseconds: 40),
      apiService: api,
    );
  });

  tearDown(() async {
    await service.stopAll();
    await vlc.close();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Plays a downloaded copy in "VLC" until [enough] positions were recorded.
  Future<void> play(bool Function() enough) async {
    final file = File('${temp.path}${Platform.pathSeparator}Long VOD - 9001.mp4')
      ..writeAsStringSync('');
    await service.playDownloadedVod(
        file,
        vod,
        AppSettings(
          playerType: 'custom',
          customPlayerPath: r'C:\nowhere\vlc.exe',
          twitchWebOauthToken: 'oauth:webtoken',
          vodDownloadFolder: temp.path,
        ));
    vlc = await FakeVlc.serve(service.activePlayerPorts[vod.id]!, startAt: 30);
    await waitFor(enough, reason: 'positions to be recorded');
    await pumpEventQueue();
  }

  test('a position the local store refuses never reaches Twitch', () async {
    final recorded = <int>[];
    // The store's verdict on a failed resume: refuse the first positions.
    service.recordWatchProgress = (id, position, progress, ageMs) {
      recorded.add(position);
      return recorded.length > 2;
    };

    await play(() => recorded.length >= 5);

    final refused = recorded.take(2);
    expect(api.pushed, isNotEmpty, reason: 'kept positions are still synced');
    for (final position in refused) {
      expect(api.pushed, isNot(contains(position)),
          reason: 'refused locally at ${position}s, so Twitch must not get it');
    }
    expect(api.pushed, everyElement(isIn(recorded.skip(2))));
  });

  test('every position the local store keeps is synced', () async {
    final recorded = <int>[];
    service.recordWatchProgress = (id, position, progress, ageMs) {
      recorded.add(position);
      return true;
    };

    await play(() => recorded.length >= 3);

    expect(api.pushed, containsAll(recorded.take(3)));
  });
}
