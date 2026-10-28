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
    service = PlayerService(startProcess: launcher.start);
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
    // End the fakes first, so stopAll has no process left to taskkill.
    for (final p in launcher.launched) {
      await p.exit(-1);
    }
    await pumpEventQueue();
    service.stopAll();
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
}
