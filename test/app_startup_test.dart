import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/app_startup.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/crash_log.dart';

/// What prepareWindow says to the runner, and in which order, before the
/// first frame: the runner's channel and window_manager's, both recorded.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const runner = MethodChannel('streamlink_gui/window');
  const windowManager = MethodChannel('window_manager');

  late List<String> calls;
  late Directory dir;
  late CrashLog log;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(windowManager, (call) async {
      calls.add('window_manager.${call.method}');
      switch (call.method) {
        case 'getId':
          return 1;
        case 'isFullScreen':
        case 'isMaximized':
        case 'isMinimized':
          return false;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(runner, (call) async {
      calls.add('runner.${call.method}');
      return call.method == 'getMonitors' ? <Object?>[] : null;
    });
    dir = Directory.systemTemp.createTempSync('app_startup_test');
    log = CrashLog(File(p.join(dir.path, 'crash.log')));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(windowManager, null);
    messenger.setMockMethodCallHandler(runner, null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a launch kept hidden by the setting tells the runner before the window '
      'is touched', () async {
    // The runner holds the foreground for a hidden start from when it knows
    // about it. For the Start minimized setting that used to be the initial
    // placement, after window_manager's title bar setup had activated the
    // hidden frame - which took the foreground from the user's own app.
    await prepareWindow(AppSettings(startMinimized: true),
        startHidden: true, milestone: (_) {}, log: log);

    expect(calls.first, 'runner.startHidden');
    expect(calls, contains('window_manager.setTitleBarStyle'),
        reason: 'the call that activates the hidden frame still runs, after');
    expect(calls.where((call) => call == 'runner.startHidden'), hasLength(1));
  });

  test('a launch that shows its window does not', () async {
    await prepareWindow(AppSettings(),
        startHidden: false, milestone: (_) {}, log: log);

    expect(calls, isNot(contains('runner.startHidden')));
    expect(calls, contains('runner.setInitialPlacement'));
  });

  test('a runner without the call still gets the window set up', () async {
    messenger.setMockMethodCallHandler(runner, (call) async {
      calls.add('runner.${call.method}');
      if (call.method == 'startHidden') {
        throw PlatformException(code: 'unavailable');
      }
      return call.method == 'getMonitors' ? <Object?>[] : null;
    });
    // The log echoes to the console in debug builds; the file is what counts.
    final echo = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {};
    addTearDown(() => debugPrint = echo);

    await prepareWindow(AppSettings(startMinimized: true),
        startHidden: true, milestone: (_) {}, log: log);

    expect(calls, contains('window_manager.setTitleBarStyle'));
    expect(calls, contains('runner.setInitialPlacement'));
    expect(log.file.readAsStringSync(), contains('ERROR [window start]'));
  });
}
