import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/downloads_controller.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/settings_repository.dart';
import 'package:streamlink_gui/state/watch_progress_store.dart';

import 'support/fake_process.dart';

/// When the three files are written: the gates that keep a save from
/// replacing data not yet read, and the delays that keep a progress tick from
/// rewriting everything.
void main() {
  group('the gates', () {
    late List<String> writes;
    late SettingsRepository repo;

    setUp(() {
      writes = [];
      repo = SettingsRepository(
        writeConfig: () async => writes.add('config'),
        writeProgress: () async => writes.add('progress'),
        writeRecents: () async => writes.add('recents'),
        saveDelay: const Duration(milliseconds: 10),
        progressDelay: const Duration(milliseconds: 40),
      );
    });
    tearDown(() => repo.dispose());

    test('nothing is written before its file has been read', () async {
      await repo.saveNow(recents: true);
      repo.noteProgress(recents: true);
      await repo.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(writes, isEmpty);
      expect(repo.hasPendingWrites, isTrue);
    });

    test('a write asked for early is held, not dropped', () async {
      await repo.saveNow();
      repo.noteProgress(recents: true);

      repo.markConfigLoaded();
      await pumpEventQueue();
      expect(writes, ['config'], reason: 'the history is not read yet');

      repo.markHistoryLoaded();
      await pumpEventQueue();
      expect(writes, ['config', 'progress', 'recents']);
      expect(repo.hasPendingWrites, isFalse);
    });

    test('opening a gate with nothing held writes nothing', () async {
      repo
        ..markConfigLoaded()
        ..markHistoryLoaded();
      await pumpEventQueue();
      expect(writes, isEmpty);
    });
  });

  group('once loaded', () {
    late List<String> writes;
    late SettingsRepository repo;

    setUp(() {
      writes = [];
      repo = SettingsRepository(
        writeConfig: () async => writes.add('config'),
        writeProgress: () async => writes.add('progress'),
        writeRecents: () async => writes.add('recents'),
        saveDelay: const Duration(milliseconds: 10),
        progressDelay: const Duration(milliseconds: 60),
      )
        ..markConfigLoaded()
        ..markHistoryLoaded();
    });
    tearDown(() => repo.dispose());

    test('saveNow writes the config and the progress before it completes',
        () async {
      await repo.saveNow();
      expect(writes, ['config', 'progress']);
    });

    test('saveNow with recents writes the history list as well', () async {
      // Removing a VOD from the history wrote the list straight through the
      // storage service, round the history gate.
      await repo.saveNow(recents: true);
      expect(writes, ['config', 'progress', 'recents']);
    });

    test('a burst of requested saves is one write', () async {
      for (var i = 0; i < 12; i++) {
        repo.requestSave();
      }
      expect(writes, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(writes, ['config']);
    });

    test('progress ticks are written once per delay, not once per tick',
        () async {
      // Thirty ticks inside one delay - a tracker polling every two seconds
      // does about ten in the twenty seconds the app uses.
      for (var i = 0; i < 30; i++) {
        repo.noteProgress(recents: true);
        await pumpEventQueue(times: 2);
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(writes, unorderedEquals(['config', 'progress', 'recents']),
          reason: 'one round for the lot; it used to be three writes per tick');
    });

    test('a stream of ticks cannot put the write off forever', () async {
      final stopAt = DateTime.now().add(const Duration(milliseconds: 200));
      while (DateTime.now().isBefore(stopAt)) {
        repo.noteProgress();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(writes.where((w) => w == 'progress').length, greaterThanOrEqualTo(2));
    });

    test('flushProgress writes a held position at once', () async {
      repo.noteProgress(recents: true);
      await repo.flushProgress();
      expect(writes, unorderedEquals(['config', 'progress', 'recents']));

      // ...and the timer it replaced does not write it again.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(writes, hasLength(3));
    });

    test('flushProgress with nothing held writes nothing', () async {
      await repo.flushProgress();
      expect(writes, isEmpty);
    });

    test('flushNow writes all three, held or not', () async {
      await repo.flushNow();
      expect(writes, unorderedEquals(['config', 'progress', 'recents']));
    });

    test('dispose writes out whatever was held', () async {
      repo.noteProgress(recents: true);
      repo.dispose();
      await pumpEventQueue();
      expect(writes, unorderedEquals(['config', 'progress', 'recents']));
    });
  });

  test('a writer that throws in the background is reported, not unhandled',
      () async {
    final errors = <Object>[];
    final repo = SettingsRepository(
      writeConfig: () => throw StateError('disk'),
      writeProgress: () async {},
      writeRecents: () async {},
      saveDelay: const Duration(milliseconds: 5),
      onError: (e, _) => errors.add(e),
    )
      ..markConfigLoaded()
      ..markHistoryLoaded();
    repo.requestSave();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(errors.single, isA<StateError>());
    repo.dispose();
  });

  // The launch the audit traced (H3), through the real storage, the real
  // queue bookkeeping and a real PlayerService with a fake yt-dlp, in the
  // order the main screen runs it: config parsed, saved queue adopted and
  // re-queued, the window settling and saving - all before the history has
  // been read.
  group('a launch with unfinished downloads', () {
    late Directory temp;
    late FakeLauncher launcher;
    late PlayerService player;
    final storage = StorageService();

    File file(String name) => File('${temp.path}${Platform.pathSeparator}$name');
    Map<String, dynamic> readJson(String name) =>
        json.decode(file(name).readAsStringSync()) as Map<String, dynamic>;

    final queued = TwitchVideo(
      id: '555',
      title: 'Queued VOD',
      duration: '1h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026),
    );

    setUp(() {
      temp = Directory.systemTemp.createTempSync('streamlink_gui_launch_');
      StorageService.storageDirectoryOverride = temp.path;
      launcher = FakeLauncher();
      player = PlayerService(
          startProcess: launcher.start, runProcess: FakeTaskkill(launcher).run);

      // What the last run left: a VOD whose furthest point (5000s) is far
      // ahead of where a bad session dragged it back to (100s), with the
      // trail that records how - and a download still queued.
      file('channels_config.json').writeAsStringSync(json.encode({
        'channels': [],
        'settings': AppSettings(
          vodDownloadFolder: temp.path,
          unfinishedDownloads: [
            {'vod': queued.toJson(), 'channelName': 'chan'},
          ],
        ).toJson(),
        'local_vods_progress': {'42': 100},
        'downloaded_vods': {},
      }));
      file('watch_progress.json').writeAsStringSync(json.encode({
        '42': {
          'p': 100,
          'u': 2000,
          'b': 5000,
          'ba': 1000,
          'r': [
            {'s': 4990, 't': 1500},
          ],
        },
      }));
    });

    tearDown(() async {
      await player.stopAll();
      StorageService.storageDirectoryOverride = null;
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('keeps the furthest point, the undo trail and the queue', () async {
      // The config, parsed; progress starts from its flat copy.
      final config = (await storage.loadStartupConfig()).data!;
      final settings =
          AppSettings.fromJson(config['settings'] as Map<String, dynamic>);
      var flat = <String, int>{'42': 100};
      var store = WatchProgressStore.fromJson({'42': 100});

      late SettingsRepository repo;
      final downloads = DownloadsController(
        onQueueChanged: () => repo.requestSave(),
        readScanInput: () => const DownloadScanInput(
            downloadRoot: '', channelName: '', vodIds: [], registry: {}, inFlight: {}),
        onScanned: (_) {},
      );
      repo = SettingsRepository(
        writeConfig: () {
          final unfinished = downloads.persisted;
          if (unfinished != null) settings.unfinishedDownloads = unfinished;
          return storage.saveConfig([], settings, flat, {});
        },
        writeProgress: () => storage.saveWatchProgress(store.toJson()),
        writeRecents: () => storage.saveRecentWatchedVods([]),
        saveDelay: const Duration(milliseconds: 5),
      );
      addTearDown(repo.dispose);
      player.onDownloadQueued = downloads.remember;

      final resumable = downloads.restore(settings.unfinishedDownloads);
      repo.markConfigLoaded();

      // Before the history is read: the resume, which used to clear the
      // saved queue and save, and a window move's save.
      for (final download in resumable) {
        player.queueVodDownload(download.vod, download.channelName, settings);
      }
      await repo.saveNow();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(readJson('watch_progress.json')['42']['b'], 5000,
          reason: 'the sidecar must not be written before it has been read');

      // The history, read and merged as the main screen does it.
      final sidecar = await storage.loadWatchProgress();
      store = WatchProgressStore.fromJson({...store.toJson(), ...sidecar});
      flat = store.toFlatMap();
      repo.markHistoryLoaded();
      await repo.flushNow();

      final saved = readJson('watch_progress.json')['42'] as Map<String, dynamic>;
      expect(saved['b'], 5000, reason: 'the furthest point survives');
      expect(saved['p'], 100);
      expect(saved['r'], [
        {'s': 4990, 't': 1500},
      ], reason: 'so does the undo trail');
      expect(store['42']!.hasRecoverablePosition, isTrue,
          reason: 'so the "jump back" offer is still made');

      final savedQueue = (readJson('channels_config.json')['settings']
          as Map<String, dynamic>)['unfinished_downloads'] as List;
      expect(savedQueue.map((e) => (e as Map)['vod']['id']), ['555'],
          reason: 'the resumed queue stays saved until it finishes');
      expect(launcher.launched, hasLength(1), reason: 'and it did resume');
    });
  });
}
