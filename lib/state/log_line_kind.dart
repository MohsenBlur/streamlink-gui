/// Classification of a single process log line, so the viewer can colour it.
///
/// Pure and Flutter-free (like the rest of `lib/state/`); the kind -> Color
/// mapping lives in the widget layer.
enum LogLineKind {
  /// Anything that reads as a failure, whatever emitted it.
  error,

  /// App-emitted `[System]` narration.
  system,

  /// Streamlink's own output.
  streamlink,

  /// Streamlink CLI progress/info, including the stream listing.
  cliInfo,

  /// yt-dlp download progress.
  download,

  /// Everything else.
  plain,
}

/// Classifies [line] for display.
///
/// Note the precedence: failure markers are tested FIRST, so a line like
/// `[System] Download failed with exit code 1` is an [LogLineKind.error]
/// rather than [LogLineKind.system]. That is deliberate — the thing a reader
/// is scanning for is the failure, not which subsystem narrated it.
LogLineKind classifyLogLine(String line) {
  // Case-insensitive, because the markers never were consistent: the VOD
  // path emitted `[Streamlink ERR]` for four releases while this test looked
  // for `[Streamlink Err]`, so every streamed-VOD stderr line rendered as
  // plain grey - precisely the lines a reader opens the log to find.
  final lower = line.toLowerCase();
  if (lower.contains('[error]') ||
      lower.contains('[streamlink err]') ||
      lower.contains('error:') ||
      lower.contains('failed')) {
    return LogLineKind.error;
  }
  if (line.startsWith('[System]')) return LogLineKind.system;
  if (line.startsWith('[Streamlink]')) return LogLineKind.streamlink;
  if (line.contains('[cli][info]') || line.contains('Available streams:')) {
    return LogLineKind.cliInfo;
  }
  if (line.contains('[Download]')) return LogLineKind.download;
  return LogLineKind.plain;
}
