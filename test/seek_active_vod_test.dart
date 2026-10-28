import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/utils/player_args.dart';
import 'package:streamlink_gui/utils/player_seek.dart';

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

  group('mpv', () {
    final mpvSettings = AppSettings(
      playerType: 'custom',
      customPlayerPath: '/usr/bin/mpv',
    );

    test('is reached where its launch told it to listen', () {
      // The progress tracker and the seek both connect through this.
      String ipcServer({required bool isWindows}) => buildPlayerArgs(
            kind: PlayerKind.mpv,
            startSeconds: 0,
            port: 8123,
            ipcName: vod.id,
            isWindows: isWindows,
          ).singleWhere((a) => a.startsWith('--input-ipc-server=')).split('=').last;

      // Off Windows: mpv's own unix socket, not a TCP port nothing listens on.
      final unix = PlayerService.mpvIpcEndpoint(vod.id, 8123, isWindows: false);
      expect(unix.host, isA<InternetAddress>());
      final address = unix.host as InternetAddress;
      expect(address.type, InternetAddressType.unix);
      expect(address.address, ipcServer(isWindows: false));
      expect(unix.port, 0);

      // On Windows: the bridge relaying to mpv's pipe, on the session port.
      final windows = PlayerService.mpvIpcEndpoint(vod.id, 8123, isWindows: true);
      expect(windows.host, '127.0.0.1');
      expect(windows.port, 8123);
    });

    test("a seek off Windows goes to mpv's own socket", () async {
      final socketPath = mpvIpcPath(vod.id, false);
      final stale = File(socketPath);
      if (stale.existsSync()) stale.deleteSync();
      final mpv = await ServerSocket.bind(
          InternetAddress(socketPath, type: InternetAddressType.unix), 0);
      addTearDown(() async {
        await mpv.close();
        if (stale.existsSync()) stale.deleteSync();
      });
      final received = <String>[];
      mpv.listen((client) {
        client.listen((data) {
          received.add(String.fromCharCodes(data));
          // Answers and stays connected, as mpv does.
          client.write('{"event":"seek"}\n'
              '{"data":null,"request_id":0,"error":"success"}\n');
        });
      });

      final watch = Stopwatch()..start();
      expect(await service.seekActiveVod(vod.id, 600, mpvSettings), isTrue);
      expect(received.join(), mpvSeekCommand(600));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)),
          reason: 'the answer ends the exchange; mpv does not hang up');
      expect(logs, contains('[System] Jumped to 600s at your request.'));
    }, skip: Platform.isWindows ? 'Windows reaches mpv through the bridge' : false);

    test('an answer is a whole reply line, never an event or half a line', () {
      expect(mpvSeekAnswered('{"data":null,"request_id":0,"error":"success"}\n'),
          isTrue);
      expect(mpvSeekAnswered('{"event":"seek"}\n{"request_id":0,"error":"succ'),
          isFalse, reason: 'half a reply: the exchange would read "succ"');
      expect(
          mpvSeekAnswered(
              '{"event":"end-file","reason":"error","file_error":"x"}\n'),
          isFalse);
      expect(mpvSeekAnswered(''), isFalse);
    });
  });
}
