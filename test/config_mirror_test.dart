import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/update_service.dart';

/// The channels_config.json older builds mirrored beside the executable on
/// every save - the whole config, Twitch tokens in plaintext, even for an
/// installed copy - and what is done about it now: the app scrubs its tokens
/// at startup where it can write, the updater's elevated step deletes it
/// where only that can (Program Files).
///
/// The rules that matter are the refusals. In a portable copy that file IS
/// the config, and while AppData has no config yet it is what the one-time
/// migration in getStorageFile still reads. And the app never deletes it:
/// a portable copy whose portable.txt went missing looks just like a stale
/// mirror, and there the file is the user's real config.
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

  /// A whole config as an older build mirrored it, or as a portable copy
  /// keeps it: channels, history and settings around the two tokens.
  String wholeConfig({String account = 'oauth-plaintext', String browser = 'dpapi:v1:AAAA'}) =>
      '{"channels":[{"username":"alpha","is_favorite":true}],'
      '"settings":{"twitch_oauth_token":"$account","default_quality":"720p60",'
      '"twitch_web_oauth_token":"$browser","material":"deck"},'
      '"local_vods_progress":{"v1":1234},"downloaded_vods":{}}';

  List<String> leftovers() => exeDir
      .listSync()
      .map((e) => p.basename(e.path))
      .where((name) => name != 'channels_config.json')
      .toList();

  group('at startup', () {
    test("a mirror beside an installed copy loses its tokens and keeps the rest", () {
      mirror().writeAsStringSync(wholeConfig());
      config().writeAsStringSync(current);

      final line = StorageService().scrubStaleConfigMirror();

      expect(mirror().readAsStringSync(), wholeConfig(account: '', browser: ''),
          reason: 'only the token values change, sealed or not');
      expect(line, contains('scrubbed'));
      expect(line, contains(mirror().path));
      expect(leftovers(), isEmpty, reason: 'the temp file is renamed into place');
      expect(config().readAsStringSync(), current,
          reason: 'the config itself is never touched');
    });

    test('a portable copy that lost its portable.txt keeps everything but the tokens', () {
      // The case deleting got wrong: a portable folder moved or copied
      // without its marker reads as an installed copy with a stale mirror,
      // and putting portable.txt back must still find the user's channels.
      mirror().writeAsStringSync(wholeConfig());
      config().writeAsStringSync(current);
      StorageService().scrubStaleConfigMirror();

      File(p.join(exeDir.path, 'portable.txt')).writeAsStringSync('');
      final restored = json.decode(mirror().readAsStringSync()) as Map<String, dynamic>;

      expect(restored['channels'], [
        {'username': 'alpha', 'is_favorite': true}
      ]);
      expect(restored['local_vods_progress'], {'v1': 1234});
      expect((restored['settings'] as Map)['material'], 'deck');
    });

    test('a mirror that does not parse is scrubbed byte for byte', () {
      // Cut off mid-write, and not even UTF-8 (a lone 0xE9): what is not a
      // token survives exactly.
      final head = utf8.encode('{"channels":[{"username":"caf');
      final tail = utf8.encode('"}],"settings":{"twitch_oauth_token":"oauth-plain');
      mirror().writeAsBytesSync([...head, 0xE9, ...tail]);
      config().writeAsStringSync(current);

      expect(StorageService().scrubStaleConfigMirror(), contains('scrubbed'));
      expect(mirror().readAsBytesSync(), [
        ...head,
        0xE9,
        ...utf8.encode('"}],"settings":{"twitch_oauth_token":"'),
      ]);
    });

    test('a mirror with no token in it is left as it is', () {
      mirror().writeAsStringSync(wholeConfig(account: '', browser: ''));
      config().writeAsStringSync(current);
      final stamp = DateTime(2020, 1, 2, 3, 4, 5);
      mirror().setLastModifiedSync(stamp);

      expect(StorageService().scrubStaleConfigMirror(), isNull);
      expect(mirror().lastModifiedSync(), stamp, reason: 'not rewritten');
    });

    test("a portable copy's config is never touched", () {
      File(p.join(exeDir.path, 'portable.txt')).writeAsStringSync('');
      mirror().writeAsStringSync(mirrored);
      config().writeAsStringSync(current);

      expect(StorageService().scrubStaleConfigMirror(), isNull);
      expect(mirror().readAsStringSync(), mirrored);
    });

    test('with no config in AppData yet the mirror is kept for the migration', () {
      mirror().writeAsStringSync(mirrored);

      expect(StorageService().scrubStaleConfigMirror(), isNull);
      expect(mirror().readAsStringSync(), mirrored);
    });

    test('a config that lives beside the exe is not a mirror of itself', () {
      // No AppData folder: getStorageFile keeps the config beside the exe.
      StorageService.storageDirectoryOverride = exeDir.path;
      mirror().writeAsStringSync(mirrored);

      expect(StorageService().scrubStaleConfigMirror(), isNull);
      expect(mirror().readAsStringSync(), mirrored);
    });

    test('nor is the config reached through another path to its folder', () {
      // The exe's folder a junction or link to the config's: two paths that
      // do not compare equal, one file. Scrubbed, that blanked the live
      // tokens at every start; and the updater was asked to delete it.
      final via = Link(p.join(root.path, 'via'))..createSync(appData.path);
      addTearDown(() {
        try {
          via.deleteSync();
        } catch (_) {}
      });
      StorageService.exeDirectoryOverride = via.path;
      config().writeAsStringSync(mirrored);

      expect(StorageService().scrubStaleConfigMirror(), isNull);
      expect(config().readAsStringSync(), mirrored);
      expect(StorageService().configLivesInAppData(), isFalse,
          reason: 'the file beside the exe is the config');
    });

    test('nothing to say when there is no mirror', () {
      config().writeAsStringSync(current);
      expect(StorageService().scrubStaleConfigMirror(), isNull);
    });

    test('a mirror this process cannot rewrite is kept whole, and says so', () {
      // A read-only file: the temp file is written beside it, and the
      // rename over it is refused.
      mirror().writeAsStringSync(mirrored);
      config().writeAsStringSync(current);
      Process.runSync('attrib', ['+r', mirror().path]);
      addTearDown(() => Process.runSync('attrib', ['-r', mirror().path]));

      final line = StorageService().scrubStaleConfigMirror();

      expect(mirror().readAsStringSync(), mirrored);
      expect(line, contains('still holds its tokens'));
      expect(line, contains('cannot be rewritten'));
      expect(leftovers(), isEmpty, reason: 'the temp file is cleaned up');
    }, skip: !Platform.isWindows);

    test('in a folder this process cannot write, it is left to the next update', () {
      // Program Files, where only the updater's elevated step can change
      // the file. A deny ACE on adding files to the folder is the same
      // refusal without needing one.
      mirror().writeAsStringSync(mirrored);
      config().writeAsStringSync(current);
      final sid = (Process.runSync('whoami', ['/user', '/fo', 'csv', '/nh']).stdout as String)
          .trim()
          .split(',')
          .last
          .replaceAll('"', '');
      expect(sid, startsWith('S-1-'));
      final denied = Process.runSync('icacls', [exeDir.path, '/deny', '*$sid:(WD,AD)']);
      expect(denied.exitCode, 0, reason: '${denied.stdout}${denied.stderr}');
      addTearDown(() => Process.runSync('icacls', [exeDir.path, '/remove:d', '*$sid']));

      final line = StorageService().scrubStaleConfigMirror();

      expect(mirror().readAsStringSync(), mirrored);
      expect(line, contains('cannot write that folder'));
      expect(line, contains('next update'));
      expect(leftovers(), isEmpty);
    }, skip: !Platform.isWindows);

    test('startup scrubs it only after the config loaded', () {
      // Not for a recovery from it: a quarantined config leaves nothing in
      // AppData to find the mirror stale against ('with no config in AppData
      // yet the mirror is kept for the migration'), and the first save
      // writes the session's state over what the migration copies in. A
      // config that is there but empty or unreadable is still the config,
      // and removed by hand, the migration takes the mirror whole, tokens
      // included.
      final src = File('lib/app_startup.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final start = src.indexOf('Future<void> startApp(');
      expect(start, isNonNegative);
      final body = src.substring(start, src.indexOf('\n}\n', start));
      final call = body.indexOf('storage.scrubStaleConfigMirror()');
      expect(call, isNonNegative, reason: 'startup no longer scrubs the mirror');
      final guard = body.lastIndexOf('if (startup.data != null)', call);
      expect(guard, isNonNegative);
      expect(body.indexOf('}', guard), greaterThan(call),
          reason: 'the scrub must sit inside the loaded-config guard');
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

    test("and only that child deletes it: a folder the user can write is the scrub's", () {
      // Where the user can write, the file may be a portable copy's real
      // config that lost its portable.txt, and the app keeps everything in
      // it but the tokens. The updater deleting it there was the data loss.
      final cpp = File('windows/runner/win32_updater/main.cpp')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final start = cpp.indexOf('int APIENTRY wWinMain(');
      final main = cpp.substring(start, cpp.indexOf('\n}\n', start));
      expect('DropConfigMirror('.allMatches(main), hasLength(1),
          reason: 'the elevated child is the one caller');
      final writable = main.indexOf('if (IsDirWritable(targetDir, &accessDenied)) {');
      expect(writable, isNonNegative);
      final branch =
          main.substring(writable, main.indexOf('} else if (accessDenied) {', writable));
      expect(branch, isNot(contains('DropConfigMirror(')));
      expect(branch, contains('Config mirror: left to the app'));
    });
  });
}
