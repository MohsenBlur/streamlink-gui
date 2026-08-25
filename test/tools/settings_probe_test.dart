import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';

void main() {
  test('probe', () {
    final p = '${Platform.environment['APPDATA']}/TwitchStreamlinkGUI/channels_config.json';
    final raw = File(p).readAsStringSync();
    final d = jsonDecode(raw.startsWith('\uFEFF') ? raw.substring(1) : raw);
    // ignore: avoid_print
    print('settings is Map<String,dynamic>: ${d['settings'] is Map<String, dynamic>}');
    final s = AppSettings.fromJson(d['settings']);
    // ignore: avoid_print
    print('parsed isDarkTheme=${s.isDarkTheme} material=${s.material}');
  });
}
