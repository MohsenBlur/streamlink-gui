/// The verdict machine for streamed VOD playback, and the gate that decides
/// which reported positions deserve to be believed.
///
/// Both exist because of one bug: pausing a passthrough VOD for ten minutes
/// makes Twitch close the idle connection, the player mistakes the failed
/// fetch for end-of-file, and in its dying moments it can report a position it
/// was never at. The old tracker believed every sample, so the bogus value was
/// persisted, pushed to Twitch, and - via the watched threshold - turned into
/// "start this VOD from zero forever".
///
/// Everything here is pure and clock-injected, in this repo's established
/// style (`activity_state.dart`, `player_args.dart`): the tracker feeds
/// samples in, decisions come out, and every rule is unit-testable without a
/// player, a socket, or a timer.
library;

import 'player_progress.dart';

/// Commits a raw position sample only once a second sample corroborates it.
///
/// The rule: a sample becomes trustworthy when the NEXT sample lands within
/// [toleranceSeconds] of where playback would have carried it. A lone reading
/// can never commit - and a dying player's last gasp (a 0 during teardown, a
/// near-end spike, garbage) is by definition a lone reading, because the
/// process dies before a corroborating sample can arrive.
///
/// A seek looks like a discontinuity followed by ordinary continuation, so it
/// commits on the second read after landing - one tick of latency, which at
/// the tracker's 2s cadence nobody can perceive.
class ProgressConfirmationGate {
  ProgressConfirmationGate({
    this.toleranceSeconds = 6,
    required this.durationSeconds,
  });

  final int toleranceSeconds;

  /// Total VOD length in seconds; 0 when unknown, which skips the
  /// past-the-end rejection.
  final int durationSeconds;

  int? _candidate;
  int? _candidateAtMs;
  int? _lastCommitted;

  int? get lastCommitted => _lastCommitted;

  /// Feed one raw sample. Returns the position to commit, or null to hold.
  int? feed({required int positionSeconds, required int nowMs}) {
    if (positionSeconds < 0) return null;
    if (durationSeconds > 0 &&
        positionSeconds > durationSeconds + toleranceSeconds) {
      // Past the end of the video is not a place a player can be. Not even
      // a candidate - two impossible readings corroborating each other are
      // still impossible.
      return null;
    }

    final prev = _candidate;
    final prevAt = _candidateAtMs;
    _candidate = positionSeconds;
    _candidateAtMs = nowMs;

    if (prev == null || prevAt == null) return null;

    // Where would playback have carried the previous sample by now? Paused
    // playback advances zero, playing advances with the wall clock - accept
    // the whole band between, plus tolerance either side. This keeps a
    // resume-after-pause (position frozen while the clock ran) as ordinary
    // continuation rather than a discontinuity.
    final elapsed = ((nowMs - prevAt) / 1000).round();
    final low = prev - toleranceSeconds;
    final high = prev + elapsed + toleranceSeconds;
    if (positionSeconds >= low && positionSeconds <= high) {
      _lastCommitted = positionSeconds;
      return positionSeconds;
    }
    // Discontinuity: the new value is now the candidate awaiting its own
    // corroboration on the next feed.
    return null;
  }
}

/// What changed this tick. Transitions only - the monitor never emits the
/// same fact twice in a row, so mapping events to log lines cannot spam.
enum MonitorEvent {
  /// First successful status read of the session.
  firstContact,

  /// The gate committed its first position.
  firstConfirmedPosition,

  paused,
  resumed,

  /// Position frozen for [VodPlaybackMonitor.stallTicks] ticks while the
  /// player claims to be playing - buffering, or a quietly dead connection.
  stalled,
  stallRecovered,

  /// eof/stopped seen this tick (pre-debounce). Logged once per episode.
  eofObserved,

  /// Debounced verdict: the stream ended mid-VOD. The supervisor should heal.
  prematureEof,

  /// Debounced verdict: the VOD genuinely finished.
  genuineEof,
}

class MonitorResult {
  const MonitorResult({this.commitPositionSeconds, this.events = const []});

  /// A freshly confirmed position to sync, or null.
  final int? commitPositionSeconds;

  final List<MonitorEvent> events;
}

/// Watches one playback session's stream of [PlayerStatus] samples and turns
/// them into confirmed positions and lifecycle verdicts.
class VodPlaybackMonitor {
  VodPlaybackMonitor({
    required this.durationSeconds,
    int toleranceSeconds = 6,
    this.minPrematureSeconds = 10,
    this.genuineEofFraction = 0.95,
    this.stallTicks = 5,
    this.eofDebounceTicks = 2,
  }) : _gate = ProgressConfirmationGate(
         toleranceSeconds: toleranceSeconds,
         durationSeconds: durationSeconds,
       );

  final int durationSeconds;
  final int minPrematureSeconds;
  final double genuineEofFraction;
  final int stallTicks;
  final int eofDebounceTicks;

  final ProgressConfirmationGate _gate;

  bool _contactSeen = false;
  bool _confirmedOnce = false;
  bool _playbackSeen = false;
  bool _wasPaused = false;
  bool _stalled = false;
  bool _eofEpisodeLogged = false;
  bool _verdictGiven = false;
  int _frozenTicks = 0;
  int _eofTicks = 0;
  int? _lastPlayingPosition;

  int? get lastConfirmedPosition => _gate.lastCommitted;

  /// At least one confirmed playing sample this session. Until this is true
  /// no EOF verdict can fire: VLC and MPC-HC bring their status interface up
  /// before playback begins and report "stopped" for the first ticks, and
  /// without this grace a session resuming at 40 minutes would be judged
  /// "prematurely ended at 40 minutes" before it had played a frame.
  bool get playbackSeen => _playbackSeen;

  MonitorResult onSample({required PlayerStatus? status, required int nowMs}) {
    final events = <MonitorEvent>[];

    if (status == null) {
      // Poll failure: no facts this tick. Deliberately NOT an eof signal -
      // a dead interface and a dead stream are different things, and the
      // process exit handler owns the former.
      return MonitorResult(events: events);
    }

    if (!_contactSeen) {
      _contactSeen = true;
      events.add(MonitorEvent.firstContact);
    }

    // --- position, through the gate --------------------------------------
    int? committed;
    if (status.positionSeconds != null &&
        status.activity == PlayerActivity.playing) {
      committed = _gate.feed(
        positionSeconds: status.positionSeconds!,
        nowMs: nowMs,
      );
      if (committed != null) {
        _playbackSeen = true;
        if (!_confirmedOnce) {
          _confirmedOnce = true;
          events.add(MonitorEvent.firstConfirmedPosition);
        }
      }
    }

    // --- pause transitions ------------------------------------------------
    final isPaused = status.activity == PlayerActivity.paused;
    if (isPaused && !_wasPaused) {
      events.add(MonitorEvent.paused);
    } else if (!isPaused && _wasPaused) {
      events.add(MonitorEvent.resumed);
    }
    _wasPaused = isPaused;

    // --- stall detection --------------------------------------------------
    if (status.activity == PlayerActivity.playing &&
        status.positionSeconds != null) {
      if (_lastPlayingPosition == status.positionSeconds) {
        _frozenTicks++;
        if (_frozenTicks == stallTicks && !_stalled) {
          _stalled = true;
          events.add(MonitorEvent.stalled);
        }
      } else {
        _frozenTicks = 0;
        if (_stalled) {
          _stalled = false;
          events.add(MonitorEvent.stallRecovered);
        }
      }
      _lastPlayingPosition = status.positionSeconds;
    } else {
      // Paused or stopped ticks neither accumulate nor reset the stall
      // counter; a pause in the middle of a stall is still a stall.
      if (status.activity == PlayerActivity.paused) {
        _frozenTicks = 0;
        if (_stalled) {
          _stalled = false;
          events.add(MonitorEvent.stallRecovered);
        }
      }
    }

    // --- EOF verdict ------------------------------------------------------
    final atEof =
        status.eofReached || status.activity == PlayerActivity.stopped;
    if (atEof) {
      _eofTicks++;
      if (!_eofEpisodeLogged) {
        _eofEpisodeLogged = true;
        events.add(MonitorEvent.eofObserved);
      }
      if (_eofTicks >= eofDebounceTicks && !_verdictGiven && _playbackSeen) {
        final confirmed = _gate.lastCommitted;
        if (confirmed != null) {
          final genuineFrom = durationSeconds > 0
              ? (durationSeconds * genuineEofFraction).floor()
              : null;
          if (genuineFrom != null && confirmed >= genuineFrom) {
            _verdictGiven = true;
            events.add(MonitorEvent.genuineEof);
          } else if (confirmed >= minPrematureSeconds) {
            _verdictGiven = true;
            events.add(MonitorEvent.prematureEof);
          }
          // Below minPrematureSeconds: observed, never acted on. Restarting
          // a stream that died in its first seconds would loop.
        }
      }
    } else {
      _eofTicks = 0;
      _eofEpisodeLogged = false;
    }

    return MonitorResult(commitPositionSeconds: committed, events: events);
  }
}

/// Restart bookkeeping that must outlive the tracker, which is torn down on
/// every relaunch. Plain data; the policy lives in [shouldAttemptRestart].
class RestartLedger {
  int attempts = 0;

  /// Confirmed position at the moment of the last restart.
  int? baselinePosition;
}

/// Whether the supervisor may bounce the session again.
///
/// Two attempts, but the count resets whenever playback has genuinely moved
/// on - [minAdvanceSeconds] past the last restart's baseline - because a
/// four-hour VOD paused three times deserves three heals, while a stream that
/// dies twice at the same second is telling us relaunching does not work.
bool shouldAttemptRestart({
  required RestartLedger ledger,
  required int confirmedPosition,
  int maxAttempts = 2,
  int minAdvanceSeconds = 30,
}) {
  final baseline = ledger.baselinePosition;
  if (baseline != null && confirmedPosition - baseline >= minAdvanceSeconds) {
    ledger.attempts = 0;
    ledger.baselinePosition = null;
  }
  return ledger.attempts < maxAttempts;
}
