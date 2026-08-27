/// Reading playback status out of what each player reports.
///
/// These parsers lived inside the progress tracker's timer callback, each
/// inside its own `catch (_) {}`. That combination is why the MPV shlex bug
/// survived several releases: a parser that quietly returned nothing was
/// indistinguishable from a player that was paused, and nothing could observe
/// the difference. Out here they are ordinary functions with return values.
///
/// They used to return a bare position, with null meaning "skip this tick" -
/// which conflated five different situations (paused, stopped, seeking,
/// unparseable, genuinely at zero). The pause-death bug made the distinction
/// load-bearing: a player sitting at end-of-file mid-VOD is a fact the app
/// must act on, and a bare null cannot carry it. So each parser now returns a
/// [PlayerStatus]; null remains only for "the reply was not parseable at all".
library;

import 'dart:convert';

/// What the player is doing right now.
enum PlayerActivity { playing, paused, stopped }

/// One poll's worth of truth about the player.
class PlayerStatus {
  const PlayerStatus({
    required this.activity,
    this.positionSeconds,
    this.eofReached = false,
  });

  final PlayerActivity activity;

  /// Whole seconds, or null when the player reported no position this tick.
  /// Zero IS a position - the confirmation gate downstream decides whether to
  /// believe it, not the parser.
  final int? positionSeconds;

  /// mpv only: the `eof-reached` property. With `--keep-open=yes` an mpv that
  /// hit end-of-file idles here instead of exiting, which is what lets the app
  /// distinguish "the stream died" from "the user closed the player".
  final bool eofReached;
}

/// VLC's HTTP interface: `GET /requests/status.json`.
///
/// Reports `time` in whole seconds and a `state` of playing/paused/stopped.
/// Anything that is not playing or paused - `stopped`, `opening`, unknown -
/// maps to [PlayerActivity.stopped]: for the verdict machine they are all
/// "not currently playing back", and the machine's own startup grace handles
/// the interface being up before playback begins.
PlayerStatus? parseVlcStatus(String body) {
  try {
    final data = json.decode(body);
    if (data is! Map) return null;
    final state = data['state'];
    if (state is! String) return null;
    final time = data['time'];
    final position = (time is int && time >= 0) ? time : null;
    switch (state) {
      case 'playing':
        return PlayerStatus(
          activity: PlayerActivity.playing,
          positionSeconds: position,
        );
      case 'paused':
        return PlayerStatus(
          activity: PlayerActivity.paused,
          positionSeconds: position,
        );
      default:
        return PlayerStatus(
          activity: PlayerActivity.stopped,
          positionSeconds: position,
        );
    }
  } catch (_) {
    return null;
  }
}

/// The mpv JSON IPC request ids for the three properties one tick asks for.
///
/// Ids, not types: the replies arrive as newline-delimited JSON in any order,
/// and the old parser told them apart by the TYPE of `data` - a num was the
/// position, a bool was `pause`. That dispatch cannot absorb `eof-reached`,
/// which is also a bool. mpv echoes `request_id` verbatim on every reply, so
/// the commands carry one each and the parser matches on it.
const int mpvTimePosRequestId = 1;
const int mpvPauseRequestId = 2;
const int mpvEofRequestId = 3;

/// The newline-terminated command lines one status tick writes to mpv.
List<String> mpvStatusCommands() => [
  '{"command":["get_property","time-pos"],"request_id":$mpvTimePosRequestId}\n',
  '{"command":["get_property","pause"],"request_id":$mpvPauseRequestId}\n',
  '{"command":["get_property","eof-reached"],"request_id":$mpvEofRequestId}\n',
];

/// Whether [buffer] already holds a reply for every request id above.
///
/// The tracker used to destroy the socket as soon as the buffer contained ANY
/// newline, which raced the second reply - and with three commands it would
/// lose one routinely. The read loop now waits for all three (or its settle
/// timeout, whichever comes first).
bool mpvRepliesComplete(String buffer) {
  for (final id in const [
    mpvTimePosRequestId,
    mpvPauseRequestId,
    mpvEofRequestId,
  ]) {
    if (!buffer.contains('"request_id":$id')) return false;
  }
  return true;
}

/// What mpv's JSON IPC replied.
///
/// Lines carrying a `request_id` are matched by id. Lines without one - old
/// mpv, or the unsolicited event messages interleaved on the same socket -
/// fall back to the historical type dispatch (num = position, bool = pause),
/// so a partial reply still yields something. A reply with an `error` other
/// than "success" is skipped per-property: `eof-reached` being unavailable
/// during load simply reads as false.
PlayerStatus? parseMpvStatus(String raw) {
  double? timePos;
  bool isPaused = false;
  bool eof = false;
  var sawAnything = false;

  for (final line in raw.split('\n')) {
    if (line.trim().isEmpty) continue;
    try {
      final parsed = json.decode(line);
      if (parsed is! Map) continue;
      final error = parsed['error'];
      if (error is String && error != 'success') continue;
      if (!parsed.containsKey('data')) continue;
      final data = parsed['data'];
      final requestId = parsed['request_id'];
      sawAnything = true;
      switch (requestId) {
        case mpvTimePosRequestId:
          if (data is num) timePos = data.toDouble();
        case mpvPauseRequestId:
          if (data is bool) isPaused = data;
        case mpvEofRequestId:
          if (data is bool) eof = data;
        default:
          // No request id: the pre-request_id dispatch, kept so one lost id
          // degrades to the old behaviour instead of a lost tick.
          if (data is num) {
            timePos = data.toDouble();
          } else if (data is bool) {
            isPaused = data;
          }
      }
    } catch (_) {
      // One malformed line must not discard the rest of the reply.
    }
  }

  if (!sawAnything) return null;
  final position = (timePos != null && timePos >= 0) ? timePos.round() : null;
  final activity = eof
      ? PlayerActivity.stopped
      : (isPaused ? PlayerActivity.paused : PlayerActivity.playing);
  return PlayerStatus(
    activity: activity,
    positionSeconds: position,
    eofReached: eof,
  );
}

/// MPC-HC's web interface: `GET /variables.html`.
///
/// Position and duration are in milliseconds, and `statestring` is a human
/// string ("Playing", "Paused", "Stopped") rather than a code.
///
/// MPC-HC never says "Stopped" at end-of-file - measured against 2.7.4 with
/// an instrumented HLS server: it pauses on the last frame, and when a live
/// source DIES it plays ~10s of frozen position while the buffer drains and
/// then JUMPS THE POSITION TO THE FULL DURATION and pauses there. That jump
/// is the dying gasp that used to mark a half-watched VOD ~100% complete. So
/// "paused at (or slightly past - a few hundred ms of overshoot is normal)
/// the duration" is MPC-HC's end-of-file signal, the exact analogue of mpv's
/// keep-open idle: a real user pause never moves the position, only EOF
/// parks a player at the very end.
PlayerStatus? parseMpcHcStatus(String html) {
  final posMatch = RegExp(r'id="position">(\d+)<').firstMatch(html);
  final durMatch = RegExp(r'id="duration">(\d+)<').firstMatch(html);
  final stateMatch = RegExp(r'id="statestring">([^<]+)<').firstMatch(html);

  final state = stateMatch?.group(1)?.toLowerCase();
  if (state == null) return null;

  final posMs = posMatch == null ? null : int.tryParse(posMatch.group(1)!);
  final durMs = durMatch == null ? null : int.tryParse(durMatch.group(1)!);
  final position = posMs == null ? null : (posMs / 1000).round();

  final pausedAtEnd = state.contains('pause') &&
      posMs != null &&
      durMs != null &&
      durMs > 0 &&
      posMs >= durMs - 1000;
  if (pausedAtEnd) {
    return PlayerStatus(
        activity: PlayerActivity.stopped,
        positionSeconds: position,
        eofReached: true);
  }

  final activity = state.contains('play')
      ? PlayerActivity.playing
      : (state.contains('pause')
            ? PlayerActivity.paused
            : PlayerActivity.stopped);
  return PlayerStatus(activity: activity, positionSeconds: position);
}
