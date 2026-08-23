/// Reading a playback position out of what each player reports.
///
/// These three parsers lived inside the progress tracker's timer callback,
/// each inside its own `catch (_) {}`. That combination is why the MPV shlex
/// bug survived several releases: a parser that quietly returned nothing was
/// indistinguishable from a player that was paused, and nothing could observe
/// the difference. Out here they are ordinary functions with return values.
///
/// All three return null for "no usable position right now" - not playing,
/// paused, seeking, at zero, or unparseable - which the caller treats the same
/// way: skip this tick.
library;

import 'dart:convert';

/// VLC's HTTP interface: `GET /requests/status.json`.
///
/// Reports `time` in whole seconds and a `state` of playing/paused/stopped.
int? parseVlcPosition(String body) {
  try {
    final data = json.decode(body);
    if (data is! Map) return null;
    if (data['state'] != 'playing') return null;
    final time = data['time'];
    if (time is! int || time <= 0) return null;
    return time;
  } catch (_) {
    return null;
  }
}

/// What MPV's JSON IPC replied to `time-pos` and `pause`.
///
/// The replies arrive as newline-delimited JSON on one socket and may be in
/// either order, or interleaved with unrelated event messages, so both are
/// picked out by the type of their `data` rather than by position. A reply
/// carrying an `error` other than "success" has no usable data.
int? parseMpvPosition(String raw) {
  double? timePos;
  bool isPaused = false;
  var sawPosition = false;

  for (final line in raw.split('\n')) {
    if (line.trim().isEmpty) continue;
    try {
      final parsed = json.decode(line);
      if (parsed is! Map) continue;
      final error = parsed['error'];
      if (error is String && error != 'success') continue;
      final data = parsed['data'];
      if (data is num) {
        timePos = data.toDouble();
        sawPosition = true;
      } else if (data is bool) {
        isPaused = data;
      }
    } catch (_) {
      // One malformed line must not discard the rest of the reply.
    }
  }

  if (!sawPosition || isPaused) return null;
  if (timePos == null || timePos < 0) return null;
  return timePos.round();
}

/// MPC-HC's web interface: `GET /variables.html`.
///
/// Position is in milliseconds, and `statestring` is a human string ("Playing",
/// "Paused", "Stopped") rather than a code.
int? parseMpcHcPosition(String html) {
  final posMatch = RegExp(r'id="position">(\d+)<').firstMatch(html);
  final stateMatch = RegExp(r'id="statestring">([^<]+)<').firstMatch(html);

  final state = stateMatch?.group(1);
  if (state == null || !state.toLowerCase().contains('play')) return null;

  final posMs = posMatch == null ? null : int.tryParse(posMatch.group(1)!);
  if (posMs == null || posMs <= 0) return null;

  return (posMs / 1000).round();
}
