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
          'settings': <String, Object?>{
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

    test('turns launch at startup off, even when asked for it', () async {
      // A staged build started with it on rewrites the user's HKCU Run value
      // to its own exe (StartupService().sync(true) at every launch).
      final config = realConfig();
      (config['settings'] as Map<String, Object?>)['launch_at_startup'] = true;
      File(p.join(appData.path, 'channels_config.json'))
          .writeAsStringSync(json.encode(config));

      await ps("Set-IsolatedConfig '${exe.path}' @{ launch_at_startup = \$true }",
          appData: p.dirname(appData.path));

      expect(settingsIn(staged())['launch_at_startup'], false);

      // A staged copy from before is put right too, with no settings at all.
      final old = json.decode(staged().readAsStringSync().replaceFirst('﻿', ''))
          as Map<String, dynamic>;
      (old['settings'] as Map<String, dynamic>)['launch_at_startup'] = true;
      staged().writeAsStringSync(json.encode(old));
      await ps("Set-IsolatedConfig '${exe.path}' @{}", appData: p.dirname(appData.path));
      expect(settingsIn(staged())['launch_at_startup'], false);
    }, skip: !Platform.isWindows);

    test('-NoActivate stages a window that is not maximized', () async {
      // A maximized first show is one SW_SHOWNOACTIVATE most likely does not
      // replace, so a launch meant to stay in the background would not.
      final config = realConfig();
      (config['settings'] as Map<String, Object?>)['is_window_maximized'] = true;
      File(p.join(appData.path, 'channels_config.json'))
          .writeAsStringSync(json.encode(config));

      await ps("Set-IsolatedConfig '${exe.path}' @{}", appData: p.dirname(appData.path));
      expect(settingsIn(staged())['is_window_maximized'], true,
          reason: 'without -NoActivate the copy keeps what the user had');
      expect(await ps("Test-StagedOpensMaximized '${exe.path}'", appData: root.path), 'True');

      await ps("Set-IsolatedConfig '${exe.path}' @{ is_window_maximized = \$true } -NoActivate",
          appData: p.dirname(appData.path));
      expect(settingsIn(staged())['is_window_maximized'], false);
      expect(await ps("Test-StagedOpensMaximized '${exe.path}'", appData: root.path), 'False');
    }, skip: !Platform.isWindows);
  });

  group('Test-StagedOpensMaximized', () {
    late Directory build;
    late String exe;

    setUp(() {
      build = Directory(p.join(root.path, 'Release'))..createSync();
      exe = p.join(build.path, 'streamlink_gui.exe');
    });

    Future<String> opensMaximized() =>
        ps("Test-StagedOpensMaximized '$exe'", appData: root.path);

    void stage(Object config) => File(p.join(build.path, 'channels_config.json'))
        .writeAsStringSync(config is String ? config : json.encode(config));

    test('reads only the config a portable build reads', () async {
      stage({
        'settings': {'is_window_maximized': true}
      });
      expect(await opensMaximized(), 'False',
          reason: 'no portable.txt: the build reads %APPDATA%, not this file');
      File(p.join(build.path, 'portable.txt')).writeAsStringSync('');
      expect(await opensMaximized(), 'True');
    }, skip: !Platform.isWindows);

    test('says no for a window that is not maximized, or a config it cannot read', () async {
      File(p.join(build.path, 'portable.txt')).writeAsStringSync('');
      expect(await opensMaximized(), 'False', reason: 'no config');
      stage({
        'settings': {'is_window_maximized': false}
      });
      expect(await opensMaximized(), 'False');
      stage('{"settings": {"is_window_maximized": tr');
      expect(await opensMaximized(), 'False');
    }, skip: !Platform.isWindows);
  });

  group('Find-PlacementOverhang', () {
    // This desk: a 150% portrait monitor left of a 100% primary.
    const monitors = r"""
      $m = @(
        [pscustomobject]@{ Left = -2160; Top = -813; Right = 0; Bottom = 3027; Dpi = 144 },
        [pscustomobject]@{ Left = 0; Top = 0; Right = 3440; Bottom = 1440; Dpi = 96 }
      )""";

    Future<String> overhang(String args) => ps(
        "$monitors; \$r = Find-PlacementOverhang $args \$m; if (\$r) { \$r } else { 'fits' }",
        appData: root.path);

    test('a window that ends at the monitor edge fits', () async {
      // shoot-matrix's own example: 1600 logical is 2400 physical at 150%,
      // so from 240px past the desktop's left edge it ends exactly at 0.
      expect(await overhang('-2400 -813 1600 1000'), 'fits');
    }, skip: !Platform.isWindows);

    test('a window reaching onto the primary is named, at its real size', () async {
      final why = await overhang('-1900 -813 1600 1000');
      expect(why, contains('2400x1500 physical at 144 dpi'));
      expect(why, contains('covers 2 monitors'));
    }, skip: !Platform.isWindows);

    test('a physical size is not scaled again', () async {
      // The staged config's placeholder: 1280 physical from -1900 ends at
      // -620, though 1280 logical would reach 20px onto the primary.
      expect(await overhang('-1900 -813 1280 720 -physical'), 'fits');
      expect(await overhang('-1900 -813 1280 720'), contains('covers 2 monitors'));
    }, skip: !Platform.isWindows);

    test('measured at the DPI of the monitor it lands on', () async {
      // 700 logical is 1050 physical on the 150% monitor: from 1000px left
      // of the primary it reaches 50px onto it, which 700 would not.
      expect(await overhang('-1000 0 700 500'),
          contains('1050x750 physical at 144 dpi'));
      // Past the desktop's outer edge is onto no monitor, and fine.
      expect(await overhang('3000 100 1400 1000'), 'fits');
    }, skip: !Platform.isWindows);
  });

  test("reads the token keys from AppSettings' own list", () async {
    final out = await ps("(Get-SecretSettingKeys) -join ','",
        appData: root.path);
    expect(out.split(','), AppSettings.secretJsonKeys);
  }, skip: !Platform.isWindows);
}
