import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/update_service.dart';

/// The channels_config.json older builds mirrored beside the executable on
/// every save - the whole config, Twitch tokens in plaintext, even for an
/// installed copy - and what removes it now: the app at startup where it can
/// write, the updater's write step where only that can (Program Files).
///
/// The rules that matter are the refusals. In a portable copy that file IS
/// the config, and while AppData has no config yet it is what the one-time
/// migration in getStorageFile still reads.
void main() {
  late Directory root;
  late Directory exeDir;
  late Directory appData;

  setUp(() {
    root = Directory.systemTemp.createTempSync('streamlink_gui_mirror_test_');
    exeDir = Directory(p.join(root.path, 'install'))..createSync();
    appData = Directory(p.join(root.path, 'appdata'))..createSync();
    StorageService.exeDirectoryOverride = exeDir.path;
    StorageService.storageDirectoryOverride = appData.path;
  });

  tearDown(() {
    StorageService.exeDirectoryOverride = null;
    StorageService.storageDirectoryOverride = null;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  File mirror() => File(p.join(exeDir.path, 'channels_config.json'));
  File config() => File(p.join(appData.path, 'channels_config.json'));
  const mirrored = '{"settings":{"twitch_oauth_token":"plaintext"}}';
  const current = '{"settings":{"twitch_oauth_token":"sealed"}}';

  group('at startup', () {
    test('a mirror beside an installed copy is deleted once AppData has the config', () {
      mirror().writeAsStringSync(mirrored);
      config().writeAsStringSync(current);

      final line = StorageService().dropStaleConfigMirror();

      expect(mirror().existsSync(), isFalse);
      expect(line, contains('removed'));
      expect(config().readAsStringSync(), current,
          reason: 'the config itself is never touched');
    });

    test("a portable copy's config is never deleted", () {
      File(p.join(exeDir.path, 'portable.txt')).writeAsStringSync('');
      mirror().writeAsStringSync(mirrored);
      config().writeAsStringSync(current);

      expect(StorageService().dropStaleConfigMirror(), isNull);
      expect(mirror().readAsStringSync(), mirrored);
    });

    test('with no config in AppData yet the mirror is kept for the migration', () {
      mirror().writeAsStringSync(mirrored);

      expect(StorageService().dropStaleConfigMirror(), isNull);
      expect(mirror().readAsStringSync(), mirrored);
    });

    test('a config that lives beside the exe is not a mirror of itself', () {
      // No AppData folder: getStorageFile keeps the config beside the exe.
      StorageService.storageDirectoryOverride = exeDir.path;
      mirror().writeAsStringSync(current);

      expect(StorageService().dropStaleConfigMirror(), isNull);
      expect(mirror().readAsStringSync(), current);
    });

    test('nothing to say when there is no mirror', () {
      config().writeAsStringSync(current);
      expect(StorageService().dropStaleConfigMirror(), isNull);
    });

    test('a mirror this process cannot delete is kept, and says so', () {
      // Program Files, where only the updater's elevated step can delete
      // it. A read-only file is the same refusal without needing one.
      mirror().writeAsStringSync(mirrored);
      config().writeAsStringSync(current);
      Process.runSync('attrib', ['+r', mirror().path]);
      addTearDown(() => Process.runSync('attrib', ['-r', mirror().path]));

      final line = StorageService().dropStaleConfigMirror();

      expect(mirror().existsSync(), isTrue);
      expect(line, contains('kept'));
      expect(line, contains('next update'));
    }, skip: !Platform.isWindows);

    test('startup deletes it only after the config loaded', () {
      // A config that would not load is quarantined, and the next launch's
      // migration recovers from the mirror: it must outlive that launch.
      final src = File('lib/app_startup.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final start = src.indexOf('Future<void> startApp(');
      expect(start, isNonNegative);
      final body = src.substring(start, src.indexOf('\n}\n', start));
      final call = body.indexOf('storage.dropStaleConfigMirror()');
      expect(call, isNonNegative, reason: 'startup no longer removes the mirror');
      final guard = body.lastIndexOf('if (startup.data != null)', call);
      expect(guard, isNonNegative);
      expect(body.indexOf('}', guard), greaterThan(call),
          reason: 'the removal must sit inside the loaded-config guard');
      expect(body.indexOf('storage.loadStartupConfig()'), lessThan(guard));
    });
  });

  group('the updater is asked to delete it', () {
    test('only for a copy whose config lives in AppData', () {
      expect(StorageService().configLivesInAppData(), isFalse,
          reason: 'no config in AppData yet');

      config().writeAsStringSync(current);
      expect(StorageService().configLivesInAppData(), isTrue);

      File(p.join(exeDir.path, 'portable.txt')).writeAsStringSync('');
      expect(StorageService().configLivesInAppData(), isFalse,
          reason: 'portable: the file beside the exe is the config');
    });

    test('asking creates and migrates nothing', () {
      // Unlike getStorageFile, which copies the mirror into an AppData folder
      // that has no config: the update path must not start a migration.
      mirror().writeAsStringSync(mirrored);
      StorageService.storageDirectoryOverride = p.join(root.path, 'fresh');

      expect(StorageService().configLivesInAppData(), isFalse);
      expect(Directory(p.join(root.path, 'fresh')).existsSync(), isFalse);
      expect(mirror().readAsStringSync(), mirrored);
    });

    List<String> args({required bool drop}) => UpdateService.updaterArguments(
          targetPath: r'C:\Apps\Streamlink GUI',
          sourcePath: r'C:\Temp\streamlink_gui_update_1\extracted\app',
          exeName: 'streamlink_gui.exe',
          readyFile: r'C:\Temp\streamlink_updater_ready_1',
          appPid: 4242,
          dropConfigMirror: drop,
        );

    test('by a flag of its own, after everything an older updater reads', () {
      final asked = args(drop: true);
      expect(asked.last, '--drop-config-mirror');
      expect(asked.sublist(0, asked.length - 1), args(drop: false),
          reason: 'every other argument stays where it was');
      expect(args(drop: false), isNot(contains('--drop-config-mirror')));
    });

    test('startUpdater passes the flag on the AppData rule', () {
      final src = File('lib/services/update_service.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final start = src.indexOf('Future<void> startUpdater(');
      expect(start, isNonNegative);
      expect(src.substring(start),
          contains('dropConfigMirror: StorageService().configLivesInAppData()'));
    });

    test('the native updater reads the same flag', () {
      final cpp = File('windows/runner/win32_updater/main.cpp').readAsStringSync();
      expect(cpp, contains('L"${UpdateService.dropConfigMirrorFlag}"'));
    });

    test('and hands it to the elevated child, which deletes it', () {
      // Under Program Files - where the mirror this exists for sits - only
      // the elevated child can write the folder, and it is started with a
      // command line of its own. Dropped there, the request did nothing for
      // exactly the installs that need it, and no other test would notice.
      final cpp = File('windows/runner/win32_updater/main.cpp')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      String body(String signature) {
        final start = cpp.indexOf(signature);
        expect(start, isNonNegative, reason: signature);
        return cpp.substring(start, cpp.indexOf('\n}\n', start));
      }

      expect(body('SwapOutcome RunElevatedSwap('),
          contains('params += std::wstring(L" ") + DROP_CONFIG_MIRROR_FLAG;'));
      final main = body('int APIENTRY wWinMain(');
      final elevated = main.indexOf('if (isElevated) {');
      expect(elevated, isNonNegative);
      expect(main.substring(elevated, main.indexOf('\n    }\n', elevated)),
          contains('if (dropConfigMirror) DropConfigMirror(targetDir);'));
      expect(main,
          contains('RunElevatedSwap(targetDir, stagingDir, exeName, dropConfigMirror)'));
    });
  });
}
