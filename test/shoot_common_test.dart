import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';

/// tools/shoot-common.ps1, the screenshot harness's shared half, run for
/// real through Windows PowerShell against scratch folders.
///
/// Only on Windows: the scripts drive Win32 and are only ever run there.
void main() {
  final common = p.absolute('tools', 'shoot-common.ps1');
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('streamlink_gui_shoot_test_');
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Dot-sources the helpers, runs [script], and returns what it printed.
  /// [appData] stands in for %APPDATA%, so no test reads the real config.
  Future<String> ps(String script, {required String appData}) async {
    final result = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "\$ErrorActionPreference = 'Stop'; . '$common'; $script",
      ],
      environment: {'APPDATA': appData},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    return (result.stdout as String).trim();
  }

  Map<String, dynamic> settingsIn(File config) =>
      (json.decode(config.readAsStringSync().replaceFirst('﻿', ''))
          as Map<String, dynamic>)['settings'] as Map<String, dynamic>;

  group('Set-IsolatedConfig', () {
    late Directory appData;
    late Directory build;
    late File exe;

    setUp(() {
      appData = Directory(p.join(root.path, 'appdata', 'TwitchStreamlinkGUI'))
        ..createSync(recursive: true);
      build = Directory(p.join(root.path, 'Release'))..createSync();
      exe = File(p.join(build.path, 'streamlink_gui.exe'))..writeAsStringSync('');
    });

    File staged() => File(p.join(build.path, 'channels_config.json'));

    Map<String, Object?> realConfig() => {
          'channels': [
            {'username': 'some_streamer'}
          ],
          'settings': {
            for (final key in AppSettings.secretJsonKeys) key: 'dpapi:sealed-$key',
            'material': 'rack',
            'twitch_client_id': 'kept',
          },
        };

    test("blanks every token in the copy of the user's config", () async {
      final real = File(p.join(appData.path, 'channels_config.json'))
        ..writeAsStringSync(json.encode(realConfig()));
      final before = real.readAsStringSync();

      await ps("Set-IsolatedConfig '${exe.path}' @{ is_dark_theme = \$true }",
          appData: p.dirname(appData.path));

      final settings = settingsIn(staged());
      for (final key in AppSettings.secretJsonKeys) {
        expect(settings[key], '', reason: '$key must not reach the staged copy');
      }
      expect(staged().readAsStringSync(), isNot(contains('dpapi:sealed')));
      expect(settings['material'], 'rack', reason: 'the rest is a real copy');
      expect(settings['twitch_client_id'], 'kept');
      expect(settings['is_dark_theme'], true);
      expect(File(p.join(build.path, 'portable.txt')).existsSync(), isTrue);
      expect(real.readAsStringSync(), before, reason: 'the real config is only read');
    }, skip: !Platform.isWindows);

    test('blanks a staged config left from before, too', () async {
      staged().writeAsStringSync(json.encode(realConfig()));

      await ps("Set-IsolatedConfig '${exe.path}' @{}",
          appData: p.dirname(appData.path));

      final settings = settingsIn(staged());
      for (final key in AppSettings.secretJsonKeys) {
        expect(settings[key], '');
      }
    }, skip: !Platform.isWindows);
  });

  test("reads the token keys from AppSettings' own list", () async {
    final out = await ps("(Get-SecretSettingKeys) -join ','",
        appData: root.path);
    expect(out.split(','), AppSettings.secretJsonKeys);
  }, skip: !Platform.isWindows);
}
