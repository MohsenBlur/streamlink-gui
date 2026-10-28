import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';

import 'support/fake_process.dart';

/// The "Jump there" seek: it may only claim a jump the player acknowledged.
void main() {
  late Directory temp;
  late FakeLauncher launcher;
  late PlayerService service;
  late AppSettings settings;
  final logs = <String>[];
  final vod = TwitchVideo(
    id: '31337',
    title: 'Long VOD',
    duration: '2h0m0s',
    thumbnailUrl: '',
    viewCount: '0',
    publishedAt: DateTime(2026),
  );

  /// Puts VLC's web interface, answering every request with [status], on a
  /// port of its own - ports from 8089 up are shared with other test files
  /// running at the same time - and points the playing VOD at it.
  Future<List<String>> fakeVlcAnswering(int status) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) {
      requests.add(request.uri.toString());
      request.response
        ..statusCode = status
        ..close();
    });
    service.activePlayerPorts[vod.id] = server.port;
    return requests;
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('streamlink_gui_seek_');
    launcher = FakeLauncher();
    logs.clear();
    // A VLC by path, so the seek goes over VLC's HTTP interface. The poll is
    // slowed right down so the tracker stays out of the way.
    settings = AppSettings(
      playerType: 'custom',
      customPlayerPath: r'C:\nowhere\vlc.exe',
      vodDownloadFolder: temp.path,
    );
    service = PlayerService(
      startProcess: launcher.start,
      runProcess: FakeTaskkill(launcher).run,
      progressPollInterval: const Duration(minutes: 1),
    )..onPlayerLog = ((key, line) => logs.add(line));
    final file = File('${temp.path}${Platform.pathSeparator}Long VOD - 31337.mp4')
      ..writeAsStringSync('');
    await service.playDownloadedVod(file, vod, settings);
  });

  tearDown(() async {
    await service.stopAll();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('reports a jump the player acknowledged', () async {
    final requests = await fakeVlcAnswering(200);

    expect(await service.seekActiveVod(vod.id, 600, settings), isTrue);
    expect(requests.single, contains('command=seek&val=600'));
    expect(logs, contains('[System] Jumped to 600s at your request.'));
  });

  test('does not claim a jump the player could not be reached for', () async {
    // A port that was free a moment ago and has nothing on it now.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    service.activePlayerPorts[vod.id] = probe.port;
    await probe.close();

    expect(await service.seekActiveVod(vod.id, 600, settings), isFalse);
    expect(logs.where((l) => l.contains('Jumped')), isEmpty,
        reason: 'this used to follow the failure it had just logged');
    expect(logs.last, contains('Could not correct the playback position'));
  });

  test('does not claim a jump the player refused', () async {
    await fakeVlcAnswering(401); // VLC's answer to a wrong password

    expect(await service.seekActiveVod(vod.id, 600, settings), isFalse);
    expect(logs.where((l) => l.contains('Jumped')), isEmpty);
    expect(logs.last, contains('answered HTTP 401'));
  });

  test('a VOD with no player is not sought at all', () async {
    expect(await service.seekActiveVod('nope', 600, settings), isFalse);
  });
}
