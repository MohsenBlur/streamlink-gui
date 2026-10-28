import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/services/config_secrets.dart';
import 'package:streamlink_gui/services/storage_service.dart';

import 'support/fake_cipher.dart';

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
  group('write failures are reported', () {
    tearDown(() => storageWriteFailure.value = null);

    test('an unwritable target sets the failure, and a good save clears it', () async {
      // Regression: the error was recorded in a field nothing read, so a save
      // that never reached disk looked identical to a successful one and the
      // user lost everything at next launch.
      final blocked = configFile().path;
      Directory(blocked).createSync(recursive: true); // a directory, not a file

      await save(storage, ['a']);
      expect(storageWriteFailure.value, isNotNull);
      expect(storageWriteFailure.value!.path, blocked);

      Directory(blocked).deleteSync(recursive: true);
      await save(storage, ['a']);
      expect(storageWriteFailure.value, isNull);
    });

    test('a successful save leaves the failure state clear', () async {
      await save(storage, ['a']);
      expect(storageWriteFailure.value, isNull);
    });

    test('a failed temp write leaves the last good config byte-identical', () async {
      // Regression: a failed temp write fell back to writing the real file
      // directly, which truncates it first. On a full disk that fallback
      // failed too, leaving an empty config that loaded as defaults - and the
      // next autosave made the loss permanent. The real file must only ever
      // change by the atomic rename.
      await save(storage, ['keep-me'], quality: 'good');
      final before = configFile().readAsBytesSync();

      // A temp path whose directory does not exist fails the temp write, the
      // way a full disk does, while the real file stays perfectly writable.
      StorageService.tempPathOverride = (target) =>
          '${tempDir.path}${Platform.pathSeparator}missing${Platform.pathSeparator}x.tmp';
      addTearDown(() => StorageService.tempPathOverride = null);

      await save(storage, ['replacement'], quality: 'bad');

      expect(storageWriteFailure.value, isNotNull,
          reason: 'the lost save must still be reported');
      expect(configFile().readAsBytesSync(), before,
          reason: 'the real config must not be written in place');

      StorageService.tempPathOverride = null;
      final loaded = await storage.loadConfig();
      expect(loaded!['settings']['default_quality'], 'good');
    });

    test('a failed rename leaves no temp file behind', () async {
      // The target is a directory, so the temp write succeeds and the rename
      // onto it fails - the temp must still be cleaned up on both attempts.
      Directory(configFile().path).createSync(recursive: true);

      await save(storage, ['a']);

      expect(storageWriteFailure.value, isNotNull);
      final leftovers = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });
  });

  group('debris does not accumulate', () {
    test('an aged orphan temp file is swept on load, a fresh one is kept', () async {
      await save(storage, ['a']);
      final base = configFile().path;

      final old = File('$base.111.tmp')..writeAsStringSync('{}');
      old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 3)));
      final fresh = File('$base.222.tmp')..writeAsStringSync('{}');
      // Not our shape: must be left alone whatever its age.
      final unrelated = File('$base.notes.tmp')..writeAsStringSync('{}');
      unrelated.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 9)));

      await storage.loadConfig();

      expect(old.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
    });

    test('quarantined copies are capped, newest kept', () async {
      final file = configFile();
      // Each corrupt load renames the file away, so write a fresh bad one each time.
      for (var i = 0; i < 5; i++) {
        file.writeAsStringSync('not json $i');
        expect(await storage.loadConfig(), isNull);
      }

      final copies = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt-'))
          .toList();
      expect(copies.length, lessThanOrEqualTo(3));
    });
  });

  group('stored tokens are sealed at rest', () {
    const account = 'abcdefghijklmnopqrstuvwxyz0123';
    const browser = 'zyxwvutsrqponmlkjihgfedcba9876';

    setUp(() => StorageService.secretCipher = FakeCipher());
    tearDown(() => StorageService.secretCipher = null);

    /// The next launch: nothing remembered from earlier loads or saves.
    void relaunch() => StorageService.secretCipher = FakeCipher();

    Future<void> saveTokens(String a, String b) => storage.saveConfig(
          [TwitchChannel(username: 'alpha')],
          AppSettings(twitchOauthToken: a, twitchWebOauthToken: b),
          <String, int>{},
          <String, String>{},
        );

    test('a save writes no token to disk, and a load reads both back', () async {
      await saveTokens(account, browser);

      final raw = configFile().readAsStringSync();
      expect(raw, isNot(contains(account)));
      expect(raw, isNot(contains(browser)));

      relaunch();
      final loaded = await storage.loadConfig();
      expect(loaded!['settings']['twitch_oauth_token'], account);
      expect(loaded['settings']['twitch_web_oauth_token'], browser);
    });

    test('a plaintext config from an older build is migrated on load, losing nothing', () async {
      // Written as every build before this one wrote it, plus keys this build
      // does not know, which the migration must not drop the way a full
      // saveConfig would.
      final legacy = {
        'channels': [
          {'username': 'alpha'},
        ],
        'settings': {
          ...AppSettings(twitchOauthToken: account, twitchWebOauthToken: browser).toJson(),
          'setting_from_a_newer_build': 'keep me',
        },
        'local_vods_progress': {'v1': 42},
        'downloaded_vods': <String, String>{},
        'key_from_a_newer_build': [1, 2, 3],
      };
      configFile().writeAsStringSync(json.encode(legacy));

      final loaded = await storage.loadConfig();

      expect(loaded!['settings']['twitch_oauth_token'], account,
          reason: 'the app runs on the plaintext it read');
      final onDisk = json.decode(configFile().readAsStringSync()) as Map<String, dynamic>;
      expect(json.encode(onDisk), isNot(contains(account)));
      expect(json.encode(onDisk), isNot(contains(browser)));
      expect(ConfigSecrets.isSealed(onDisk['settings']['twitch_oauth_token']), isTrue);
      expect(onDisk['settings']['setting_from_a_newer_build'], 'keep me');
      expect(onDisk['key_from_a_newer_build'], [1, 2, 3]);
      expect(onDisk['local_vods_progress'], {'v1': 42});
      expect(onDisk['channels'], legacy['channels']);

      // The migrated file reads back the same, and is not rewritten again.
      relaunch();
      final migrated = configFile().readAsBytesSync();
      final again = await storage.loadConfig();
      expect(again!['settings']['twitch_web_oauth_token'], browser);
      expect(configFile().readAsBytesSync(), migrated);
    });

    test('a config with no account is left exactly as it is', () async {
      await saveTokens('', '');
      final before = configFile().readAsBytesSync();

      relaunch();
      await storage.loadConfig();

      expect(configFile().readAsBytesSync(), before);
      expect(json.decode(utf8.decode(before))['settings']['twitch_oauth_token'], '');
    });

    test('a token sealed elsewhere survives a load-and-save here', () async {
      StorageService.secretCipher = FakeCipher(account: 0x11);
      await saveTokens(account, browser);
      final sealedElsewhere =
          json.decode(configFile().readAsStringSync())['settings']['twitch_oauth_token'];

      relaunch(); // a different account: cannot open it
      final loaded = await storage.loadConfig();
      expect(loaded!['settings']['twitch_oauth_token'], '');
      await storage.saveConfig(
        const [],
        AppSettings.fromJson(loaded['settings']),
        <String, int>{},
        <String, String>{},
      );

      expect(json.decode(configFile().readAsStringSync())['settings']['twitch_oauth_token'],
          sealedElsewhere);
    });
  });

  group('configExists', () {
    test('distinguishes absent from present-but-unreadable', () async {
      expect(storage.configExists(), isFalse);

      configFile().writeAsStringSync('not json');
      expect(storage.configExists(), isTrue);

      // loadConfig quarantines it, so afterwards there is genuinely no config.
      expect(await storage.loadConfig(), isNull);
      expect(storage.configExists(), isFalse);
    });
  });
}
