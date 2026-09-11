import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/watch_progress_store.dart';
import 'package:streamlink_gui/utils/player_seek.dart';
import 'package:streamlink_gui/utils/player_args.dart';

/// The rules that stop a bad playback session from destroying a watch position.
///
/// The incident these come from: a self-heal relaunched MPC-HC, which discards
/// the `/start` flag on a network stream, so playback resumed at the top of a
/// five-hour VOD. The fresh session then wrote its small positions straight over
/// the stored one — locally and to Twitch, where `max(local, remote)` cannot
/// undo it — turning a moment's annoyance into permanent loss.
void main() {
  const t0 = 1000000;

  group('the furthest point is never lost', () {
    test('a first sighting sets both position and best', () {
      final s = WatchProgressStore();
      final r = s.record('v', 500, nowMs: t0, sessionAgeMs: 120000);
      expect(r.accepted, isTrue);
      expect(s['v']!.position, 500);
      expect(s['v']!.best, 500);
    });

    test('best follows the position upward', () {
      final s = WatchProgressStore();
      s.record('v', 500, nowMs: t0, sessionAgeMs: 120000);
      s.record('v', 900, nowMs: t0 + 1000, sessionAgeMs: 130000);
      expect(s['v']!.best, 900);
    });

    test('a late backward seek moves the position but never best', () {
      // A deliberate rewatch, well past the grace window. It must record —
      // refusing it forever would be its own bug — but the furthest point
      // survives so the user can get back.
      final s = WatchProgressStore();
      s.record('v', 9292, nowMs: t0, sessionAgeMs: 600000);
      final r = s.record('v', 40, nowMs: t0 + 1000, sessionAgeMs: 600000);
      expect(r.accepted, isTrue);
      expect(s['v']!.position, 40);
      expect(s['v']!.best, 9292, reason: 'the furthest point is the safety net');
      expect(s['v']!.hasRecoverablePosition, isTrue);
    });
  });

  group('the grace window rejects a failed resume', () {
    test('a huge regression in the first seconds is refused outright', () {
      // Exactly the incident: a relaunch lands at the top of a 2h34m VOD and
      // starts reporting 0, 2, 4...
      final s = WatchProgressStore();
      s.record('v', 9292, nowMs: t0, sessionAgeMs: 600000);
      final r = s.record('v', 2, nowMs: t0 + 1000, sessionAgeMs: 3000);
      expect(r.accepted, isFalse);
      expect(r.outcome, ProgressWriteOutcome.rejectedSuspectRegression);
      expect(s['v']!.position, 9292, reason: 'the good position is untouched');
    });

    test('the same regression is accepted once the session has settled', () {
      final s = WatchProgressStore();
      s.record('v', 9292, nowMs: t0, sessionAgeMs: 600000);
      final r = s.record('v', 2,
          nowMs: t0 + 1000, sessionAgeMs: kSessionGraceSeconds * 1000 + 1);
      expect(r.accepted, isTrue,
          reason: 'a deliberate restart must not be blocked forever');
    });

    test('a small early regression still records', () {
      // Keyframe snap, buffering wobble, a nudge backwards - all normal.
      final s = WatchProgressStore();
      s.record('v', 9292, nowMs: t0, sessionAgeMs: 600000);
      final r = s.record('v', 9280, nowMs: t0 + 1000, sessionAgeMs: 2000);
      expect(r.accepted, isTrue);
      expect(s['v']!.position, 9280);
    });

    test('forward movement early in a session is never blocked', () {
      final s = WatchProgressStore();
      s.record('v', 9292, nowMs: t0, sessionAgeMs: 600000);
      final r = s.record('v', 9400, nowMs: t0 + 1000, sessionAgeMs: 1000);
      expect(r.accepted, isTrue);
      expect(s['v']!.best, 9400);
    });
  });

  group('recovery', () {
    test('restoreBest puts the position back and keeps a trail', () {
      final s = WatchProgressStore();
      s.record('v', 9292, nowMs: t0, sessionAgeMs: 600000);
      s.record('v', 40, nowMs: t0 + 1000, sessionAgeMs: 600000);
      expect(s.restoreBest('v', nowMs: t0 + 2000), isTrue);
      expect(s['v']!.position, 9292);
      expect(s['v']!.trail.first.seconds, 40,
          reason: 'the undone value stays recoverable');
    });

    test('restoreBest is a no-op when nothing is further along', () {
      final s = WatchProgressStore();
      s.record('v', 500, nowMs: t0, sessionAgeMs: 600000);
      expect(s.restoreBest('v', nowMs: t0 + 1000), isFalse);
    });

    test('the trail is bounded', () {
      final s = WatchProgressStore();
      for (var i = 1; i <= 12; i++) {
        s.record('v', i * 100, nowMs: t0 + i * 1000, sessionAgeMs: 600000);
      }
      expect(s['v']!.trail.length, lessThanOrEqualTo(kProgressTrailLength));
    });
  });

  group('migration from the shipped flat map', () {
    test('an int entry becomes a position that is its own best', () {
      // The live config holds dozens of these; dropping one would be the very
      // data loss this store exists to prevent.
      final s = WatchProgressStore.fromJson({'2870237439': 9292, '2869387736': 10469});
      expect(s['2870237439']!.position, 9292);
      expect(s['2870237439']!.best, 9292);
      expect(s['2869387736']!.position, 10469);
      expect(s.entries.length, 2);
    });

    test('a round trip through json preserves everything', () {
      final s = WatchProgressStore();
      s.record('v', 9292, nowMs: t0, sessionAgeMs: 600000);
      s.record('v', 40, nowMs: t0 + 1000, sessionAgeMs: 600000);
      final back = WatchProgressStore.fromJson(s.toJson());
      expect(back['v']!.position, 40);
      expect(back['v']!.best, 9292);
      expect(back['v']!.trail.first.seconds, 9292);
    });

    test('mixed and junk entries survive without taking the map down', () {
      final s = WatchProgressStore.fromJson({
        'a': 500,
        'b': {'p': 20, 'u': 1, 'b': 900, 'ba': 1},
        'c': 'nonsense',
      });
      expect(s['a']!.best, 500);
      expect(s['b']!.best, 900);
      expect(s['c'], isNull);
    });

    test('the flat view still serves callers that want id -> seconds', () {
      final s = WatchProgressStore.fromJson({'a': 500});
      expect(s.toFlatMap(), {'a': 500});
    });
  });

  group('landing verification', () {
    test('a launch with no intended position needs no checking', () {
      final l = LandingCheck(intendedSeconds: 0);
      expect(l.isSettled, isTrue);
      expect(l.mayWriteProgress, isTrue);
    });

    test('landing near the intent settles and writes are allowed', () {
      final l = LandingCheck(intendedSeconds: 9292);
      expect(l.mayWriteProgress, isFalse, reason: 'nothing writes until it lands');
      expect(l.evaluate(9290), isNull);
      expect(l.isSettled, isTrue);
      expect(l.mayWriteProgress, isTrue);
    });

    test('landing at the top asks for a correction', () {
      // MPC-HC discarding /start, measured.
      final l = LandingCheck(intendedSeconds: 9292);
      expect(l.evaluate(0), 9292);
      expect(l.mayWriteProgress, isFalse,
          reason: 'a session that has not landed must not persist anything');
    });

    test('it gives up rather than fighting the player forever', () {
      final l = LandingCheck(intendedSeconds: 9292);
      for (var i = 0; i < kMaxSeekCorrections; i++) {
        expect(l.evaluate(0), 9292);
      }
      expect(l.evaluate(0), isNull);
      expect(l.isSettled, isTrue);
      expect(l.mayWriteProgress, isTrue,
          reason: 'giving up must not freeze progress for the whole session');
    });

    test('overshooting on the FIRST reading is corrected down', () {
      // Observed live: the app showed 15% watched and MPC-HC opened at 72%,
      // because it restores its own remembered position for a URL it has seen.
      // The stored position is what the user saw and clicked.
      final l = LandingCheck(intendedSeconds: 600);
      expect(l.evaluate(9000), 600);
    });

    test('overshooting LATER is the user seeking, and is left alone', () {
      final l = LandingCheck(intendedSeconds: 600);
      l.evaluate(0); // the landing, corrected
      expect(l.evaluate(1200), isNull,
          reason: 'yanking a user back from their own seek would be worse');
      expect(l.isSettled, isTrue);
    });

    test('a keyframe snap short of the target still counts as landed', () {
      // A Twitch 1080p60 seek snapped ~27s back from its target; at the
      // tolerance this started with, a correct seek read as a miss.
      final l = LandingCheck(intendedSeconds: 9292);
      expect(l.evaluate(9265), isNull);
      expect(l.isSettled, isTrue);
    });

    test('a player with no control channel is abandoned, not stuck', () {
      expect(seekChannelFor(PlayerKind.other), SeekChannel.none);
      final l = LandingCheck(intendedSeconds: 600);
      l.abandon();
      expect(l.mayWriteProgress, isTrue);
    });
  });

  group('seek requests', () {
    test('MPC-HC is asked in absolute time, not percent', () {
      // percent is resolved against the duration the PLAYER loaded - under
      // passthrough the HLS manifest's, which need not match the Twitch
      // metadata this app holds. An absolute clock cannot drift with a
      // denominator we do not own.
      final path = seekRequestPath(SeekChannel.mpcHcWeb,
          targetSeconds: 9292, durationSeconds: 18876);
      expect(path, contains('wm_command=-1'));
      expect(path, contains('position=02:34:52'));
      expect(path, isNot(contains('percent')));
    });

    test('an absolute seek needs no duration at all', () {
      expect(
          seekRequestPath(SeekChannel.mpcHcWeb,
              targetSeconds: 60, durationSeconds: 0),
          isNotNull,
          reason: 'that was the whole point of dropping percent');
    });

    test('the clock is zero padded the way the parser expects', () {
      expect(formatSeekClock(0), '00:00:00');
      expect(formatSeekClock(61), '00:01:01');
      expect(formatSeekClock(9292), '02:34:52');
    });

    test('percent survives as a fallback, with real precision', () {
      final path = seekRequestPathByPercent(SeekChannel.mpcHcWeb,
          targetSeconds: 60, durationSeconds: 120);
      expect(path, contains('percent=50.000000'));
      expect(
          seekRequestPathByPercent(SeekChannel.mpcHcWeb,
              targetSeconds: 60, durationSeconds: 0),
          isNull);
    });

    test('VLC seeks in seconds', () {
      expect(
          seekRequestPath(SeekChannel.vlcHttp,
              targetSeconds: 60, durationSeconds: 120),
          contains('command=seek&val=60'));
    });

    test('mpv seeks over IPC, newline terminated', () {
      expect(mpvSeekCommand(60), '{"command":["seek",60,"absolute"]}\n');
    });

    test('each player is mapped to the channel it actually has', () {
      expect(seekChannelFor(PlayerKind.mpcHc), SeekChannel.mpcHcWeb);
      expect(seekChannelFor(PlayerKind.vlc), SeekChannel.vlcHttp);
      expect(seekChannelFor(PlayerKind.mpv), SeekChannel.mpvIpc);
    });
  });
}
