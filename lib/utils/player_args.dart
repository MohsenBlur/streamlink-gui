/// Pure command-line construction for media players and streamlink.
///
/// Deliberately free of `dart:io` so every branch is unit-testable; callers
/// pass `isWindows` in.
library;

/// Which family of command-line flags a player understands.
///
/// This classification was previously written out three times — in
/// `playDownloadedVod`, in `launchStreamlinkForVod` and again in the progress
/// tracker — and had already started to drift between them.
enum PlayerKind { vlc, mpv, mpcHc, other }

PlayerKind classifyPlayer(String effectivePlayerType, String customPlayerPath) {
  switch (effectivePlayerType) {
    case 'vlc':
      return PlayerKind.vlc;
    case 'mpv':
      return PlayerKind.mpv;
    case 'mpc-hc':
      return PlayerKind.mpcHc;
    case 'custom':
      final p = customPlayerPath.toLowerCase();
      if (p.contains('vlc')) return PlayerKind.vlc;
      if (p.contains('mpv')) return PlayerKind.mpv;
      if (p.contains('mpc')) return PlayerKind.mpcHc;
      return PlayerKind.other;
    default:
      return PlayerKind.other;
  }
}

/// Where playback should start, in whole seconds; 0 means "from the beginning".
///
/// Ignores a position under 10s (the user barely started) and ignores any
/// position on a VOD already counted as watched, so a replay does not open at
/// the end. Both rules already existed, expressed differently in two places.
int resumeSeconds({
  required int? watchPosition,
  required double? watchProgress,
  required int watchedThreshold, // percent, 50..100
}) {
  final pos = watchPosition ?? 0;
  if (pos <= 10) return 0;
  if (watchProgress != null && watchProgress >= watchedThreshold / 100.0) {
    return 0;
  }
  return pos;
}

/// MPC-HC view preset: 1 = minimal, 2 = compact, 3 = normal. Compact keeps the
/// seek bar and transport controls visible; minimal hides them.
const List<String> mpcViewPresetCompact = ['/viewpreset', '2'];

String mpvIpcPath(String ipcName, bool isWindows) => isWindows
    ? r'\\.\pipe\mpv-socket-' + ipcName
    : '/tmp/mpv-socket-$ipcName';

/// Player-side flags for one playback session, WITHOUT the input (file path or
/// URL) — the caller, or streamlink, appends that last.
///
/// [startSeconds] of 0 means no seek. This is the only place the per-player
/// resume flags live: VLC `--start-time=<s>`, MPV `--start=<s>`, MPC-HC
/// `/start <ms>`.
List<String> buildPlayerArgs({
  required PlayerKind kind,
  required int startSeconds,
  required int port,
  required String ipcName,
  required bool isWindows,
}) {
  final args = <String>[];
  switch (kind) {
    case PlayerKind.vlc:
      if (startSeconds > 0) args.add('--start-time=$startSeconds');
      args.addAll([
        '--extraintf=http',
        '--http-port=$port',
        '--http-password=streamlink',
        '--http-host=127.0.0.1',
      ]);
    case PlayerKind.mpv:
      if (startSeconds > 0) args.add('--start=$startSeconds');
      args.add('--input-ipc-server=${mpvIpcPath(ipcName, isWindows)}');
    case PlayerKind.mpcHc:
      if (startSeconds > 0) args.addAll(['/start', '${startSeconds * 1000}']);
      args.addAll(['/webport', '$port']);
      args.addAll(mpcViewPresetCompact);
    case PlayerKind.other:
      break;
  }
  return args;
}

/// Quotes one token so it survives streamlink's `--player-args` parsing.
///
/// Streamlink splits that string with POSIX `shlex`, where a backslash escapes
/// the following character. MPV's Windows pipe path
/// `--input-ipc-server=\\.\pipe\mpv-socket-1` arrived as
/// `--input-ipc-server=.pipempv-socket-1`, so MPV never created the pipe the
/// progress bridge connects to and watch tracking silently did nothing while
/// streaming. Single quotes are the one shlex construct that keeps backslashes
/// literal — double quotes still consume the first of each pair.
String shlexQuote(String token) {
  if (!token.contains('\\') &&
      !token.contains(' ') &&
      !token.contains('"') &&
      !token.contains("'")) {
    return token;
  }
  return "'" + token.replaceAll("'", r"'\''") + "'";
}

/// Joins generated tokens for `--player-args`.
///
/// Note: the user's own `customPlayerArgs` is a free-form multi-token string
/// and must NOT be passed through here — it is forwarded verbatim, as before.
String joinPlayerArgs(Iterable<String> tokens) =>
    tokens.map(shlexQuote).join(' ');

/// The outcome of building a streamlink command for a VOD.
class VodStreamCommand {
  const VodStreamCommand({
    required this.args,
    required this.passthrough,
    required this.appliedStart,
    required this.resumeUnsupported,
  });

  /// Full streamlink argv.
  final List<String> args;

  /// True when the player owns the timeline, i.e. its seek bar works.
  final bool passthrough;

  /// Seconds the session actually starts at; 0 means from the top.
  final int appliedStart;

  /// Passthrough is on and a resume was wanted, but this player has no
  /// start-position flag we know of.
  final bool resumeUnsupported;
}

/// Builds the streamlink argv for streaming a VOD.
///
/// With [seekableStreaming] the stream URL is handed to the player
/// (`--player-passthrough hls`) so the player fetches the HLS playlist itself
/// and its seek bar works across the whole VOD. Without it, streamlink pipes
/// the stream to the player's stdin — a pipe has no timeline, so seeking is
/// impossible and the only way to start partway in is streamlink's own
/// `--hls-start-offset`.
VodStreamCommand buildVodStreamlinkArgs({
  required String vodId,
  required String titleString,
  required String quality,
  required String oauthToken, // already stripped of any 'oauth:' prefix
  required String clientId,
  required PlayerKind kind,
  required String? playerExe, // null => emit no --player
  required String customPlayerArgs,
  required int port,
  required bool seekableStreaming,
  required int resume, // already through resumeSeconds()
  required bool isWindows,
}) {
  final args = <String>['--title', titleString];

  if (oauthToken.isNotEmpty && clientId == 'kimne78kx3ncx6brgo4mv6wki5h1ko') {
    args.addAll(['--twitch-api-header', 'Authorization=OAuth $oauthToken']);
  }

  // Passthrough requires an explicit --player: streamlink aborts with "The
  // default player (VLC) does not seem to be installed" when it has none, so a
  // configuration that resolves to no player must stay on piping.
  final passthrough = seekableStreaming && playerExe != null;
  if (playerExe != null) args.addAll(['--player', playerExe]);

  // Under passthrough the player holds the whole playlist, so resume is a
  // player-side flag. Under piping the player has no timeline at all and only
  // streamlink can skip ahead.
  final playerStart = passthrough ? resume : 0;
  final extra = buildPlayerArgs(
    kind: kind,
    startSeconds: playerStart,
    port: port,
    ipcName: vodId,
    isWindows: isWindows,
  );

  final parts = <String>[
    if (customPlayerArgs.trim().isNotEmpty) customPlayerArgs.trim(),
    if (extra.isNotEmpty) joinPlayerArgs(extra),
  ];
  if (parts.isNotEmpty) args.addAll(['--player-args', parts.join(' ')]);

  if (passthrough) {
    args.addAll(['--player-passthrough', 'hls']);
  } else if (resume > 0) {
    args.addAll(['--hls-start-offset', '${resume}s']);
  }

  // Positional, and order matters: URL then quality.
  args.add('twitch.tv/videos/$vodId');
  args.add(quality);

  final unsupported = passthrough && resume > 0 && kind == PlayerKind.other;
  return VodStreamCommand(
    args: args,
    passthrough: passthrough,
    appliedStart: unsupported ? 0 : resume,
    resumeUnsupported: unsupported,
  );
}
