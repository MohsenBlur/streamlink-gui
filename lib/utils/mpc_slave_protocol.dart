/// MPC-HC's /slave API, the part of it this app speaks.
///
/// The player is started with `/slave <window>` and reports to that window
/// with WM_COPYDATA; the app sends it commands the same way. The window, and
/// the check that a message really comes from the player this session
/// launched, are the runner's (windows/runner/mpc_slave.cpp); this is what the
/// messages mean.
///
/// It replaces MPC-HC's web interface, which the app used to turn on with
/// `/webport` and which has no authentication at all: while a VOD played, any
/// web page could drive the player with a plain GET - open a UNC path, which
/// hands the account's NTLM hash to whoever serves it, list folders, send
/// commands. Window messages reach neither the network nor a browser.
///
/// Ids and formats are MPC-HC's `src/mpc-hc/MpcApi.h` (2.8.4); MPC-BE's
/// `mpcapi.h` uses the same. Every payload is a string.
///
/// Pure and clock-free, like the other parsers here.
library;

import 'player_progress.dart';

/// The command ids, from MpcApi.h.
abstract final class MpcCommand {
  // Player -> app.

  /// Sent once the player has read its command line; the payload is its
  /// main window, which the runner then holds it to.
  static const int connect = 0x50000000;

  /// The load state, as an [MpcLoadState] value.
  static const int state = 0x50000001;

  /// The play state, as an [MpcPlayState] value.
  static const int playMode = 0x50000002;

  /// `title|author|description|filename|duration`, the duration in seconds
  /// (`%.3f` in MPC-HC, `%d` in MPC-BE). `|` inside a field is escaped as
  /// `\|`; a backslash is not escaped, so a path can end in one.
  static const int nowPlaying = 0x50000003;

  /// The answer to [getCurrentPosition]: seconds, `%.3f`.
  static const int currentPosition = 0x50000007;

  /// Sent after every seek, the user's included: the new position.
  static const int notifySeek = 0x50000008;

  /// Sent with each play-state change while the player sits at the end of
  /// the media.
  static const int notifyEndOfStream = 0x50000009;

  static const int version = 0x5000000A;

  /// The player is closing.
  static const int disconnect = 0x5000000B;

  // App -> player.

  /// Seconds, read with `_wtof`.
  static const int setPosition = 0xA0002000;
  static const int getNowPlaying = 0xA0003002;
  static const int getCurrentPosition = 0xA0003004;
  static const int closeApp = 0xA0004006;
}

/// MPC_LOADSTATE. MPC-HC's own enum has a sixth value, aborting (5), which it
/// sends as it is; anything but [loaded] is "nothing playing".
abstract final class MpcLoadState {
  static const int closed = 0;
  static const int loading = 1;
  static const int loaded = 2;
  static const int closing = 3;
  static const int failing = 4;
}

/// MPC_PLAYSTATE.
abstract final class MpcPlayState {
  static const int play = 0;
  static const int pause = 1;
  static const int stop = 2;
}

/// Seconds as MPC-HC formats them (`%.3f`, or `%d` for a DVD and MPC-BE's
/// durations), or null.
double? parseMpcSeconds(String payload) {
  final value = double.tryParse(payload.trim());
  if (value == null || value.isNaN || value.isInfinite || value < 0) {
    return null;
  }
  return value;
}

/// The duration a [MpcCommand.nowPlaying] carries, or null.
///
/// The last field, after the last `|`: the duration never contains one, and
/// the fields before it can (escaped) - and a filename ending in a backslash
/// turns the separator after it into what looks like an escape, so the
/// fields cannot be split reliably from the front.
double? parseMpcNowPlayingDuration(String payload) {
  final bar = payload.lastIndexOf('|');
  if (bar < 0) return null;
  final duration = parseMpcSeconds(payload.substring(bar + 1));
  return duration == null || duration <= 0 ? null : duration;
}

/// The payload of [MpcCommand.setPosition] for [seconds].
String mpcSetPositionPayload(int seconds) => '${seconds < 0 ? 0 : seconds}';

/// What one player session has reported, folded into the [PlayerStatus] the
/// progress tracker reads.
///
/// The web interface answered one request with everything; /slave reports
/// changes as they happen and the position on request, so the state is kept
/// here between polls.
class MpcSlaveState {
  bool connected = false;
  bool disconnected = false;
  int loadState = MpcLoadState.closed;

  /// Null until the player has said; MPC-HC reports it on every change.
  int? playMode;

  /// The player's own duration for what it opened, from now-playing.
  double? durationSeconds;

  /// Set by [MpcCommand.notifyEndOfStream], cleared by anything that moves
  /// the player off the end: a seek, playing again, another file.
  bool endOfStream = false;

  /// The latest position the player reported, by either message.
  double? lastPosition;

  /// Folds one message in.
  void apply(int command, String payload) {
    switch (command) {
      case MpcCommand.connect:
        connected = true;
      case MpcCommand.state:
        final state = int.tryParse(payload.trim());
        if (state != null) {
          if (state != loadState) endOfStream = false;
          loadState = state;
        }
      case MpcCommand.playMode:
        final mode = int.tryParse(payload.trim());
        if (mode != null) {
          playMode = mode;
          if (mode == MpcPlayState.play) endOfStream = false;
        }
      case MpcCommand.nowPlaying:
        durationSeconds = parseMpcNowPlayingDuration(payload);
      case MpcCommand.currentPosition:
        lastPosition = parseMpcSeconds(payload) ?? lastPosition;
      case MpcCommand.notifySeek:
        lastPosition = parseMpcSeconds(payload) ?? lastPosition;
        endOfStream = false;
      case MpcCommand.notifyEndOfStream:
        endOfStream = true;
      case MpcCommand.disconnect:
        disconnected = true;
    }
  }

  /// The tracker's view of the player, with [position] - this poll's answer,
  /// or null when there was none.
  ///
  /// End of stream is MPC-HC saying so, or the position parked at its own
  /// duration while paused. The second is what the web interface had to go
  /// on - MPC-HC 2.7.4, measured with an instrumented HLS server, pauses on
  /// the last frame at EOF, and when a live source dies it plays ~10s of
  /// frozen position while the buffer drains, then jumps the position to the
  /// full duration and pauses there - and it is kept as the fallback, since
  /// the end-of-stream message is only sent with a play-state change. A real
  /// pause never moves the position, so only the end parks a player there.
  PlayerStatus status(double? position) {
    final seconds = position?.round();
    if (!connected || disconnected || loadState != MpcLoadState.loaded) {
      return PlayerStatus(
          activity: PlayerActivity.stopped, positionSeconds: seconds);
    }
    final duration = durationSeconds;
    final pausedAtEnd = playMode == MpcPlayState.pause &&
        position != null &&
        duration != null &&
        position >= duration - 1;
    if ((endOfStream && playMode != MpcPlayState.play) || pausedAtEnd) {
      return PlayerStatus(
          activity: PlayerActivity.stopped,
          positionSeconds: seconds,
          eofReached: true);
    }
    final activity = switch (playMode) {
      MpcPlayState.play => PlayerActivity.playing,
      MpcPlayState.pause => PlayerActivity.paused,
      _ => PlayerActivity.stopped,
    };
    return PlayerStatus(activity: activity, positionSeconds: seconds);
  }
}
