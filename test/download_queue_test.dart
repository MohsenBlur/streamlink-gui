import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';

import 'support/fake_process.dart';

/// The download queue and yt-dlp's output, driven through PlayerService's
/// real code with a fake yt-dlp in place of the real one.
void main() {
  late Directory temp;
  late FakeLauncher launcher;
  late PlayerService service;
  final failed = <String>[];
  final ended = <String>[];
  final cancelled = <String>[];
  final progress = <double>[];
  final statuses = <String>[];
  final logs = <String, List<String>>{};

  TwitchVideo vod(String id, {String title = 'Some VOD'}) => TwitchVideo(
        id: id,
        title: title,
        duration: '1h0m0s',
        thumbnailUrl: '',
        viewCount: '0',
        publishedAt: DateTime(2026),
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('streamlink_gui_dlqueue_');
    launcher = FakeLauncher();
    service = PlayerService(
        startProcess: launcher.start, runProcess: FakeTaskkill(launcher).run);
    for (final list in [failed, ended, cancelled, progress, statuses]) {
      list.clear();
    }
    logs.clear();
    service
      ..onDownloadFailed = ((id, title, code) => failed.add(id))
      ..onDownloadEnded = ((id, code) => ended.add(id))
      ..onDownloadCancelled = cancelled.add
      ..onDownloadProgress = ((id, p, status) {
        progress.add(p);
        statuses.add(status);
      })
      ..onPlayerLog = ((key, line) => logs.putIfAbsent(key, () => []).add(line));
  });

  tearDown(() async {
    await service.stopAll();
    for (final p in launcher.launched) {
      await p.exit(-1);
    }
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('a download whose folder cannot be prepared', () {
    test('fails on its own and leaves the queue working', () async {
      // A channel folder that cannot be created: its parent is a file. The
      // same throw an unplugged external drive produces.
      final notAFolder = File('${temp.path}${Platform.pathSeparator}file')
        ..writeAsStringSync('x');
      final settings = AppSettings(vodDownloadFolder: notAFolder.path);

      service.queueVodDownload(vod('1'), 'chan', settings);
      service.queueVodDownload(vod('2'), 'chan', settings);
      await pumpEventQueue();

      expect(failed, ['1', '2']);
      expect(ended, ['1', '2']);
      expect(launcher.launched, isEmpty);
      expect(service.isQueueProcessing, isFalse,
          reason: 'a stuck flag left every later download "Queued" forever');
      expect(service.downloadQueue, isEmpty);
      expect(service.activeDownloadTasks, isEmpty);
      expect(logs['dl-1']!.join('\n'),
          contains('Could not prepare the download folder'));
    });

    // Cleared after construction: the constructor fills an empty folder in
    // with the user's real Downloads\TwitchVODs.
    AppSettings noFolder() => AppSettings()..vodDownloadFolder = '';

    test('with no folder configured at all', () async {
      service.queueVodDownload(vod('1'), 'chan', noFolder());
      await pumpEventQueue();

      expect(failed, ['1']);
      expect(service.isQueueProcessing, isFalse);
    });

    test('does not block a later download to a good folder', () async {
      service.queueVodDownload(vod('1'), 'chan', noFolder());
      await pumpEventQueue();

      service.queueVodDownload(
          vod('2'), 'chan', AppSettings(vodDownloadFolder: temp.path));
      await pumpEventQueue();

      expect(launcher.launched, hasLength(1));
      expect(launcher.launched.single.arguments.last,
          'https://twitch.tv/videos/2');
    });
  });

  group('yt-dlp output', () {
    late AppSettings settings;
    setUp(() => settings = AppSettings(vodDownloadFolder: temp.path));

    Future<FakeProcess> startDownload(String id, {String title = 'Some VOD'}) async {
      service.queueVodDownload(vod(id, title: title), 'chan', settings);
      await pumpEventQueue();
      return launcher.launched.last;
    }

    test('a percentage in the title is not progress', () async {
      final ytdlp = await startDownload('1', title: 'My 100% run');
      ytdlp.printOut('[download] Destination: ${temp.path}/chan/My 100% run - 1.mp4\n');
      await pumpEventQueue();

      expect(progress.where((p) => p >= 1.0), isEmpty,
          reason: 'the Destination line used to report 100%');
      await ytdlp.exit(0);
    });

    test('progress is read line by line across pipe reads', () async {
      final ytdlp = await startDownload('1');
      // Two updates separated by yt-dlp's bare \r, the second split across
      // two reads.
      ytdlp.printOut('[download]   5.0% of ~1.00GiB at 1.00MiB/s ETA 10:00\r'
          '[download]  10.');
      await pumpEventQueue();
      ytdlp.printOut('0% of ~1.00GiB at 2.00MiB/s ETA 09:00\r');
      await pumpEventQueue();

      expect(progress, containsAllInOrder([0.0, 0.05, 0.10]));
      expect(statuses.last, 'Downloading: 10.0% (2.00MiB/s)');
      await ytdlp.exit(0);
    });

    test('the fragment error triggers the ffmpeg retry even when split across reads',
        () async {
      final ytdlp = await startDownload('1');
      ytdlp.printErr('ERROR: Initialization fragment fou');
      await pumpEventQueue();
      ytdlp.printErr('nd after media fragments\n');
      await ytdlp.exit(1);

      // The retry waits a second before starting.
      await Future<void>.delayed(const Duration(milliseconds: 1300));

      expect(launcher.launched, hasLength(2));
      expect(launcher.launched.last.arguments,
          containsAllInOrder(['--downloader', 'ffmpeg']));
      expect(failed, isEmpty);
    });
  });

  test('cancelling during the gap before the ffmpeg retry stops the retry',
      () async {
    final settings = AppSettings(vodDownloadFolder: temp.path);
    service.queueVodDownload(vod('1'), 'chan', settings);
    await pumpEventQueue();
    final ytdlp = launcher.launched.single;
    ytdlp.printErr('ERROR: Initialization fragment found after media fragments\n');
    await ytdlp.exit(1);
    await pumpEventQueue();

    // In the gap: no process, but still queued - so the Downloads panel
    // offers a cancel button for it.
    expect(service.activeDownloadProcesses, isEmpty);
    expect(service.downloadQueue, contains('1'));
    await service.cancelVodDownload('1', 'chan', temp.path);
    expect(cancelled, ['1']);

    await Future<void>.delayed(const Duration(milliseconds: 1300));

    expect(launcher.launched, hasLength(1),
        reason: 'the cancelled download must not start again');
    expect(service.activeDownloadTasks, isEmpty);
    expect(service.isQueueProcessing, isFalse);
  });

  test('a VOD cancelled and queued again during that gap still downloads',
      () async {
    final settings = AppSettings(vodDownloadFolder: temp.path);
    service.queueVodDownload(vod('1'), 'chan', settings);
    await pumpEventQueue();
    final ytdlp = launcher.launched.single;
    ytdlp.printErr('ERROR: Initialization fragment found after media fragments\n');
    await ytdlp.exit(1);
    await pumpEventQueue();

    // Both buttons are on offer in the gap; the user presses both.
    await service.cancelVodDownload('1', 'chan', temp.path);
    service.queueVodDownload(vod('1'), 'chan', settings);
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    // The drain used to remove the re-queued entry when the abandoned retry
    // returned, leaving it "Queued" with nothing to start it.
    expect(launcher.launched, hasLength(2), reason: 'the re-queue must start');
    expect(launcher.launched.last.arguments, isNot(contains('ffmpeg')),
        reason: 'a fresh download, not the abandoned retry');
    expect(service.activeDownloadProcesses.keys, ['1']);

    await launcher.launched.last.exit(0);
    await pumpEventQueue();
    expect(service.downloadQueue, isEmpty);
    expect(service.activeDownloadTasks, isEmpty);
    expect(service.isQueueProcessing, isFalse);
  });

  group('a running download cancelled and queued again', () {
    // A taskkill that returns before its target has died, as the real one
    // can: the cancel finishes, and the old yt-dlp's exit is processed only
    // after the user has queued the VOD again.
    late PlayerService lateDeaths;
    late AppSettings settings;
    setUp(() {
      lateDeaths = PlayerService(
        startProcess: launcher.start,
        runProcess: (executable, arguments) async =>
            ProcessResult(0, 0, '', ''),
      );
      settings = AppSettings(vodDownloadFolder: temp.path);
    });
    tearDown(() => lateDeaths.stopAll());

    test('downloads into its own channel folder', () async {
      // The drain was started for another channel, so falling back to the
      // drain's own channelName puts the VOD in the wrong folder.
      lateDeaths.queueVodDownload(vod('1'), 'alpha', settings);
      lateDeaths.queueVodDownload(vod('2'), 'beta', settings);
      await pumpEventQueue();
      await launcher.launched.single.exit(0);
      await pumpEventQueue();
      final cancelledRun = launcher.launched.last;
      expect(cancelledRun.arguments.last, 'https://twitch.tv/videos/2');

      await lateDeaths.cancelVodDownload('2', 'beta', temp.path);
      lateDeaths.queueVodDownload(vod('2'), 'beta', settings);
      await cancelledRun.exit(1);
      await pumpEventQueue();

      expect(launcher.launched, hasLength(3), reason: 'the re-queue must start');
      expect(launcher.launched.last.arguments,
          contains(startsWith('${temp.path}/beta/')),
          reason: 'the old run\'s exit cleared the channel name, and the '
              'drain fell back to alpha');
      expect(lateDeaths.activeDownloadProcesses.keys, ['2']);

      await launcher.launched.last.exit(0);
      await pumpEventQueue();
      expect(lateDeaths.downloadQueue, isEmpty);
      expect(lateDeaths.activeDownloadTasks, isEmpty);
      expect(lateDeaths.downloadChannelNames, isEmpty);
    });

    test('still shows as queued after the old run has exited', () async {
      lateDeaths.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      final cancelledRun = launcher.launched.single;

      await lateDeaths.cancelVodDownload('1', 'chan', temp.path);
      // Another download ahead of it keeps the re-queue waiting, so what the
      // old run's exit leaves behind is what the Downloads panel shows.
      lateDeaths.queueVodDownload(vod('9'), 'other', settings);
      lateDeaths.queueVodDownload(vod('1'), 'chan', settings);
      await cancelledRun.exit(1);
      await pumpEventQueue();

      expect(launcher.launched.last.arguments.last, 'https://twitch.tv/videos/9');
      expect(lateDeaths.activeDownloadTasks['1'], 'Queued');
      expect(lateDeaths.downloadChannelNames['1'], 'chan');
      expect(lateDeaths.downloadTitles['1'], 'Some VOD');
    });

    test('is not shown with the progress the old run printed on its way out',
        () async {
      lateDeaths.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      final cancelledRun = launcher.launched.single;

      await lateDeaths.cancelVodDownload('1', 'chan', temp.path);
      lateDeaths.queueVodDownload(vod('9'), 'other', settings);
      lateDeaths.queueVodDownload(vod('1'), 'chan', settings);
      // Still running after taskkill returned, so its pipe has more to say.
      cancelledRun.printOut('[download]  45.0% of ~1.00GiB at 2.00MiB/s ETA 05:12\n');
      await cancelledRun.exit(1);
      await pumpEventQueue();

      expect(lateDeaths.activeDownloadTasks['1'], 'Queued');
      expect(lateDeaths.activeDownloadsProgress['1'], isNull);
    });
  });

  group('a running download cancelled and not queued again', () {
    // The same late death, with nothing claiming the VOD afterwards: what the
    // old run leaves behind must still go when it exits.
    late PlayerService lateDeaths;
    late AppSettings settings;
    setUp(() {
      lateDeaths = PlayerService(
        startProcess: launcher.start,
        runProcess: (executable, arguments) async =>
            ProcessResult(0, 0, '', ''),
      );
      settings = AppSettings(vodDownloadFolder: temp.path);
    });
    tearDown(() => lateDeaths.stopAll());

    test('leaves no progress behind that it printed after the cancel',
        () async {
      lateDeaths.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      final cancelledRun = launcher.launched.single;

      await lateDeaths.cancelVodDownload('1', 'chan', temp.path);
      cancelledRun.printOut('[download]  45.0% of ~1.00GiB at 2.00MiB/s ETA 05:12\n');
      await cancelledRun.exit(1);
      await pumpEventQueue();

      expect(lateDeaths.activeDownloadTasks, isEmpty,
          reason: 'a Downloads row left showing 45% for good');
      expect(lateDeaths.activeDownloadsProgress, isEmpty);
    });
  });

  group('a download cancelled while its yt-dlp is starting', () {
    // Until the process exists the cancel has nothing to end. It marked
    // nothing either, so the yt-dlp started anyway and downloaded the whole
    // VOD - with the cancel having cleared every trace of it on screen.
    late AppSettings settings;
    setUp(() => settings = AppSettings(vodDownloadFolder: temp.path));

    test('is ended the moment its yt-dlp exists', () async {
      launcher.startGate = Completer<void>();
      service.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      expect(launcher.starting, 1, reason: 'held mid-start');

      await service.cancelVodDownload('1', 'chan', temp.path);
      expect(cancelled, ['1']);
      launcher.startGate!.complete();
      launcher.startGate = null;
      await pumpEventQueue();

      final straggler = launcher.launched.single;
      expect(straggler.hasExited, isTrue);
      expect(service.activeDownloadProcesses, isEmpty,
          reason: 'a process on record refuses every later queueing');
      expect(service.activeDownloadTasks, isEmpty);
      expect(ended, ['1'], reason: 'its log session is closed');
      expect(failed, isEmpty, reason: 'cancelled, not failed');
      expect(service.isQueueProcessing, isFalse);
      expect(logs['dl-1']!.last, contains('cancelled'));

      service.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      expect(launcher.launched, hasLength(2), reason: 'it can be queued again');
    });

    test('before yt-dlp was even asked for starts none', () async {
      // Queued and cancelled in one go: the start was still waiting for the
      // archive's rewrites.
      service.queueVodDownload(vod('1'), 'chan', settings);
      await service.cancelVodDownload('1', 'chan', temp.path);
      await pumpEventQueue();

      expect(launcher.launched, isEmpty);
      expect(ended, ['1']);
      expect(failed, isEmpty);
      expect(service.activeDownloadTasks, isEmpty);
      expect(service.isQueueProcessing, isFalse);
    });

    test('and queued again, downloads in the new run only', () async {
      launcher.startGate = Completer<void>();
      service.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      await service.cancelVodDownload('1', 'chan', temp.path);
      service.queueVodDownload(vod('1'), 'chan', settings);
      launcher.startGate!.complete();
      launcher.startGate = null;
      await pumpEventQueue();

      expect(launcher.launched, hasLength(2));
      expect(launcher.launched.first.hasExited, isTrue);
      expect(launcher.launched.last.hasExited, isFalse);
      expect(service.activeDownloadProcesses['1'], same(launcher.launched.last));
      expect(service.downloadChannelNames['1'], 'chan',
          reason: "the old run's end leaves the new run's state alone");

      await launcher.launched.last.exit(0);
      await pumpEventQueue();
      expect(failed, isEmpty);
      expect(service.downloadQueue, isEmpty);
    });

    test('whose start then fails is reported as cancelled, not failed',
        () async {
      final gate = Completer<void>();
      final broken = PlayerService(
        startProcess: (executable, arguments, {environment}) async {
          await gate.future;
          throw const ProcessException('yt-dlp', [], 'not found');
        },
        runProcess: FakeTaskkill(launcher).run,
      )
        ..onDownloadFailed = ((id, title, code) => failed.add(id))
        ..onDownloadEnded = ((id, code) => ended.add(id));
      addTearDown(broken.stopAll);

      broken.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      await broken.cancelVodDownload('1', 'chan', temp.path);
      gate.complete();
      await pumpEventQueue();

      expect(failed, isEmpty);
      expect(ended, ['1']);
      expect(broken.isQueueProcessing, isFalse);
    });

    test('is ended by stopping everything too, its queue entry kept',
        () async {
      launcher.startGate = Completer<void>();
      service.queueVodDownload(vod('1'), 'chan', settings);
      await pumpEventQueue();
      await service.stopAll();
      launcher.startGate!.complete();
      launcher.startGate = null;
      await pumpEventQueue();

      expect(launcher.launched.single.hasExited, isTrue,
          reason: 'it outlived an exit or an update that stopped everything');
      expect(failed, isEmpty);
      expect(cancelled, isEmpty,
          reason: 'not cancelled: the saved queue resumes it next launch');
    });
  });

  test('a download it already has is not announced as queued', () async {
    final settings = AppSettings(vodDownloadFolder: temp.path);
    final queued = <String>[];
    service.onDownloadQueued = (vod, channel) => queued.add('$channel/${vod.id}');
    service.queueVodDownload(vod('1'), 'chan', settings);
    service.queueVodDownload(vod('2'), 'other', settings);
    service.queueVodDownload(vod('1'), 'chan', settings);
    await pumpEventQueue();
    expect(queued, ['chan/1', 'other/2']);
  });

  test('a cancel that lands after its download finished does nothing',
      () async {
    // The Stop dialog was confirmed after the download completed under it:
    // "Download cancelled." replaced the completion message, the archive
    // line went, and the VOD's files were deleted from the folder searched.
    final settings = AppSettings(vodDownloadFolder: temp.path);
    final done = File('${temp.path}/chan/Some VOD - v1.mp4');
    service.queueVodDownload(vod('1'), 'chan', settings);
    await pumpEventQueue();
    done
      ..createSync(recursive: true)
      ..writeAsStringSync('video');
    await launcher.launched.single.exit(0);
    await pumpEventQueue();
    expect(service.activeDownloadTasks, isEmpty, reason: 'precondition');

    await service.cancelVodDownload('1', 'chan', temp.path);

    expect(cancelled, isEmpty);
    expect(done.existsSync(), isTrue);
  });
}
