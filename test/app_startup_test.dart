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
  late List<Object?> placements;
  late List<String> milestones;
  late Directory dir;
  late CrashLog log;

  /// The runner's side: what it answers to startsHidden, given what Dart
  /// said; it throws instead when [answer] does.
  void runnerAnswers(bool? Function(bool hidden) answer) {
    messenger.setMockMethodCallHandler(runner, (call) async {
      calls.add('runner.${call.method}');
      switch (call.method) {
        case 'startsHidden':
          return answer((call.arguments as Map)['hidden'] as bool);
        case 'getMonitors':
          return <Object?>[];
        case 'setInitialPlacement':
          placements.add((call.arguments as Map)['hidden']);
      }
      return null;
    });
  }

  Future<bool> prepare({required bool startHidden}) => prepareWindow(
      AppSettings(startMinimized: startHidden),
      startHidden: startHidden,
      milestone: milestones.add,
      log: log);

  setUp(() {
    calls = [];
    placements = [];
    milestones = [];
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
    // A runner that keeps the launch hidden exactly when Dart says so.
    runnerAnswers((hidden) => hidden);
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
    expect(await prepare(startHidden: true), isTrue);

    expect(calls.first, 'runner.startsHidden');
    expect(calls, contains('window_manager.setTitleBarStyle'),
        reason: 'the call that activates the hidden frame still runs, after');
    expect(calls.where((call) => call == 'runner.startsHidden'), hasLength(1));
    expect(placements, [true]);
  });

  test('a launch that shows its window says so, first, too', () async {
    expect(await prepare(startHidden: false), isFalse);

    expect(calls.first, 'runner.startsHidden');
    expect(placements, [false]);
  });

  test("the runner's answer wins: a launcher's SW_HIDE keeps it hidden",
      () async {
    // Only the runner sees STARTUPINFO. Windows kept just the first show
    // hidden, and the check after the first frame - told the window should
    // be up - showed it and took the foreground.
    runnerAnswers((_) => true);

    expect(await prepare(startHidden: false), isTrue,
        reason: 'what startApp hands the shell and the first-frame check');
    expect(placements, [true]);
    expect(milestones,
        contains('starting hidden: the launcher asked for no window'));
  });

  test('a runner that cannot answer still gets the window set up', () async {
    runnerAnswers((_) => throw PlatformException(code: 'unavailable'));
    // The log echoes to the console in debug builds; the file is what counts.
    final echo = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {};
    addTearDown(() => debugPrint = echo);

    expect(await prepare(startHidden: true), isTrue,
        reason: "the app's own reason still stands");

    expect(calls, contains('window_manager.setTitleBarStyle'));
    expect(placements, [true]);
    expect(log.file.readAsStringSync(), contains('ERROR [window start]'));
  });

  test("startApp goes by prepareWindow's answer", () {
    // startApp itself needs the whole app around it; this is its wiring.
    final source = File('lib/app_startup.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final start = source.indexOf('Future<void> startApp(');
    expect(start, isNonNegative);
    final body = source.substring(start, source.indexOf('\n}\n', start));
    expect(body, contains('final startHidden = await prepareWindow('));
    expect(body, contains('runApp(app(startup, startHidden));'));
    expect(body, contains('startHidden: startHidden, milestone: milestone'));
  });
}
