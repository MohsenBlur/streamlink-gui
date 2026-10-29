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

  group("MPC-HC's web interface, which has no password", () {
    // Started by /webport, it listened on every interface unless MPC-HC was
    // set to allow only this computer - which it is not by default.
    late Directory temp;
    late FakeLauncher launcher;
    late List<List<String>> runs;
    late int regExitCode;
    late PlayerService service;
    final vod = TwitchVideo(
      id: '7',
      title: 'A VOD',
      duration: '1h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026),
    );
    setUp(() {
      temp = Directory.systemTemp.createTempSync('streamlink_gui_mpc_');
      launcher = FakeLauncher();
      runs = [];
      regExitCode = 0;
      final taskkill = FakeTaskkill(launcher);
      service = PlayerService(
        startProcess: launcher.start,
        runProcess: (exe, args) async {
          if (exe == 'reg') {
            runs.add([exe, ...args]);
            return ProcessResult(0, regExitCode, '', 'denied');
          }
          return taskkill.run(exe, args);
        },
      );
    });
    tearDown(() async {
      await service.stopAll();
      for (final run in launcher.launched) {
        await run.exit(-1);
      }
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<FakeProcess> play() async {
      final exe = File('${temp.path}${Platform.pathSeparator}mpc-hc64.exe')
        ..writeAsStringSync('');
      final file = File('${temp.path}${Platform.pathSeparator}A VOD - 7.mp4')
        ..writeAsStringSync('');
      await service.playDownloadedVod(
          file,
          vod,
          AppSettings(
            playerType: 'custom',
            customPlayerPath: exe.path,
            vodDownloadFolder: temp.path,
          ));
      return launcher.launched.single;
    }

    test('is limited to this computer in the registry before the launch',
        () async {
      final player = await play();
      expect(runs.single, [
        'reg',
        'add',
        PlayerService.mpcHcSettingsKey,
        '/v',
        'WebServerLocalhostOnly',
        '/t',
        'REG_DWORD',
        '/d',
        '1',
        '/f',
      ]);
      expect(player.arguments, contains('/webport'));
    });

    test('or in the .ini beside its exe, where MPC-HC then keeps settings',
        () async {
      final ini = File('${temp.path}${Platform.pathSeparator}mpc-hc64.ini')
        ..writeAsBytesSync([
          0xFF, 0xFE,
          for (final unit in '[Settings]\r\nWebServerLocalhostOnly=0\r\n'.codeUnits)
            ...[unit & 0xFF, unit >> 8],
        ]);
      final player = await play();
      expect(runs, isEmpty);
      final bytes = ini.readAsBytesSync();
      expect(bytes.take(2), [0xFF, 0xFE], reason: 'still UTF-16');
      expect(
          String.fromCharCodes([
            for (var i = 2; i + 1 < bytes.length; i += 2)
              bytes[i] | (bytes[i + 1] << 8),
          ]),
          '[Settings]\r\nWebServerLocalhostOnly=1\r\n');
      expect(player.arguments, contains('/webport'));
    });

    test('stays off when it cannot be limited, and says why', () async {
      regExitCode = 1;
      final lines = <String>[];
      service.onPlayerLog = (_, line) => lines.add(line);
      final player = await play();
      expect(player.arguments, isNot(contains('/webport')));
      expect(lines.join('\n'), contains("MPC-HC's web interface stays off"));
    });
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

  // Checking a port awaits, and the check sits between each launch path's
  // "already playing?" guard and the point where the VOD used to be recorded
  // as playing. A double-click, or an automation pass landing on a manual
  // play, must still start one player: a second would clobber the first's
  // process, port, timer and bridge entries, which are all keyed by VOD id.
  group('two launches of the same VOD at once start one player', () {
    late Directory temp;
    late FakeLauncher launcher;
    late PlayerService service;
    final vod = TwitchVideo(
      id: '2',
      title: 'A VOD',
      duration: '1h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026),
    );

    AppSettings settings() => AppSettings(
          playerType: 'custom',
          customPlayerPath: r'C:\nowhere\someplayer.exe',
          vodDownloadFolder: temp.path,
        );

    setUp(() {
      temp = Directory.systemTemp.createTempSync('streamlink_gui_ports_');
      launcher = FakeLauncher();
      service = PlayerService(
          startProcess: launcher.start, runProcess: FakeTaskkill(launcher).run);
    });

    tearDown(() async {
      await service.stopAll();
      for (final p in launcher.launched) {
        await p.exit(0);
      }
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('from a downloaded file', () async {
      final file = File('${temp.path}${Platform.pathSeparator}A VOD - 2.mp4')
        ..writeAsStringSync('');
      await Future.wait([
        service.playDownloadedVod(file, vod, settings()),
        service.playDownloadedVod(file, vod, settings()),
      ]);
      expect(launcher.launched, hasLength(1));
      expect(service.playingVodIds, {vod.id});
    });

    test('streamed', () async {
      await Future.wait([
        service.launchStreamlinkForVod(vod, 'chan', settings()),
        service.launchStreamlinkForVod(vod, 'chan', settings()),
      ]);
      expect(launcher.launched, hasLength(1));
      expect(service.playingVodIds, {vod.id});
    });
  });
}
