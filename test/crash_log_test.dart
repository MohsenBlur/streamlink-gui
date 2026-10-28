import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/services/crash_log.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crash_log_test_');
    file = File(p.join(dir.path, CrashLog.fileName));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  CrashLog log({int maxBytes = 256 * 1024}) => CrashLog(file,
      maxBytes: maxBytes, clock: () => DateTime(2026, 10, 28, 16, 0, 0));

  test('a milestone is one timestamped line', () {
    log().milestone('[startup +12ms] config: loaded');
    expect(file.readAsStringSync(),
        '2026-10-28T16:00:00.000 [startup +12ms] config: loaded\n');
  });

  test('an error carries its source and an indented, capped stack', () {
    final stack = StackTrace.fromString(
        List.generate(100, (i) => '#$i frame$i').join('\n'));
    log().error('zone', StateError('boom'), stack);
    final text = file.readAsStringSync();
    expect(text, contains('ERROR [zone] Bad state: boom'));
    expect(text, contains('\n    #0 frame0'));
    expect(text, contains('#39 frame39'));
    expect(text, isNot(contains('#40 frame40')),
        reason: 'a deep stack must not flood a file meant to stay small');
  });

  test('credentials in an error message are masked', () {
    // An exception can quote the request it failed on, header included.
    log().error('platform',
        Exception('GET failed with Authorization: OAuth abcdefghijklmnopqrstuvwxyz0123'),
        null);
    final text = file.readAsStringSync();
    expect(text, isNot(contains('abcdefghijklmnopqrstuvwxyz0123')));
    expect(text, contains('<redacted>'));
  });

  group('rotation', () {
    test('past the limit the file moves to .1 and starts over', () {
      final l = log(maxBytes: 200);
      for (var i = 0; i < 10; i++) {
        l.milestone('line $i ${'x' * 40}');
      }
      expect(l.previous.existsSync(), isTrue);
      expect(file.lengthSync(), lessThanOrEqualTo(200));
      expect(file.readAsStringSync(), contains('line 9'));
    });

    test('keeps one previous copy, never a growing pile', () {
      final l = log(maxBytes: 120);
      for (var i = 0; i < 40; i++) {
        l.milestone('line $i ${'x' * 40}');
      }
      final logs = dir.listSync().map((e) => p.basename(e.path)).toList()
        ..sort();
      expect(logs, ['crash.log', 'crash.log.1']);
      expect(file.lengthSync() + l.previous.lengthSync(),
          lessThanOrEqualTo(2 * 120));
    });

    test('a file left by an earlier launch counts toward the limit', () {
      file.writeAsStringSync('${'y' * 190}\n');
      log(maxBytes: 200).milestone('launch ${'x' * 20}');
      expect(File('${file.path}.1').readAsStringSync(), startsWith('yyy'));
      expect(file.readAsStringSync(), contains('launch'));
    });
  });

  test('timed milestones say how long each step of an operation took', () async {
    // The exit logged its first and last line only, so a 6.9s exit could not
    // say whether the players, the saves or the tray held it up.
    final steps = TimedMilestones('exit', log());
    steps.mark('players stopped');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    steps.mark('saved');

    final lines = file.readAsLinesSync();
    final pattern = RegExp(r'\[exit\] (.+) \(\+(\d+)ms\)$');
    final matches = [for (final l in lines) pattern.firstMatch(l)!];
    expect([for (final m in matches) m.group(1)], ['players stopped', 'saved']);
    final first = int.parse(matches[0].group(2)!);
    final second = int.parse(matches[1].group(2)!);
    expect(second - first, greaterThanOrEqualTo(20));

    expect(() => TimedMilestones('exit', null).mark('nowhere'), returnsNormally);
  });

  test('an unwritable location is swallowed, never thrown', () {
    // A file where the folder should be: creating it fails.
    final blocker = File(p.join(dir.path, 'blocked'))..writeAsStringSync('');
    final l = CrashLog(File(p.join(blocker.path, CrashLog.fileName)));
    expect(() => l.milestone('nowhere to go'), returnsNormally);
    expect(() => l.error('zone', StateError('x'), null), returnsNormally);
  });

  test('install routes framework and platform errors into the log', () {
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    final previousCurrent = CrashLog.current;
    final chained = <FlutterErrorDetails>[];
    FlutterError.onError = chained.add;
    try {
      final l = log();
      CrashLog.install(l);
      expect(CrashLog.current, same(l));

      FlutterError.onError!(FlutterErrorDetails(
          exception: StateError('layout went wrong'), library: 'rendering'));
      // The framework's own reporting still runs.
      expect(chained, hasLength(1));

      final handled = PlatformDispatcher.instance.onError!(
          StateError('callback threw'), StackTrace.empty);
      expect(handled, isTrue);

      final text = file.readAsStringSync();
      expect(text, contains('ERROR [rendering] Bad state: layout went wrong'));
      expect(text, contains('ERROR [platform] Bad state: callback threw'));
    } finally {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
      CrashLog.current = previousCurrent;
    }
  });
}
