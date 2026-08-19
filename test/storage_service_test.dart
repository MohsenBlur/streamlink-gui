import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/services/storage_service.dart';

void main() {
  late Directory tempDir;
  late StorageService storage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('streamlink_gui_storage_test_');
    StorageService.storageDirectoryOverride = tempDir.path;
    storage = StorageService();
  });

  tearDown(() {
    StorageService.storageDirectoryOverride = null;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File configFile() => File('${tempDir.path}${Platform.pathSeparator}channels_config.json');

  Future<void> save(StorageService s, List<String> channelNames, {String quality = 'best'}) {
    return s.saveConfig(
      channelNames.map((n) => TwitchChannel(username: n)).toList(),
      AppSettings(defaultQuality: quality),
      <String, int>{},
      <String, String>{},
    );
  }

  group('StorageService persistence', () {
    test('round-trips a saved config', () async {
      await save(storage, ['alpha', 'beta'], quality: '720p');

      final loaded = await storage.loadConfig();
      expect(loaded, isNotNull);
      expect((loaded!['channels'] as List), hasLength(2));
      expect(loaded['settings']['default_quality'], '720p');
    });

    test('concurrent saves never corrupt the file and leave no temp files', () async {
      // Watch-progress ticks fire saveConfig repeatedly without awaiting. These
      // used to share one `<file>.tmp` path, so one call could rename the temp
      // away while another was still writing it.
      final futures = <Future<void>>[];
      for (var i = 0; i < 40; i++) {
        futures.add(save(storage, ['chan$i'], quality: 'q$i'));
      }
      await Future.wait(futures);

      final loaded = await storage.loadConfig();
      expect(loaded, isNotNull, reason: 'config must remain readable after concurrent saves');
      expect(loaded!['channels'], isA<List>());

      final leftovers = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty, reason: 'no temp files should survive');
    });

    test('the config file is never absent while saves are in flight', () async {
      await save(storage, ['seed']);

      // Kick off a burst of saves and sample the file between microtasks. The
      // old delete-then-rename sequence left a window with no config at all, so
      // a crash there lost everything.
      final futures = <Future<void>>[];
      for (var i = 0; i < 25; i++) {
        futures.add(save(storage, ['chan$i']));
      }

      var sawMissing = false;
      for (var i = 0; i < 25; i++) {
        await Future<void>.delayed(Duration.zero);
        if (!configFile().existsSync()) sawMissing = true;
      }
      await Future.wait(futures);

      expect(sawMissing, isFalse, reason: 'config must always exist on disk');
      expect(configFile().existsSync(), isTrue);
    });

    test('the last write wins after coalescing', () async {
      final futures = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(save(storage, ['chan'], quality: 'quality-$i'));
      }
      await Future.wait(futures);

      final loaded = await storage.loadConfig();
      expect(loaded!['settings']['default_quality'], 'quality-9');
    });

    test('separate StorageService instances still serialize on the same file', () async {
      // main.dart and PlayerService each construct their own instance.
      final a = StorageService();
      final b = StorageService();
      await Future.wait([
        save(a, ['from-a'], quality: 'a'),
        save(b, ['from-b'], quality: 'b'),
      ]);

      final loaded = await storage.loadConfig();
      expect(loaded, isNotNull);
      expect(loaded!['settings']['default_quality'], anyOf('a', 'b'));
    });
  });

  group('StorageService corruption handling', () {
    test('quarantines an unparseable config instead of ignoring it', () async {
      configFile().writeAsStringSync('{ this is not valid json');

      final loaded = await storage.loadConfig();
      expect(loaded, isNull);

      final quarantined = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1),
          reason: 'the bad file must be preserved, not silently overwritten');
      expect(configFile().existsSync(), isFalse);
    });

    test('treats an empty config as absent without quarantining it', () async {
      configFile().writeAsStringSync('');
      expect(await storage.loadConfig(), isNull);
      expect(
        tempDir.listSync().whereType<File>().where((f) => f.path.contains('.corrupt-')),
        isEmpty,
      );
    });

    test('returns null when no config exists yet', () async {
      expect(await storage.loadConfig(), isNull);
    });
  });

  group('StorageService recent watched VODs', () {
    test('round-trips the list', () async {
      await storage.saveRecentWatchedVods([
        {'id': '1', 'title': 'one'},
        {'id': '2', 'title': 'two'},
      ]);

      final loaded = await storage.loadRecentWatchedVods();
      expect(loaded, hasLength(2));
      expect(loaded.first['title'], 'one');
    });

    test('recovers from a corrupt list file', () async {
      File('${tempDir.path}${Platform.pathSeparator}recent_watched_vods.json')
          .writeAsStringSync('not json at all');

      expect(await storage.loadRecentWatchedVods(), isEmpty);
    });

    test('written content is valid JSON', () async {
      await storage.saveRecentWatchedVods([
        {'id': '1', 'title': 'quotes " and \\ backslash'},
      ]);
      final raw = File('${tempDir.path}${Platform.pathSeparator}recent_watched_vods.json')
          .readAsStringSync();
      expect(() => json.decode(raw), returnsNormally);
    });
  });
}
