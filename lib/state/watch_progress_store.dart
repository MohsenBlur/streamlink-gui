/// Watch positions that survive a bad session.
///
/// The old model was `vodId -> int`: one mutable number, overwritten on every
/// commit with no comparison, and pushed to Twitch the same way. When a
/// relaunched player came up at the top of the VOD — which MPC-HC does, because
/// it discards the `/start` flag on a network stream — the new session wrote its
/// way over a good position within seconds, on both sides. Both read-side merges
/// take `max(local, remote)`, so once both are zero the value is gone for good,
/// and `resumeSeconds` then maps anything under 10s to "start from the
/// beginning" forever after.
///
/// So progress is no longer a single number. Each VOD keeps the position it is
/// at, the furthest point ever reached, and a short trail — and the furthest
/// point only ever moves forward. A wrong write becomes something the user can
/// undo instead of something they simply lose.
///
/// Pure and IO-free: the file this lives in is written by StorageService, and
/// every rule here is unit tested.
library;

/// A regression larger than this, early in a session, is treated as a failed
/// resume rather than as the user seeking backwards.
///
/// Two minutes is far past any keyframe snap or buffering wobble, and far short
/// of a deliberate "start this again" — which is the movement this must not
/// block, only delay.
const int kSuspectRegressionSeconds = 120;

/// How long a session is treated as still settling.
///
/// The damage a bad restart does happens in its first seconds, while it plays
/// from the top. After this, a backward position is taken at face value: the
/// user really is rewatching, and refusing them forever would be its own bug.
const int kSessionGraceSeconds = 60;

/// How many past positions to keep per VOD.
const int kProgressTrailLength = 5;

class ProgressPoint {
  const ProgressPoint(this.seconds, this.atMs);
  final int seconds;
  final int atMs;

  Map<String, dynamic> toJson() => {'s': seconds, 't': atMs};

  static ProgressPoint? tryFromJson(dynamic j) {
    if (j is! Map) return null;
    final s = j['s'], t = j['t'];
    if (s is! int || t is! int) return null;
    return ProgressPoint(s, t);
  }
}

/// One VOD's progress.
class WatchProgress {
  WatchProgress({
    required this.position,
    required this.updatedAtMs,
    required this.best,
    required this.bestAtMs,
    List<ProgressPoint>? trail,
  }) : trail = trail ?? const [];

  /// Where playback currently is.
  int position;

  int updatedAtMs;

  /// The furthest point ever reached. Never decreases except by an explicit
  /// user action — this is the value that makes a bad write survivable.
  int best;

  int bestAtMs;

  /// Recent positions, newest first. A bounded undo trail.
  List<ProgressPoint> trail;

  /// True when the live position has fallen well behind the furthest point, so
  /// the UI can offer to jump back to it.
  bool get hasRecoverablePosition => best - position > kSuspectRegressionSeconds;

  Map<String, dynamic> toJson() => {
        'p': position,
        'u': updatedAtMs,
        'b': best,
        'ba': bestAtMs,
        'r': trail.map((e) => e.toJson()).toList(),
      };

  static WatchProgress fromJson(Map<String, dynamic> j) => WatchProgress(
        position: j['p'] is int ? j['p'] as int : 0,
        updatedAtMs: j['u'] is int ? j['u'] as int : 0,
        best: j['b'] is int ? j['b'] as int : (j['p'] is int ? j['p'] as int : 0),
        bestAtMs: j['ba'] is int ? j['ba'] as int : 0,
        trail: [
          for (final e in (j['r'] as List<dynamic>? ?? const []))
            if (ProgressPoint.tryFromJson(e) != null) ProgressPoint.tryFromJson(e)!,
        ],
      );
}

/// Why a write was refused, for the log.
enum ProgressWriteOutcome { accepted, rejectedSuspectRegression, rejectedNoChange }

class ProgressWriteResult {
  const ProgressWriteResult(this.outcome, this.entry);
  final ProgressWriteOutcome outcome;
  final WatchProgress entry;
  bool get accepted => outcome == ProgressWriteOutcome.accepted;
}

/// The single chokepoint every progress write goes through.
class WatchProgressStore {
  WatchProgressStore([Map<String, WatchProgress>? initial])
      : _entries = initial ?? <String, WatchProgress>{};

  final Map<String, WatchProgress> _entries;

  Map<String, WatchProgress> get entries => Map.unmodifiable(_entries);

  WatchProgress? operator [](String vodId) => _entries[vodId];

  /// The position to resume from: the live one, unless it has fallen far behind
  /// the furthest point.
  int? resumeFor(String vodId) => _entries[vodId]?.position;

  /// The furthest point, for the UI's "jump back" affordance.
  int? bestFor(String vodId) => _entries[vodId]?.best;

  /// Records a position.
  ///
  /// [sessionAgeMs] is how long the session that reported it has been running;
  /// a large backwards jump early in a session is a failed resume, not a seek.
  ProgressWriteResult record(
    String vodId,
    int position, {
    required int nowMs,
    required int sessionAgeMs,
  }) {
    final existing = _entries[vodId];
    if (existing == null) {
      final e = WatchProgress(
          position: position, updatedAtMs: nowMs, best: position, bestAtMs: nowMs);
      _entries[vodId] = e;
      return ProgressWriteResult(ProgressWriteOutcome.accepted, e);
    }

    final regression = existing.best - position;
    if (sessionAgeMs < kSessionGraceSeconds * 1000 &&
        regression > kSuspectRegressionSeconds) {
      // The window in which a player that restarted at the top does its damage.
      // Nothing legitimate needs to move the position two minutes backwards in
      // the first minute of playback.
      return ProgressWriteResult(
          ProgressWriteOutcome.rejectedSuspectRegression, existing);
    }

    if (position == existing.position) {
      return ProgressWriteResult(ProgressWriteOutcome.rejectedNoChange, existing);
    }

    if (existing.position != position) {
      existing.trail = [
        ProgressPoint(existing.position, existing.updatedAtMs),
        ...existing.trail,
      ].take(kProgressTrailLength).toList();
    }
    existing.position = position;
    existing.updatedAtMs = nowMs;
    if (position > existing.best) {
      existing.best = position;
      existing.bestAtMs = nowMs;
    }
    return ProgressWriteResult(ProgressWriteOutcome.accepted, existing);
  }

  /// Puts the live position back to the furthest point reached.
  bool restoreBest(String vodId, {required int nowMs}) {
    final e = _entries[vodId];
    if (e == null || e.best <= e.position) return false;
    e.trail = [
      ProgressPoint(e.position, e.updatedAtMs),
      ...e.trail,
    ].take(kProgressTrailLength).toList();
    e.position = e.best;
    e.updatedAtMs = nowMs;
    return true;
  }

  /// An explicit user reset. The only thing that may lower [WatchProgress.best]
  /// — deliberately, so "mark unwatched" genuinely means unwatched.
  void clear(String vodId) => _entries.remove(vodId);

  void clearAll() => _entries.clear();

  Map<String, dynamic> toJson() =>
      _entries.map((k, v) => MapEntry(k, v.toJson()));

  /// Reads either shape.
  ///
  /// The shipped format is a flat `id -> seconds` map, and a live config holds
  /// dozens of real entries; migration must never drop one, so an int is read
  /// as a position that is also its own furthest point.
  static WatchProgressStore fromJson(Map<String, dynamic>? json) {
    final out = <String, WatchProgress>{};
    if (json == null) return WatchProgressStore(out);
    json.forEach((key, value) {
      if (value is int) {
        out[key] = WatchProgress(
            position: value, updatedAtMs: 0, best: value, bestAtMs: 0);
      } else if (value is Map<String, dynamic>) {
        out[key] = WatchProgress.fromJson(value);
      } else if (value is Map) {
        out[key] = WatchProgress.fromJson(Map<String, dynamic>.from(value));
      }
    });
    return WatchProgressStore(out);
  }

  /// The flat shape, for anything still reading `id -> seconds`.
  Map<String, int> toFlatMap() =>
      _entries.map((k, v) => MapEntry(k, v.position));
}
