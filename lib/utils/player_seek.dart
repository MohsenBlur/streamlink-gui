/// Seeking a running player, and deciding when that is necessary.
///
/// The app has always passed a start position as a launch flag and assumed it
/// took effect. Measured against the real players, that assumption is false for
/// one of them: **MPC-HC discards `/start` on a network stream** while honouring
/// it for a local file, so every streamed resume landed at 0 and only *appeared*
/// to work because MPC-HC separately restores its own remembered position for a
/// URL it has seen before. A `taskkill /F` — what the self-heal does — denies it
/// the graceful exit that memory needs, which is why a heal relaunch started
/// from the beginning.
///
/// So the launch flag is no longer trusted on its own. The position is verified
/// once the player reports playing, and corrected over the same control channel
/// the progress tracker already uses.
///
/// Measured on MPC-HC 2.7.4 and VLC 3.x against a local HLS server:
///
/// | check                                   | result                    |
/// |-----------------------------------------|---------------------------|
/// | MPC-HC `/start` on an HLS URL           | ignored, landed 0s        |
/// | MPC-HC `/start` on a local file         | honoured, landed 60s      |
/// | MPC-HC `wm_command=-1` seek             | works, 90s asked → 92s    |
/// | VLC `--start-time` on an HLS URL        | works, 60s asked → 58s    |
library;

import 'player_args.dart';

/// How far a landing may miss before it is treated as a failed resume.
///
/// Measured rather than guessed: seeking a Twitch 1080p60 VOD lands on a
/// segment boundary, and the observed snap was about 27s short of the target.
/// At the 12s this started as, a correct seek still read as a miss and burned
/// both attempts fighting the container. Well under a minute, so a genuinely
/// failed resume is still unmistakable.
const int kSeekToleranceSeconds = 45;

/// How long to keep trying to land before giving up and letting playback be.
///
/// Two attempts, because the failure this corrects is categorical — the flag was
/// discarded — not flaky. If a seek does not take twice, a third will not help
/// and the user is better served by playback that continues from the wrong place
/// than by a player that keeps jumping under them.
const int kMaxSeekCorrections = 2;

/// Whether a player can be told to seek while it is running, and how.
enum SeekChannel {
  /// MPC-HC's web interface: `command.html?wm_command=-1&position=hh:mm:ss`.
  /// `-1` is `CMD_SETPOS`, read out of the shipped binary along with the
  /// request map, then measured against the running player.
  mpcHcWeb,

  /// VLC's HTTP interface: `/requests/status.json?command=seek&val=<seconds>`.
  vlcHttp,

  /// mpv's JSON IPC: `{"command":["seek",<seconds>,"absolute"]}`.
  mpvIpc,

  /// No control channel — nothing can be corrected.
  none,
}

SeekChannel seekChannelFor(PlayerKind kind) {
  switch (kind) {
    case PlayerKind.mpcHc:
      return SeekChannel.mpcHcWeb;
    case PlayerKind.vlc:
      return SeekChannel.vlcHttp;
    case PlayerKind.mpv:
      return SeekChannel.mpvIpc;
    case PlayerKind.other:
      return SeekChannel.none;
  }
}

/// `hh:mm:ss`, which is what MPC-HC's own parser expects.
String formatSeekClock(int totalSeconds) {
  final t = totalSeconds < 0 ? 0 : totalSeconds;
  final h = t ~/ 3600;
  final m = (t % 3600) ~/ 60;
  final sec = t % 60;
  String two(int v) => v < 10 ? '0$v' : '$v';
  return '${two(h)}:${two(m)}:${two(sec)}';
}

/// The request path for an HTTP-controlled player, or null for the rest.
///
/// MPC-HC is asked in **absolute time, not percent**, and that distinction is
/// load-bearing. Its web UI sends `percent`, but percent is resolved against
/// the duration the *player* loaded — under passthrough that is the HLS
/// manifest's duration, not the Twitch metadata this app holds, and the two
/// need not agree. Its command handler reads `position` first and parses it
/// exactly, so an absolute clock cannot drift with a denominator we do not own.
String? seekRequestPath(
  SeekChannel channel, {
  required int targetSeconds,
  required int durationSeconds,
}) {
  switch (channel) {
    case SeekChannel.mpcHcWeb:
      return 'command.html?wm_command=-1&position=${formatSeekClock(targetSeconds)}';
    case SeekChannel.vlcHttp:
      return 'requests/status.json?command=seek&val=$targetSeconds';
    case SeekChannel.mpvIpc:
    case SeekChannel.none:
      return null;
  }
}

/// The percent form, kept as a fallback for a build whose `position` handler
/// does not take. Needs a duration, and is only meaningful if the player's
/// loaded duration matches ours — hence second choice, not first.
String? seekRequestPathByPercent(
  SeekChannel channel, {
  required int targetSeconds,
  required int durationSeconds,
}) {
  if (channel != SeekChannel.mpcHcWeb || durationSeconds <= 0) return null;
  final pct = (targetSeconds / durationSeconds) * 100;
  final clamped = pct < 0 ? 0.0 : (pct > 100 ? 100.0 : pct);
  return 'command.html?wm_command=-1&percent=${clamped.toStringAsFixed(6)}';
}

/// The mpv IPC command, newline-terminated as the socket protocol requires.
String mpvSeekCommand(int targetSeconds) =>
    '{"command":["seek",$targetSeconds,"absolute"]}\n';

/// Tracks whether a session has landed where it was told to.
///
/// Deliberately a small value type with no IO: the decision of "is this landing
/// acceptable, and should we correct it" is the part worth testing, and it was
/// previously not expressed anywhere at all.
class LandingCheck {
  LandingCheck({required this.intendedSeconds, this.tolerance = kSeekToleranceSeconds});

  /// Where the launch asked the player to start. Zero means "no expectation" —
  /// playback from the top is correct and nothing needs verifying.
  final int intendedSeconds;
  final int tolerance;

  int _corrections = 0;
  int _samples = 0;
  bool _settled = false;

  int get corrections => _corrections;

  /// True once the position is acceptable, or once we have stopped trying.
  bool get isSettled => _settled || intendedSeconds <= 0;

  /// Whether progress may be written yet.
  ///
  /// A session that has not landed must not persist anything: writing the
  /// position of a player that restarted at the top is precisely how a bad
  /// relaunch turned into permanent data loss.
  bool get mayWriteProgress => isSettled;

  /// Feed a confirmed position. Returns the position to seek to, or null.
  ///
  /// The FIRST reading is the landing, and it is corrected in either
  /// direction. Landing too far *forward* is a real failure mode, not a
  /// courtesy: MPC-HC restores its own remembered position for a URL it has
  /// seen before, which can be an hour past what the app's own progress says.
  /// Observed live — the app showed 15% watched, the player opened at 72%.
  /// The stored position is what the user saw and clicked, so overshooting it
  /// is a surprise that can spoil an hour of content.
  ///
  /// Every reading after the first is the user's, and a forward position then
  /// means they seeked. That is left alone.
  int? evaluate(int positionSeconds) {
    if (isSettled) return null;
    final wasFirst = _samples == 0;
    _samples++;

    if ((positionSeconds - intendedSeconds).abs() <= tolerance) {
      _settled = true;
      return null;
    }
    if (!wasFirst && positionSeconds > intendedSeconds) {
      _settled = true;
      return null;
    }
    if (_corrections >= kMaxSeekCorrections) {
      _settled = true;
      return null;
    }
    _corrections++;
    return intendedSeconds;
  }

  /// Give up verifying — the player has no control channel, so there is nothing
  /// to correct and progress must be allowed to flow.
  void abandon() => _settled = true;
}
