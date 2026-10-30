import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/utils/mpc_slave_protocol.dart';

import 'support/fake_mpc_slave.dart';
import 'support/fake_process.dart';
import 'support/fake_vlc.dart' show waitFor;

/// MPC-HC driven over its /slave API: the launches hand it a control window,
/// and the progress tracker, the resume correction, the end-of-stream heal
/// and the seek all go through that window - never its web interface, and
/// never by changing MPC-HC's settings.
void main() {
  late Directory temp;
  late FakeLauncher launcher;
  late FakeTaskkill taskkill;
  late FakeMpcSlave slave;
  late PlayerService service;
  late List<String> logs;
  late List<String> otherCommands;
  late List<int> recorded;
  late String mpcExe;

  TwitchVideo vod({int? watchPosition}) => TwitchVideo(
        id: '5150',
        title: 'Long VOD',
        duration: '2h0m0s',
        thumbnailUrl: '',
        viewCount: '0',
        publishedAt: DateTime(2026),
        watchPosition: watchPosition,
      );

  AppSettings settings() => AppSettings(
        playerType: 'custom',
        customPlayerPath: mpcExe,
        vodDownloadFolder: temp.path,
      );

  PlayerService makeService(
          {Duration mpcConnectGrace = const Duration(seconds: 20)}) =>
      PlayerService(
        startProcess: launcher.start,
        runProcess: (exe, args) {
          if (exe != 'taskkill') otherCommands.add('$exe ${args.join(' ')}');
          return taskkill.run(exe, args);
        },
        progressPollInterval: const Duration(milliseconds: 40),
        mpcSlave: slave,
        mpcConnectGrace: mpcConnectGrace,
      )
        ..onPlayerLog = ((_, line) => logs.add(line))
        ..recordWatchProgress = (id, position, progress, ageMs) {
          recorded.add(position);
          return true;
        };

  setUp(() {
    temp = Directory.systemTemp.createTempSync('streamlink_gui_mpc_');
    launcher = FakeLauncher();
    taskkill = FakeTaskkill(launcher);
    slave = FakeMpcSlave();
    logs = [];
    otherCommands = [];
    recorded = [];
    mpcExe = '${temp.path}${Platform.pathSeparator}mpc-hc64.exe';
    File(mpcExe).writeAsStringSync('');
    service = makeService();
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

  Future<FakeProcess> playFile({TwitchVideo? video}) async {
    final file = File('${temp.path}${Platform.pathSeparator}Long VOD - 5150.mp4')
      ..writeAsStringSync('');
    await service.playDownloadedVod(file, video ?? vod(), settings());
    return launcher.launched.single;
  }

  group('a downloaded VOD', () {
    test('is launched with its control window and no web interface',
        () async {
      // MPC-HC keeps its settings in an .ini beside its exe when there is
      // one; the app used to write WebServerLocalhostOnly=1 into it (or the
      // registry) before every launch, and never put it back.
      final ini = File('${temp.path}${Platform.pathSeparator}mpc-hc64.ini')
        ..writeAsStringSync('[Settings]\r\nWebServerLocalhostOnly=0\r\n');
      final before = ini.readAsBytesSync();

      final player = await playFile();

      expect(player.executable, mpcExe);
      expect(player.arguments,
          containsAllInOrder(['/new', '/slave', FakeMpcSlave.windowOf(1)]));
      expect(player.arguments, isNot(contains('/webport')));
      expect(slave.bound, {1: player.pid},
          reason: 'the runner takes messages only from this process');
      expect(otherCommands, isEmpty, reason: 'no reg add, nothing else');
      expect(ini.readAsBytesSync(), before);
    });

    test('has its position tracked over the window', () async {
      await playFile();
      slave.players[1]!.connect(startAt: 30);
      await waitFor(() => recorded.length >= 3, reason: 'positions');

      expect(recorded.first, inInclusiveRange(30, 40));
      expect(recorded, orderedEquals([...recorded]..sort()));
      expect(slave.commandsTo(1), everyElement(MpcCommand.getCurrentPosition));
      expect(logs, contains('[System] MPC-HC connected to the app over its /slave interface.'));
      expect(logs, contains('[System] Player answering over its control window.'));
    });

    test('can be sent to a position, which counts once MPC-HC reports it',
        () async {
      await playFile();
      // Not connected yet: nothing to send it to.
      expect(await service.seekActiveVod('5150', 600, settings()), isFalse);
      expect(logs, contains('[System] Could not correct the playback position: '
          'MPC-HC has not connected to the app.'));

      slave.players[1]!.connect(startAt: 30);
      expect(await service.seekActiveVod('5150', 600, settings()), isTrue);
      expect(slave.sent, contains((1, MpcCommand.setPosition, '600')));
      expect(logs, contains('[System] Jumped to 600s at your request.'));
    });

    test("closes its window when the player exits", () async {
      final player = await playFile();
      slave.players[1]!.connect();
      await player.exit(0);
      await pumpEventQueue();
      expect(slave.closed, {1});
    });

    test('closes its window when everything is stopped', () async {
      await playFile();
      await service.stopAll();
      expect(slave.closed, {1});
    });

    test('plays untracked, and says why, when there is no window', () async {
      slave.openFailure = StateError('no window');
      final player = await playFile();
      expect(player.arguments, isNot(contains('/slave')));
      expect(player.arguments, contains('/new'));
      expect(logs.join('\n'),
          contains("MPC-HC's position is not tracked this session: Bad state: no window."));
      expect(service.activePlayerTimers, isEmpty);
    });

    test('plays untracked when the window cannot be held to the player',
        () async {
      slave.bindResult = false;
      await playFile();
      await pumpEventQueue();
      expect(logs.join('\n'), contains('could not be held on to'));
      expect(slave.closed, {1});
      expect(service.activePlayerTimers, isEmpty);
    });

    test('says once that MPC-HC never connected', () async {
      service = makeService(mpcConnectGrace: const Duration(milliseconds: 100));
      await playFile();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
          logs.where((l) => l.contains('MPC-HC has not connected to the app')),
          hasLength(1));
      expect(slave.sent, isEmpty);
    });

    test('logs a message from another process once', () async {
      await playFile();
      slave.reject(1, 4444, MpcCommand.connect);
      slave.reject(1, 4444, MpcCommand.connect);
      expect(logs.where((l) => l.contains('Ignored a control message')),
          ['[System] Ignored a control message from process 4444, which this '
              'session did not start (further ones are ignored silently).']);
    });
  });

  group('a streamed VOD', () {
    test("binds streamlink's process, which starts the player", () async {
      await service.launchStreamlinkForVod(vod(), 'chan', settings());
      final streamlink = launcher.launched.single;
      final playerArgs =
          streamlink.arguments[streamlink.arguments.indexOf('--player-args') + 1];
      expect(playerArgs, contains('/new /slave ${FakeMpcSlave.windowOf(1)}'));
      expect(playerArgs, isNot(contains('/webport')));
      expect(slave.bound, {1: streamlink.pid});
      expect(otherCommands, isEmpty);
    });

    test('a resume MPC-HC ignored is corrected over the window', () async {
      // MPC-HC discards /start on a network stream: asked for 600s, it
      // comes up at 0.
      await service.launchStreamlinkForVod(
          vod(watchPosition: 600), 'chan', settings());
      slave.players[1]!.connect(startAt: 0);
      await waitFor(
          () => slave.sent.contains((1, MpcCommand.setPosition, '600')),
          reason: 'the correction');
      await waitFor(
          () => logs.any((l) => l.contains('Playback started where it was asked')),
          reason: 'the landing');
      expect(recorded, everyElement(greaterThanOrEqualTo(600 - 45)),
          reason: 'nothing written from where it wrongly came up');
    });

    test('a premature end of stream relaunches it with a new window',
        () async {
      taskkill.gracefulEndsTargets = true;
      await service.launchStreamlinkForVod(vod(), 'chan', settings());
      slave.players[1]!.connect(startAt: 100);
      await waitFor(() => recorded.length >= 2, reason: 'a confirmed position');

      slave.players[1]!.endOfStream();
      await waitFor(() => launcher.launched.length == 2,
          reason: 'the relaunch');
      await pumpEventQueue();

      expect(logs.join('\n'), contains('Premature end-of-stream verdict'));
      expect(slave.closed, contains(1), reason: "the first player's window");
      expect(slave.opened, [1, 2]);
      final relaunch = launcher.launched.last;
      expect(relaunch.arguments.join(' '),
          contains('/slave ${FakeMpcSlave.windowOf(2)}'));
      expect(slave.bound[2], relaunch.pid);
      expect(slave.closed, isNot(contains(2)));
    });

    test('a genuine end is the end', () async {
      await service.launchStreamlinkForVod(vod(), 'chan', settings());
      slave.players[1]!.connect(startAt: 7100); // of 7200
      await waitFor(() => recorded.length >= 2, reason: 'a confirmed position');
      slave.players[1]!.endOfStream();
      await waitFor(() => logs.contains('[System] VOD finished.'),
          reason: 'the verdict');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(launcher.launched, hasLength(1));
    });
  });
}
