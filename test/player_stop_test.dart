import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';

import 'support/fake_process.dart';
import 'support/fake_vlc.dart';

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
    service = PlayerService(
      startProcess: launcher.start,
      runProcess: taskkill.run,
      progressPollInterval: const Duration(milliseconds: 40),
    );
    stopped.clear();
    failedDownloads.clear();
    logs.clear();
    service
      ..onPlayerStopped = ((key, code, userInitiated) => stopped[key] = userInitiated)
      ..onDownloadFailed = ((id, title, code) => failedDownloads.add(id))
      ..onPlayerLog = ((key, line) => logs.putIfAbsent(key, () => []).add(line));
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

  // The self-heal: a streamed VOD whose player reports end-of-stream mid-VOD
  // is relaunched at the confirmed position. The relaunch is staged before the
  // player is asked to close, and on Windows the player then gets up to 2.4s
  // to close on its own - which is the window a user's Stop can land in.
  group('a Stop during a self-heal bounce', () {
    late FakeVlc vlc;
    final vod = TwitchVideo(
      id: '4242',
      title: 'Long VOD',
      duration: '2h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026),
    );

    // A VLC by path, so the tracker polls the fake VLC below.
    AppSettings vlcSettings() => AppSettings(
          playerType: 'custom',
          customPlayerPath: r'C:\nowhere\vlc.exe',
          vodDownloadFolder: temp.path,
        );

    /// Plays to a confirmed position, then lets the stream die, and returns
    /// once the heal has asked the player to close.
    Future<void> playUntilTheHealBegins() async {
      await service.launchStreamlinkForVod(vod, 'chan', vlcSettings());
      vlc = await FakeVlc.serve(service.activePlayerPorts[vod.id]!);
      await waitFor(() => vlc.polls >= 3, reason: 'playback to be confirmed');
      vlc.state = 'stopped';
      await waitFor(() => taskkill.calls.isNotEmpty,
          reason: 'the heal to ask the player to close');
      expect(taskkill.calls.single, isNot(contains('/F')),
          reason: 'the heal closes gracefully first');
    }

    tearDown(() => vlc.close());

    test('relaunches the stream when the user does nothing', () async {
      // The control: proves the harness really reaches the heal.
      taskkill.gracefulEndsTargets = true;
      await playUntilTheHealBegins();
      await waitFor(() => launcher.launched.length == 2,
          reason: 'the relaunch');

      expect(launcher.launched.last.arguments.join(' '),
          contains('--start-time='));
      expect(stopped, isEmpty, reason: 'a heal is not a stop');
    });

    test('is honoured instead of relaunching', () async {
      await playUntilTheHealBegins();

      await service.killProcess(vod.id);
      await pumpEventQueue();
      // Past the end of the graceful wait, when a relaunch would have come.
      await Future<void>.delayed(const Duration(milliseconds: 2600));

      expect(launcher.launched, hasLength(1),
          reason: 'the stream the user stopped must stay stopped');
      expect(stopped, {vod.id: true});
    });

    test('is honoured when the verdict lands while its taskkill is running',
        () async {
      // The other order. Stop is now an asynchronous taskkill, so the tracker
      // keeps ticking while it runs - and a stream that dies in that window
      // (the very moment a user, seeing it stall, reaches for Stop) used to
      // get a heal staged behind the Stop, which the exit handler then obeyed.
      await service.launchStreamlinkForVod(vod, 'chan', vlcSettings());
      vlc = await FakeVlc.serve(service.activePlayerPorts[vod.id]!);
      await waitFor(() => vlc.polls >= 3, reason: 'playback to be confirmed');

      taskkill.delay = const Duration(milliseconds: 600);
      final stop = service.killProcess(vod.id);
      vlc.state = 'stopped';
      await stop;
      await pumpEventQueue();
      // Past a heal's graceful wait, when a relaunch would have come.
      await Future<void>.delayed(const Duration(milliseconds: 2600));

      expect(launcher.launched, hasLength(1),
          reason: 'the stream the user stopped must stay stopped');
      expect(stopped, {vod.id: true});
    });

    // After the heal's exit there is a gap before the relaunched process is
    // registered - a port probe, then the process start - in which a Stop
    // used to find nothing to kill and was dropped.
    test('is honoured when it lands before the relaunch has a process',
        () async {
      taskkill.gracefulEndsTargets = true;
      // Stop at the moment the relaunch announces itself: its port is chosen
      // and its process is about to start.
      service.onPlayerLog = (key, line) {
        logs.putIfAbsent(key, () => []).add(line);
        if (line.contains('Resuming after premature end-of-stream')) {
          unawaited(service.killProcess(vod.id));
        }
      };
      await playUntilTheHealBegins();
      await waitFor(() => stopped.isNotEmpty, reason: 'the stop to be reported');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(launcher.launched, hasLength(1),
          reason: 'no player may start for a stopped stream');
      expect(stopped, {vod.id: true}, reason: 'a stop, not a failure');
      expect(service.playingVodIds, isEmpty);
      expect(service.activePlayerPorts, isEmpty);
      expect(logs[vod.id], contains('[System] Stopped before the relaunch began.'));
    });

    test('is honoured when it lands while the relaunch is starting', () async {
      taskkill.gracefulEndsTargets = true;
      launcher.startDelay = const Duration(milliseconds: 400);
      await playUntilTheHealBegins();
      // The graceful close ended the player; the relaunch is now waiting on
      // its process start, with nothing registered for a Stop to end. The
      // relaunch logs its resume in the same step as its last check for a
      // Stop, just before the start. playingVodIds alone is set before the
      // port probe, which under a loaded full run can still be binding when
      // the Stop arrives, so the Stop then landed before the relaunch began.
      await waitFor(
          () =>
              launcher.launched.single.hasExited &&
              (logs[vod.id] ?? const []).any((line) =>
                  line.contains('Resuming after premature end-of-stream')),
          reason: 'the relaunch to be under way');

      await service.killProcess(vod.id);
      await waitFor(() => stopped.isNotEmpty, reason: 'the stop to be reported');

      expect(launcher.launched, hasLength(2));
      expect(launcher.launched.last.hasExited, isTrue,
          reason: 'the relaunched player is ended as soon as it exists');
      expect(stopped, {vod.id: true});
      expect(service.playingVodIds, isEmpty);
    });
  }, skip: Platform.isWindows ? false : 'the graceful wait exists only on Windows');

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
