import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/downloads_controller.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/state/download_registry.dart';

import 'support/fake_process.dart';

TwitchVideo _vod(String id) => TwitchVideo(
      id: id,
      title: 'VOD $id',
      duration: '1h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026),
    );

const _noScan = DownloadScanInput(
    downloadRoot: '', channelName: '', vodIds: [], registry: {}, inFlight: {});

void main() {
  // The saved queue, driven by PlayerService's real queue with a fake yt-dlp,
  // wired the way the main screen wires it.
  group('the saved download queue', () {
    late Directory temp;
    late FakeLauncher launcher;
    late PlayerService player;
    late DownloadsController downloads;
    late AppSettings settings;
    var changes = 0;

    List<String> savedIds() => [
          for (final entry in downloads.persisted!)
            (entry['vod'] as Map)['id'] as String,
        ];

    setUp(() {
      temp = Directory.systemTemp.createTempSync('streamlink_gui_dlctl_');
      launcher = FakeLauncher();
      player = PlayerService(
          startProcess: launcher.start, runProcess: FakeTaskkill(launcher).run);
      settings = AppSettings(vodDownloadFolder: temp.path);
      changes = 0;
      downloads = DownloadsController(
        onQueueChanged: () => changes++,
        readScanInput: () => _noScan,
        onScanned: (_) {},
      );
      player
        ..onDownloadQueued = downloads.remember
        ..onDownloadCompleted = ((id, title, path) => downloads.forget(id))
        ..onDownloadFailed = ((id, title, code) => downloads.forget(id))
        ..onDownloadCancelled = downloads.forget;
    });

    tearDown(() async {
      await player.stopAll();
      for (final p in launcher.launched) {
        await p.exit(-1);
      }
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('is left alone until the saved one has been adopted', () {
      expect(downloads.persisted, isNull,
          reason: 'null means "keep the config\'s own copy"');
      downloads.restore(const []);
      expect(downloads.persisted, isEmpty);
    });

    test('changes as downloads are queued and finish', () async {
      downloads.restore(const []);
      player.queueVodDownload(_vod('1'), 'chan', settings);
      player.queueVodDownload(_vod('2'), 'chan', settings);
      player.queueVodDownload(_vod('3'), 'other', settings);
      await pumpEventQueue();
      expect(savedIds(), ['1', '2', '3'],
          reason: 'saved as it changes, not only at a deliberate exit');
      expect(downloads.persisted![2]['channelName'], 'other');

      // 1 completes, 2 fails, 3 is cancelled.
      await launcher.launched[0].exit(0);
      await pumpEventQueue();
      expect(savedIds(), ['2', '3']);
      await launcher.launched[1].exit(1);
      await pumpEventQueue();
      expect(savedIds(), ['3']);
      await player.cancelVodDownload('3', 'other', temp.path);
      await pumpEventQueue();
      expect(savedIds(), isEmpty);
      expect(changes, 6);
    });

    test('a download queued twice is saved once', () async {
      downloads.restore(const []);
      player.queueVodDownload(_vod('1'), 'chan', settings);
      player.queueVodDownload(_vod('1'), 'chan', settings);
      await pumpEventQueue();
      expect(savedIds(), ['1']);
      expect(changes, 1);
    });

    test('stopping everything to exit or update leaves it saved', () async {
      downloads.restore(const []);
      player.queueVodDownload(_vod('1'), 'chan', settings);
      player.queueVodDownload(_vod('2'), 'chan', settings);
      await pumpEventQueue();

      await player.stopAll();
      await pumpEventQueue();

      expect(launcher.launched.single.hasExited, isTrue);
      expect(savedIds(), ['1', '2'],
          reason: 'ended, not finished: both resume at the next launch');
    });

    test('the saved queue is resumed without being cleared first', () async {
      final resumable = downloads.restore([
        {'vod': _vod('7').toJson(), 'channelName': 'chan'},
        {'vod': _vod('8').toJson(), 'channelName': 'chan'},
      ]);
      expect(resumable.map((d) => d.vod.id), ['7', '8']);
      expect(savedIds(), ['7', '8'],
          reason: 'a crash right after launch must still find them');
      expect(changes, 0, reason: 'nothing changed, so nothing to save');

      for (final download in resumable) {
        player.queueVodDownload(download.vod, download.channelName, settings);
      }
      await pumpEventQueue();
      expect(savedIds(), ['7', '8']);
      expect(launcher.launched, hasLength(1));

      await launcher.launched.single.exit(0);
      await pumpEventQueue();
      expect(savedIds(), ['8'], reason: 'each leaves when it finishes');
    });

    test('unreadable saved entries are dropped, and that is saved', () {
      final resumable = downloads.restore([
        {'vod': _vod('7').toJson(), 'channelName': 'chan'},
        'garbage',
        {'vod': {'title': 'no id'}, 'channelName': 'chan'},
        {'vod': _vod('9').toJson()},
        {'vod': _vod('7').toJson(), 'channelName': 'chan'},
      ]);
      expect(resumable.map((d) => d.vod.id), ['7']);
      expect(savedIds(), ['7']);
      expect(changes, 1);
    });

    test('while frozen, downloads Windows ends stay saved', () async {
      downloads.restore(const []);
      player.queueVodDownload(_vod('1'), 'chan', settings);
      player.queueVodDownload(_vod('2'), 'chan', settings);
      await pumpEventQueue();

      downloads.freeze();
      // The session end kills yt-dlp, which reports that as a failure.
      await launcher.launched.single.exit(1);
      await pumpEventQueue();
      expect(savedIds(), ['1', '2']);

      // ...and if the end is called off, back to the queue as it is.
      downloads.unfreeze();
      expect(savedIds(), ['2']);
    });
  });

  group('scanDownloadFolder', () {
    late Directory root;
    late Directory channel;

    String touch(String name) {
      final file = File('${channel.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync('x');
      return file.path;
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('streamlink_gui_scan_');
      channel = Directory('${root.path}${Platform.pathSeparator}chan')
        ..createSync();
    });
    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('finds the open channel\'s files from one listing', () {
      final a = touch('First - 100.mp4');
      touch('Partial - 200.mp4.part');
      touch('Longer - 3000.mp4');
      final plan = scanDownloadFolder(DownloadScanInput(
        downloadRoot: root.path,
        channelName: 'chan',
        vodIds: ['100', '200', '300'],
        registry: const {},
        inFlight: const {},
      ))!;
      expect(plan.additions, {'100': a},
          reason: 'a partial is not a download, and 300 is not 3000');
      expect(plan.present, {'100'});
    });

    test('prunes a deleted file and keeps an unreachable one', () {
      final gone = '${channel.path}${Platform.pathSeparator}Gone - 1.mp4';
      final offline =
          '${root.path}${Platform.pathSeparator}nowhere${Platform.pathSeparator}Off - 2.mp4';
      final kept = touch('Kept - 3.mp4');
      final plan = scanDownloadFolder(DownloadScanInput(
        downloadRoot: root.path,
        channelName: 'chan',
        vodIds: const [],
        registry: {'1': gone, '2': offline, '3': kept},
        inFlight: const {},
      ))!;
      expect(plan.prune, {'1'});
      expect(plan.unverified, {'2'});
      expect(plan.present, {'3'});
    });

    test('an unreachable download folder changes nothing', () {
      expect(
        scanDownloadFolder(DownloadScanInput(
          downloadRoot: '${root.path}${Platform.pathSeparator}unplugged',
          channelName: 'chan',
          vodIds: const ['1'],
          registry: const {'1': 'x'},
          inFlight: const {},
        )),
        isNull,
      );
    });
  });

  group('reconcileDownloadScan', () {
    const scanned = DownloadScanInput(
      downloadRoot: 'D',
      channelName: 'chan',
      vodIds: [],
      registry: {'1': 'old/1.mp4', '2': 'p/2.mp4'},
      inFlight: {},
    );
    const plan = RegistryScanPlan(
      present: {'2', '9'},
      unverified: {},
      prune: {'1'},
      stripFromArchive: {'1'},
      additions: {'9': 'p/9.mp4'},
    );

    test('applies the plan when nothing moved meanwhile', () {
      final outcome =
          reconcileDownloadScan(scanned: scanned, plan: plan, now: scanned);
      expect(outcome.prune, {'1'});
      expect(outcome.stripFromArchive, {'1'});
      expect(outcome.additions, {'9': 'p/9.mp4'});
      expect(outcome.downloaded, {'2', '9'});
    });

    test('an entry recorded again during the scan is not pruned', () {
      final outcome = reconcileDownloadScan(
        scanned: scanned,
        plan: plan,
        now: const DownloadScanInput(
          downloadRoot: 'D',
          channelName: 'chan',
          vodIds: [],
          // 1 was downloaded again, to a new path, while the scan ran.
          registry: {'1': 'new/1.mp4', '2': 'p/2.mp4'},
          inFlight: {},
        ),
      );
      expect(outcome.prune, isEmpty);
      expect(outcome.stripFromArchive, isEmpty,
          reason: 'stripping its archive line would make yt-dlp fetch it again');
    });

    test('an entry deleted during the scan is not badged again', () {
      final outcome = reconcileDownloadScan(
        scanned: scanned,
        plan: plan,
        now: const DownloadScanInput(
          downloadRoot: 'D',
          channelName: 'chan',
          vodIds: [],
          registry: {'1': 'old/1.mp4'},
          inFlight: {},
        ),
      );
      expect(outcome.downloaded, {'9'});
    });

    test('a file whose VOD was queued again meanwhile is not adopted', () {
      final outcome = reconcileDownloadScan(
        scanned: scanned,
        plan: plan,
        now: const DownloadScanInput(
          downloadRoot: 'D',
          channelName: 'chan',
          vodIds: [],
          registry: {'1': 'old/1.mp4', '2': 'p/2.mp4'},
          inFlight: {'9'},
        ),
      );
      expect(outcome.additions, isEmpty);
      expect(outcome.downloaded, {'2'});
    });
  });

  group('rescan', () {
    test('folds requests during a scan into one more pass', () async {
      final gate = Completer<void>();
      var scans = 0;
      final outcomes = <DownloadScanOutcome>[];
      final downloads = DownloadsController(
        onQueueChanged: () {},
        readScanInput: () => const DownloadScanInput(
            downloadRoot: 'D', channelName: '', vodIds: [], registry: {}, inFlight: {}),
        onScanned: outcomes.add,
        runScan: (_) async {
          scans++;
          if (scans == 1) await gate.future;
          return const RegistryScanPlan(
              present: {}, unverified: {}, prune: {}, stripFromArchive: {}, additions: {});
        },
      );

      final first = downloads.rescan();
      for (var i = 0; i < 5; i++) {
        unawaited(downloads.rescan());
      }
      gate.complete();
      await first;

      expect(scans, 2, reason: 'one listing in flight, then one to catch up');
      expect(outcomes, hasLength(2));
    });

    test('with no download folder, nothing is badged and nothing is listed',
        () async {
      var scans = 0;
      DownloadScanOutcome? outcome;
      final downloads = DownloadsController(
        onQueueChanged: () {},
        readScanInput: () => const DownloadScanInput(
            downloadRoot: '', channelName: '', vodIds: ['1'], registry: {'1': 'x'}, inFlight: {}),
        onScanned: (o) => outcome = o,
        runScan: (_) async {
          scans++;
          return null;
        },
      );
      await downloads.rescan();
      expect(scans, 0);
      expect(outcome!.downloaded, isEmpty);
      expect(outcome!.registryChanged, isFalse);
    });

    test('a scan that fails changes nothing', () async {
      var reported = false;
      final downloads = DownloadsController(
        onQueueChanged: () {},
        readScanInput: () => const DownloadScanInput(
            downloadRoot: 'D', channelName: '', vodIds: [], registry: {}, inFlight: {}),
        onScanned: (_) => reported = true,
        runScan: (_) async => throw const FileSystemException('share went away'),
      );
      await downloads.rescan();
      expect(reported, isFalse);
    });

    test('runs on a background isolate against the real disk', () async {
      final root = Directory.systemTemp.createTempSync('streamlink_gui_iso_');
      addTearDown(() => root.deleteSync(recursive: true));
      final channel = Directory('${root.path}${Platform.pathSeparator}chan')
        ..createSync();
      final file = File('${channel.path}${Platform.pathSeparator}A - 77.mkv')
        ..writeAsStringSync('x');

      DownloadScanOutcome? outcome;
      final downloads = DownloadsController(
        onQueueChanged: () {},
        readScanInput: () => DownloadScanInput(
          downloadRoot: root.path,
          channelName: 'chan',
          vodIds: const ['77'],
          registry: const {},
          inFlight: const {},
        ),
        onScanned: (o) => outcome = o,
      );
      await downloads.rescan();
      expect(outcome!.additions, {'77': file.path});
      expect(outcome!.downloaded, {'77'});
    });

    test('a scan that comes back after dispose is dropped', () async {
      final gate = Completer<RegistryScanPlan?>();
      var reported = false;
      final downloads = DownloadsController(
        onQueueChanged: () {},
        readScanInput: () => const DownloadScanInput(
            downloadRoot: 'D', channelName: '', vodIds: [], registry: {}, inFlight: {}),
        onScanned: (_) => reported = true,
        runScan: (_) => gate.future,
      );
      final scan = downloads.rescan();
      downloads.dispose();
      gate.complete(const RegistryScanPlan(
          present: {}, unverified: {}, prune: {}, stripFromArchive: {}, additions: {}));
      await scan;
      expect(reported, isFalse);
    });
  });
}
