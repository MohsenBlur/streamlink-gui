import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/player_progress.dart';
import 'package:streamlink_gui/utils/vod_playback_monitor.dart';

void main() {
  group('ProgressConfirmationGate', () {
    test('a lone sample never commits', () {
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      expect(gate.feed(positionSeconds: 100, nowMs: 0), isNull);
      expect(gate.lastCommitted, isNull);
    });

    test('smooth continuation commits from the second sample on', () {
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      expect(gate.feed(positionSeconds: 100, nowMs: 0), isNull);
      expect(gate.feed(positionSeconds: 102, nowMs: 2000), 102);
      expect(gate.feed(positionSeconds: 104, nowMs: 4000), 104);
      expect(gate.lastCommitted, 104);
    });

    test('the dying gasp: a final 0 before process death never commits', () {
      // The reported bug in miniature. The player stalls at 3600s, reports a
      // 0 while tearing down, and dies. The old tracker persisted the 0 and
      // the resume mark was gone.
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      gate.feed(positionSeconds: 3598, nowMs: 0);
      gate.feed(positionSeconds: 3600, nowMs: 2000);
      expect(gate.lastCommitted, 3600);
      expect(gate.feed(positionSeconds: 0, nowMs: 4000), isNull);
      // <process death - no further samples>
      expect(gate.lastCommitted, 3600);
    });

    test('a near-end spike before death never commits', () {
      // The other corruption direction: a bogus near-end value would cross
      // the watched threshold and mark the VOD finished.
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      gate.feed(positionSeconds: 3598, nowMs: 0);
      gate.feed(positionSeconds: 3600, nowMs: 2000);
      expect(gate.feed(positionSeconds: 7150, nowMs: 4000), isNull);
      expect(gate.lastCommitted, 3600);
    });

    test('a real seek commits on its second, corroborating sample', () {
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      gate.feed(positionSeconds: 100, nowMs: 0);
      gate.feed(positionSeconds: 102, nowMs: 2000);
      // User seeks to 5000. First read there is a discontinuity - held.
      expect(gate.feed(positionSeconds: 5000, nowMs: 4000), isNull);
      // Next read continues from 5000 - the seek was real.
      expect(gate.feed(positionSeconds: 5002, nowMs: 6000), 5002);
    });

    test('a backward seek commits the same way', () {
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      gate.feed(positionSeconds: 5000, nowMs: 0);
      gate.feed(positionSeconds: 5002, nowMs: 2000);
      expect(gate.feed(positionSeconds: 40, nowMs: 4000), isNull);
      expect(gate.feed(positionSeconds: 42, nowMs: 6000), 42);
    });

    test('resume after a long pause is continuation, not a discontinuity', () {
      // The gate is not fed while paused (parsers report paused, the monitor
      // does not feed those ticks), so on resume the wall clock has run far
      // ahead of the position. The acceptance band spans [prev - tol,
      // prev + elapsed + tol], so a frozen position resuming is inside it.
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      gate.feed(positionSeconds: 1000, nowMs: 0);
      gate.feed(positionSeconds: 1002, nowMs: 2000);
      // 10 minutes pass paused; playback resumes at 1003.
      expect(gate.feed(positionSeconds: 1003, nowMs: 602000), 1003);
    });

    test('a position past the end of the VOD is rejected outright', () {
      final gate = ProgressConfirmationGate(durationSeconds: 7200);
      gate.feed(positionSeconds: 7300, nowMs: 0);
      // Not even a candidate: a second impossible reading must not
      // corroborate the first.
      expect(gate.feed(positionSeconds: 7302, nowMs: 2000), isNull);
      expect(gate.lastCommitted, isNull);
    });

    test('unknown duration skips the past-the-end rejection', () {
      final gate = ProgressConfirmationGate(durationSeconds: 0);
      gate.feed(positionSeconds: 7300, nowMs: 0);
      expect(gate.feed(positionSeconds: 7302, nowMs: 2000), 7302);
    });
  });

  group('VodPlaybackMonitor', () {
    PlayerStatus playing(int pos) =>
        PlayerStatus(activity: PlayerActivity.playing, positionSeconds: pos);
    PlayerStatus paused(int pos) =>
        PlayerStatus(activity: PlayerActivity.paused, positionSeconds: pos);
    PlayerStatus stopped(int pos) =>
        PlayerStatus(activity: PlayerActivity.stopped, positionSeconds: pos);
    PlayerStatus eof(int pos) => PlayerStatus(
      activity: PlayerActivity.stopped,
      positionSeconds: pos,
      eofReached: true,
    );

    /// Feeds [statuses] at a 2s cadence and returns every event in order.
    List<MonitorEvent> run(
      VodPlaybackMonitor m,
      List<PlayerStatus?> statuses, {
      int startMs = 0,
    }) {
      final events = <MonitorEvent>[];
      var t = startMs;
      for (final s in statuses) {
        events.addAll(m.onSample(status: s, nowMs: t).events);
        t += 2000;
      }
      return events;
    }

    test('startup grace: stopped-before-playback yields no verdict', () {
      // VLC's HTTP interface is up before playback begins and reports
      // "stopped". With a resume at 40 minutes, a naive machine would fire
      // "premature EOF at 40 minutes" instantly and kill/relaunch-loop.
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [stopped(0), stopped(0), stopped(0), stopped(0)]);
      expect(events, contains(MonitorEvent.firstContact));
      expect(events, contains(MonitorEvent.eofObserved));
      expect(events, isNot(contains(MonitorEvent.prematureEof)));
      expect(events, isNot(contains(MonitorEvent.genuineEof)));
    });

    test('a one-tick stopped blip is debounced away', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [
        playing(100), playing(102),
        stopped(102), // blip
        playing(104), playing(106),
      ]);
      expect(events, contains(MonitorEvent.eofObserved));
      expect(events, isNot(contains(MonitorEvent.prematureEof)));
    });

    test('the reported bug end-to-end: premature verdict mid-VOD', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [
        playing(3598), playing(3600),
        paused(3600), paused(3600), // the long pause (abbreviated)
        playing(3601), // brief resume
        eof(3601), eof(3601), // the false end-of-file, debounced
      ]);
      expect(events, contains(MonitorEvent.prematureEof));
      expect(events, isNot(contains(MonitorEvent.genuineEof)));
      expect(m.lastConfirmedPosition, 3601);
    });

    test('genuine EOF at >= 95% of the duration', () {
      final m = VodPlaybackMonitor(durationSeconds: 1000);
      final events = run(m, [playing(996), playing(998), eof(999), eof(999)]);
      expect(events, contains(MonitorEvent.genuineEof));
      expect(events, isNot(contains(MonitorEvent.prematureEof)));
    });

    test('EOF below the premature floor is observed, never acted on', () {
      // A stream dying in its first seconds: restarting would loop.
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [playing(4), playing(6), eof(6), eof(6), eof(6)]);
      expect(events, contains(MonitorEvent.eofObserved));
      expect(events, isNot(contains(MonitorEvent.prematureEof)));
    });

    test('one verdict per monitor: premature does not repeat', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [
        playing(100),
        playing(102),
        eof(102),
        eof(102),
        eof(102),
        eof(102),
        eof(102),
      ]);
      expect(events.where((e) => e == MonitorEvent.prematureEof), hasLength(1));
    });

    test('stall fires once after five frozen playing ticks, recovers once', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [
        playing(100), playing(102),
        playing(102), playing(102), playing(102), playing(102), playing(102),
        playing(102), // frozen beyond the threshold - still one event
        playing(104),
      ]);
      expect(events.where((e) => e == MonitorEvent.stalled), hasLength(1));
      expect(
        events.where((e) => e == MonitorEvent.stallRecovered),
        hasLength(1),
      );
    });

    test('paused ticks do not accumulate stall', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [
        playing(100),
        playing(102),
        paused(102),
        paused(102),
        paused(102),
        paused(102),
        paused(102),
        paused(102),
        paused(102),
      ]);
      expect(events, isNot(contains(MonitorEvent.stalled)));
      expect(events, contains(MonitorEvent.paused));
    });

    test('pause and resume are single transitions', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [
        playing(100),
        playing(102),
        paused(102),
        paused(102),
        paused(102),
        playing(103),
        playing(105),
      ]);
      expect(events.where((e) => e == MonitorEvent.paused), hasLength(1));
      expect(events.where((e) => e == MonitorEvent.resumed), hasLength(1));
    });

    test('poll failures carry no facts and no verdicts', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [
        playing(100),
        playing(102),
        null,
        null,
        null,
        null,
        null,
        null,
      ]);
      expect(events, isNot(contains(MonitorEvent.eofObserved)));
      expect(events, isNot(contains(MonitorEvent.stalled)));
    });

    test('firstContact and firstConfirmedPosition fire exactly once', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final events = run(m, [playing(100), playing(102), playing(104)]);
      expect(events.where((e) => e == MonitorEvent.firstContact), hasLength(1));
      expect(
        events.where((e) => e == MonitorEvent.firstConfirmedPosition),
        hasLength(1),
      );
    });

    test('committed positions flow out; uncommitted do not', () {
      final m = VodPlaybackMonitor(durationSeconds: 7200);
      final r1 = m.onSample(status: playing(100), nowMs: 0);
      expect(r1.commitPositionSeconds, isNull);
      final r2 = m.onSample(status: playing(102), nowMs: 2000);
      expect(r2.commitPositionSeconds, 102);
    });
  });

  group('shouldAttemptRestart', () {
    test('allows two attempts, blocks the third', () {
      final ledger = RestartLedger();
      expect(
        shouldAttemptRestart(ledger: ledger, confirmedPosition: 1000),
        isTrue,
      );
      ledger.attempts = 1;
      ledger.baselinePosition = 1000;
      expect(
        shouldAttemptRestart(ledger: ledger, confirmedPosition: 1005),
        isTrue,
      );
      ledger.attempts = 2;
      expect(
        shouldAttemptRestart(ledger: ledger, confirmedPosition: 1010),
        isFalse,
      );
    });

    test('thirty seconds of real progress resets the count', () {
      // A four-hour VOD paused three times deserves three heals; a stream
      // dying twice at the same second is telling us relaunching is not
      // working.
      final ledger = RestartLedger();
      ledger.attempts = 2;
      ledger.baselinePosition = 1000;
      expect(
        shouldAttemptRestart(ledger: ledger, confirmedPosition: 1029),
        isFalse,
      );
      expect(
        shouldAttemptRestart(ledger: ledger, confirmedPosition: 1030),
        isTrue,
      );
      expect(ledger.attempts, 0);
    });
  });
}
