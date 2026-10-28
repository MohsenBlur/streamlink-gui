/// Pure command-line construction for media players and streamlink.
///
/// Deliberately free of `dart:io` so every branch is unit-testable; callers
/// pass `isWindows` in.
library;

import 'dart:convert';

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

String mpvIpcPath(String ipcName, bool isWindows) =>
    isWindows ? r'\\.\pipe\mpv-socket-' + ipcName : '/tmp/mpv-socket-$ipcName';

/// The pipe name (without `\\.\pipe\`) the Windows bridge connects to.
String mpvPipeName(String ipcName) => 'mpv-socket-$ipcName';

/// The only mpv IPC lines the Windows bridge will pass on to mpv.
///
/// The bridge used to copy raw bytes from any loopback client straight into
/// mpv's command pipe, and mpv's IPC accepts `run <program>` - so for as long
/// as an mpv VOD played, any local process (another user's included, since TCP
/// loopback has no ACL) could run code as this user by connecting to a port
/// that starts at 8089. These match exactly what the app itself sends - the
/// three status reads in `mpvStatusCommands` and `mpvSeekCommand` - and
/// nothing else.
///
/// Written to mean the same thing to Dart's RegExp and to .NET's, because the
/// bridge enforces them in PowerShell: `[0-9]` rather than `\d`, which in .NET
/// also matches non-ASCII digits.
const List<String> mpvBridgeAllowedCommandPatterns = [
  r'^\{"command":\["get_property","(time-pos|pause|eof-reached)"\],"request_id":[0-9]+\}$',
  r'^\{"command":\["seek",[0-9]+,"absolute"\]\}$',
];

/// Whether the bridge relays [line] (one command, without its newline).
bool isMpvBridgeCommandAllowed(String line) =>
    mpvBridgeAllowedCommandPatterns.any((p) => RegExp(p).hasMatch(line));

/// The environment variable the bridge reads its per-session token from.
///
/// Not the command line: on Windows a process's command line can be read by
/// callers that cannot read its environment block.
const String mpvBridgeTokenVariable = 'STREAMLINK_GUI_MPV_BRIDGE_TOKEN';

/// The PowerShell relay that fronts mpv's Windows named pipe with a loopback
/// TCP port, because dart:io cannot open a named pipe.
///
/// One exchange per connection, and a line protocol rather than a byte copy:
///
///     <token>\n
///     <command>\n      (up to 8, each checked against the allowlist)
///     \n               (end of request)
///
/// The relay then forwards the allowed commands, writes back one reply per
/// command and closes the connection. A client that does not open with the
/// session's token - another program, or a browser POSTing to the port - is
/// dropped before anything reaches mpv.
///
/// Nothing in the script may write to stdout. Its predecessor left
/// `[Task]::WaitAny(...)` as a bare expression, so PowerShell printed the
/// result on every exchange into a pipe the app never read; after about 340
/// polls (11 minutes) the pipe was full, the relay blocked on the write, and
/// progress saving, the end-of-stream self-heal and seeking all stopped for
/// the rest of the session without a word in the log.
String buildMpvBridgeScript({required int port, required String pipeName}) {
  final allowed = mpvBridgeAllowedCommandPatterns
      .map((p) => "'${p.replaceAll("'", "''")}'")
      .join(', ');
  return _mpvBridgeScriptTemplate
      .replaceAll('@@ALLOWED@@', allowed)
      .replaceAll('@@PORT@@', '$port')
      .replaceAll('@@PIPE@@', pipeName.replaceAll("'", "''"))
      .replaceAll('@@TOKEN_VARIABLE@@', mpvBridgeTokenVariable);
}

// Raw, so PowerShell's `$` needs no escaping; the @@NAME@@ slots are filled in
// by buildMpvBridgeScript.
const String _mpvBridgeScriptTemplate = r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$token = $env:@@TOKEN_VARIABLE@@
$allowed = @(@@ALLOWED@@)
$utf8 = New-Object System.Text.UTF8Encoding($false)

# One request line, bounded in length and in time, so a client that never
# sends a newline (a port scanner, a browser holding a connection) cannot
# stall the relay or grow its memory.
function Read-RequestLine($stream, $deadline) {
  $bytes = New-Object System.Collections.Generic.List[byte]
  while ($bytes.Count -lt 512) {
    if ([DateTime]::UtcNow -gt $deadline) { return $null }
    $b = $stream.ReadByte()
    if ($b -lt 0) { return $null }
    if ($b -eq 10) { return $utf8.GetString($bytes.ToArray()).TrimEnd("`r") }
    $bytes.Add([byte]$b)
  }
  return $null
}

try {
  if ([string]::IsNullOrEmpty($token)) { exit 2 }

  # Listen first, so a poll arriving before mpv has created its pipe is
  # accepted and simply fails fast rather than being refused outright.
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, @@PORT@@)
  $listener.Start()

  while ($true) {
    $tcpClient = $listener.AcceptTcpClient()
    $pipe = $null
    try {
      $tcpClient.ReceiveTimeout = 1000
      $tcpClient.SendTimeout = 1000
      $tcpStream = $tcpClient.GetStream()
      $deadline = [DateTime]::UtcNow.AddSeconds(2)

      if ((Read-RequestLine $tcpStream $deadline) -cne $token) { continue }

      $commands = New-Object System.Collections.Generic.List[string]
      while ($commands.Count -lt 8) {
        $line = Read-RequestLine $tcpStream $deadline
        if ([string]::IsNullOrEmpty($line)) { break }
        foreach ($pattern in $allowed) {
          if ($line -cmatch $pattern) { $commands.Add($line); break }
        }
      }
      if ($commands.Count -eq 0) { continue }

      # A fresh pipe connection per request. mpv's IPC server accepts
      # sequential clients, and this keeps each poll independent: a
      # half-finished exchange cannot wedge the next one.
      $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', '@@PIPE@@', [System.IO.Pipes.PipeDirection]::InOut)
      $pipe.Connect(1000)
      $request = $utf8.GetBytes(($commands -join "`n") + "`n")
      $pipe.Write($request, 0, $request.Length)
      $pipe.Flush()

      # mpv interleaves unsolicited events with the replies; only a reply
      # carries an "error" member, and only replies go back to the client.
      $reader = New-Object System.IO.StreamReader($pipe, $utf8)
      $replyDeadline = [DateTime]::UtcNow.AddMilliseconds(1500)
      $replies = 0
      while ($replies -lt $commands.Count) {
        $wait = [int]($replyDeadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($wait -le 0) { break }
        $pending = $reader.ReadLineAsync()
        if (-not $pending.Wait($wait)) { break }
        $reply = $pending.Result
        if ($null -eq $reply) { break }
        if (-not $reply.Contains('"error":') -or $reply.StartsWith('{"event"')) { continue }
        $replies++
        $bytes = $utf8.GetBytes($reply + "`n")
        $tcpStream.Write($bytes, 0, $bytes.Length)
      }
    } catch {
      # mpv not ready yet, or the client vanished: drop this exchange and
      # keep serving.
    } finally {
      if ($pipe) { $pipe.Dispose() }
      $tcpClient.Close()
    }
  }
} catch {
  exit 1
}
''';

/// [script] in the form `powershell -EncodedCommand` takes: base64 of its
/// UTF-16LE bytes.
///
/// The bridge's allowlist is full of double quotes, which `-Command` would
/// hand to Windows PowerShell's own command-line re-parsing to mangle. The
/// encoded form has no quoting at all.
String encodePowerShellCommand(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes
      ..add(unit & 0xff)
      ..add(unit >> 8);
  }
  return base64.encode(bytes);
}

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
  bool keepOpen = false,
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
      // Streamed passthrough only. When Twitch closes a paused connection,
      // mpv mistakes the failed fetch for end-of-file; without this it EXITS,
      // which is indistinguishable from the user closing the window. With it,
      // mpv idles at the false EOF, the tracker reads `eof-reached`, and the
      // app can tell "the stream died" (heal it) from "the user quit"
      // (respect it). VLC and MPC-HC idle at EOF natively; local files never
      // hit a false EOF, so downloads leave this off and keep mpv's
      // close-at-end behaviour.
      if (keepOpen) args.add('--keep-open=yes');
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

  // The player's own stdout/stderr, which otherwise go to DEVNULL inside
  // streamlink. Under passthrough the player owns the whole HLS session, so
  // its output is the ONLY record of why playback died - without this flag a
  // VOD session's log is four lines of startup and then silence, which is
  // exactly the complaint that prompted it. On a non-tty mpv suppresses its
  // per-frame status line, so the cost is a handful of init lines. VOD only:
  // live sessions keep streamlink's own reader logs and need no second voice.
  args.add('--player-verbose');

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
    keepOpen: passthrough,
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

/// The streamlink command line for a live channel.
///
/// Extracted from PlayerService so it can be tested, and so the live and VOD
/// paths stop disagreeing. The live path used to hand-build `--player` from
/// findVlcPath()/findMpvPath()/findMpcHcPath() inline and pass a custom path
/// through untouched - so a path pasted from Explorer's "Copy as path", which
/// arrives wrapped in double quotes, worked for VODs and failed for live.
///
/// [playerExe] comes from the same resolvePlayerExecutable the VOD path uses;
/// null means no usable player was found, and no `--player` is emitted (rather
/// than a bare quoted string streamlink cannot run).
List<String> buildLiveStreamlinkArgs({
  required String channelName,
  required String titleString,
  required String quality,
  required String oauthToken, // already stripped of any 'oauth:' prefix
  required String clientId,
  required String? playerExe,
  required String customPlayerArgs,
  required bool lowLatency,
}) {
  final args = <String>['--title', titleString];

  if (oauthToken.isNotEmpty && clientId == 'kimne78kx3ncx6brgo4mv6wki5h1ko') {
    args.addAll(['--twitch-api-header', 'Authorization=OAuth $oauthToken']);
  }

  // Supported by the bundled streamlink 8.4.0, contrary to the comment that
  // used to sit at this spot claiming it was deprecated. Live only: it lowers
  // --hls-live-edge and prefetches, neither of which means anything for a VOD.
  if (lowLatency) args.add('--twitch-low-latency');

  if (playerExe != null) args.addAll(['--player', playerExe]);

  if (customPlayerArgs.trim().isNotEmpty) {
    args.addAll(['--player-args', customPlayerArgs.trim()]);
  }

  // Positional, and order matters: URL then quality.
  args.add('twitch.tv/$channelName');
  args.add(quality);

  return args;
}
