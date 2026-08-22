import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/log_store.dart';
import 'package:streamlink_gui/state/log_line_kind.dart';

void main() {
  group('classifyLogLine', () {
    test('failure markers win, whoever emitted the line', () {
      // Precedence is deliberate: the reader is scanning for the failure, not
      // for which subsystem narrated it.
      expect(classifyLogLine('[System] Download failed with exit code 1'),
          LogLineKind.error);
      expect(classifyLogLine('[Error] boom'), LogLineKind.error);
      expect(classifyLogLine('[Streamlink Err] nope'), LogLineKind.error);
      expect(classifyLogLine('error: bad thing'), LogLineKind.error);
    });

    test('classifies the remaining sources', () {
      expect(classifyLogLine('[System] Initializing'), LogLineKind.system);
      expect(classifyLogLine('[Streamlink] opening'), LogLineKind.streamlink);
      expect(classifyLogLine('[cli][info] Found plugin'), LogLineKind.cliInfo);
      expect(
          classifyLogLine('Available streams: 1080p60'), LogLineKind.cliInfo);
      expect(classifyLogLine('[Download] 42%'), LogLineKind.download);
      expect(classifyLogLine('just some text'), LogLineKind.plain);
    });
  });

  group('LogNotifier buffering', () {
    test('keeps the tail when the buffer overflows', () {
      final logs = LogNotifier(maxLines: 3);
      for (var i = 1; i <= 5; i++) {
        logs.appendLog('k', 'line $i');
      }
      expect(logs.getLogs('k'), ['line 3', 'line 4', 'line 5']);
    });

    test('unknown key reads as empty, not null', () {
      expect(LogNotifier().getLogs('nope'), isEmpty);
    });

    test('clear empties the buffer but keeps the session', () {
      final logs = LogNotifier()
        ..beginSession('k', 'Label')
        ..appendLog('k', 'a');
      logs.clear('k');
      expect(logs.getLogs('k'), isEmpty);
      expect(logs.session('k'), isNotNull);
    });
  });

  group('LogNotifier sessions', () {
    test('labels survive the session ending', () {
      final logs = LogNotifier()..beginSession('dl-1', 'Download: Thing');
      logs.endSession('dl-1', 0);
      expect(logs.session('dl-1')!.label, 'Download: Thing');
      expect(logs.session('dl-1')!.isRunning, isFalse);
      expect(logs.session('dl-1')!.failed, isFalse);
    });

    test('a non-zero exit marks the session failed', () {
      final logs = LogNotifier()..beginSession('k', 'x');
      logs.endSession('k', 1);
      expect(logs.session('k')!.failed, isTrue);
    });

    test('restarting a key starts a clean session', () {
      final logs = LogNotifier()..beginSession('k', 'first');
      logs.appendLog('k', 'old line');
      logs.beginSession('k', 'second');
      expect(logs.getLogs('k'), isEmpty);
      expect(logs.session('k')!.label, 'second');
    });

    test('sessions come back newest first', () async {
      final logs = LogNotifier()..beginSession('a', 'A');
      await Future.delayed(const Duration(milliseconds: 2));
      logs.beginSession('b', 'B');
      expect(logs.sessions.map((s) => s.key), ['b', 'a']);
    });

    test('evicts oldest finished sessions past the cap', () async {
      final logs = LogNotifier(maxSessions: 2);
      logs.beginSession('a', 'A');
      logs.endSession('a', 0);
      await Future.delayed(const Duration(milliseconds: 2));
      logs.beginSession('b', 'B');
      logs.endSession('b', 0);
      await Future.delayed(const Duration(milliseconds: 2));
      logs.beginSession('c', 'C');

      expect(logs.sessions.map((s) => s.key), ['c', 'b']);
      expect(logs.getLogs('a'), isEmpty);
    });

    test('never evicts a running session, however old', () async {
      final logs = LogNotifier(maxSessions: 1);
      logs.beginSession('old-running', 'still going'); // never ended
      await Future.delayed(const Duration(milliseconds: 2));
      logs.beginSession('new', 'newer');

      // Over cap, but the only candidate is still running, so it stays.
      expect(logs.sessions.map((s) => s.key).toSet(),
          {'old-running', 'new'});
    });

    test('removeKey and clearAll drop both buffer and session', () {
      final logs = LogNotifier()..beginSession('k', 'x');
      logs.appendLog('k', 'a');
      logs.removeKey('k');
      expect(logs.session('k'), isNull);
      expect(logs.getLogs('k'), isEmpty);

      logs.beginSession('z', 'z');
      logs.clearAll();
      expect(logs.isEmpty, isTrue);
    });

    test('a session that ends becomes evictable', () {
      // Downloads announced their start but never their end, so their sessions
      // read "running" forever - and because eviction skips running sessions,
      // the store could never reclaim them and grew for as long as the app ran.
      final logs = LogNotifier(maxSessions: 2);
      logs.beginSession('a', 'a');
      logs.beginSession('b', 'b');
      logs.endSession('a', 0);

      logs.beginSession('c', 'c');

      expect(logs.sessions.map((s) => s.key).toSet(), {'b', 'c'});
    });

    test('ending a session evicts immediately, without waiting for the next start', () {
      final logs = LogNotifier(maxSessions: 1);
      logs.beginSession('a', 'a');
      logs.beginSession('b', 'b'); // over cap, but both are running
      expect(logs.sessions, hasLength(2));

      logs.endSession('a', 0);

      expect(logs.sessions.map((s) => s.key), ['b']);
    });

    test('ending an unknown or already-ended session is a no-op', () {
      final logs = LogNotifier();
      logs.endSession('nope', 1); // must not create anything
      expect(logs.session('nope'), isNull);

      logs.beginSession('a', 'a');
      logs.endSession('a', 0);
      logs.endSession('a', 1); // a late second report cannot rewrite history
      expect(logs.session('a')!.exitCode, 0);
    });

    test('endAllRunning closes the sessions a mass kill left behind', () {
      // A failed update kills every child process but the app survives, so
      // nothing else would ever end these.
      final logs = LogNotifier();
      logs.beginSession('a', 'a');
      logs.beginSession('b', 'b');
      logs.endSession('a', 0);

      logs.endAllRunning(-1);

      expect(logs.session('a')!.exitCode, 0); // untouched
      expect(logs.session('b')!.exitCode, -1);
      expect(logs.sessions.every((s) => !s.isRunning), isTrue);
    });
  });
}
