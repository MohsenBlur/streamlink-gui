import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';

import 'support/fake_process.dart';

/// The port each player's control interface (and the mpv bridge) is given.
/// A player that cannot bind its port has no interface, so the tracker polls
/// nothing - or someone else's server - for the whole session.
void main() {
  test('skips a port another program is already listening on', () async {
    ServerSocket? foreign;
    try {
      foreign = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, PlayerService.firstPlayerPort);
    } on SocketException {
      // Something on this machine already holds it: the same situation.
    }
    try {
      expect(await PlayerService().getNextAvailablePlayerPort(),
          isNot(PlayerService.firstPlayerPort));
    } finally {
      await foreign?.close();
    }
  });

  test('two launches at once are never handed the same port', () async {
    final service = PlayerService();
    final ports = await Future.wait([
      service.getNextAvailablePlayerPort(),
      service.getNextAvailablePlayerPort(),
    ]);
    expect(ports.toSet(), hasLength(2));
  });

  test('a closed local player\'s port cools before it is reused', () async {
    final temp = Directory.systemTemp.createTempSync('streamlink_gui_ports_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final launcher = FakeLauncher();
    final service = PlayerService(
        startProcess: launcher.start, runProcess: FakeTaskkill(launcher).run);
    final file = File('${temp.path}${Platform.pathSeparator}A VOD - 1.mp4')
      ..writeAsStringSync('');
    final vod = TwitchVideo(
      id: '1',
      title: 'A VOD',
      duration: '1h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026),
    );

    await service.playDownloadedVod(
        file,
        vod,
        AppSettings(
          playerType: 'custom',
          customPlayerPath: r'C:\nowhere\someplayer.exe',
          vodDownloadFolder: temp.path,
        ));
    final port = service.activePlayerPorts[vod.id]!;

    await launcher.launched.single.exit(0);
    await pumpEventQueue();
    expect(service.activePlayerPorts, isEmpty);

    // The dying player may still hold it, exactly as on the streamed path.
    expect(await service.getNextAvailablePlayerPort(), isNot(port));
  });
}
