import '../models/twitch_video.dart';

/// One row in the Library view: a downloaded file and/or a watched VOD.
class LibraryEntry {
  const LibraryEntry({
    required this.vodId,
    required this.title,
    required this.channel,
    this.filePath,
    this.sizeBytes,
    this.modified,
    this.watchProgress,
    this.video,
  });

  final String vodId;
  final String title;

  /// Null when the channel is genuinely unknown - a file outside the download
  /// tree, or watch history with no channel recorded against the id.
  ///
  /// This used to fall back to the literal strings 'VOD' and 'Streamed', which
  /// the Library then offered as channel filter chips beside real channel
  /// names, and matched on in search. A sentinel that renders is a lie.
  final String? channel;

  /// Null for streamed-only entries (watched, never downloaded).
  final String? filePath;
  final int? sizeBytes;
  final DateTime? modified;

  /// 0..1 when known from watch history.
  final double? watchProgress;

  /// Full metadata when the VOD is in the recently-watched history; entries
  /// known only from the download registry have none.
  final TwitchVideo? video;

  bool get isDownloaded => filePath != null;

  /// Best available date for "Newest" sorting: file mtime, else publish date.
  DateTime? get sortDate => modified ?? video?.publishedAt;
}

/// Result shape for the injected stat function.
typedef LibraryFileStat = ({int size, DateTime modified});

/// Splits `Some Title - v12345.mp4` into title and vod id, mirroring the
/// anchored download-file convention in PlayerService. Returns null when the
/// name does not follow it (hand-renamed files keep their whole name as
/// title, handled by the caller).
({String title, String vodId})? parseDownloadedVodFilename(String fileName) {
  // Strip the extension first; ids are numeric and always terminal.
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final match = RegExp(r'^(.*) - v?(\d+)$', caseSensitive: false).firstMatch(stem);
  if (match == null) return null;
  final title = match.group(1)!.trim();
  if (title.isEmpty) return null;
  return (title: title, vodId: match.group(2)!);
}

/// Channel folder for a download path: the first path segment under the
/// download root (downloads land in `<root>/<channel>/<file>`), falling back
/// to the parent directory name for files outside the root.
String? channelFromDownloadPath(String filePath, String downloadRoot) {
  String norm(String p) => p.replaceAll('\\', '/');
  final path = norm(filePath);
  final root = norm(downloadRoot).replaceAll(RegExp(r'/+$'), '');

  List<String> segments;
  if (root.isNotEmpty && path.toLowerCase().startsWith('${root.toLowerCase()}/')) {
    segments = path.substring(root.length + 1).split('/');
  } else {
    segments = path.split('/');
    // Drop the file name; the parent dir is the last remaining segment.
    if (segments.length < 2) return null;
    return segments[segments.length - 2].isEmpty ? null : segments[segments.length - 2];
  }
  if (segments.length < 2) return null; // file directly in the root
  return segments.first.isEmpty ? null : segments.first;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Builds the Library rows from persisted state. IO-free: file metadata comes
/// through [statFile] (return null for a missing file - the entry is dropped
/// for downloads, mirroring _checkDownloadedVods' pruning view).
List<LibraryEntry> buildLibraryEntries({
  required Map<String, String> registry,
  required List<TwitchVideo> recents,
  required Map<String, int> localProgress,
  required Map<String, String> channelNames,
  required String downloadRoot,
  required LibraryFileStat? Function(String path) statFile,
}) {
  final entries = <LibraryEntry>[];
  final recentsById = {for (final v in recents) v.id: v};
  final seen = <String>{};

  registry.forEach((vodId, filePath) {
    final stat = statFile(filePath);
    if (stat == null) return; // file gone; the registry prune will catch up
    seen.add(vodId);

    final video = recentsById[vodId];
    final fileName = filePath.replaceAll('\\', '/').split('/').last;
    final parsed = parseDownloadedVodFilename(fileName);
    final title = video?.title ??
        parsed?.title ??
        (fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName);
    final channel =
        channelFromDownloadPath(filePath, downloadRoot) ?? channelNames[vodId];

    entries.add(LibraryEntry(
      vodId: vodId,
      title: title,
      channel: channel,
      filePath: filePath,
      sizeBytes: stat.size,
      modified: stat.modified,
      watchProgress: video?.watchProgress,
      video: video,
    ));
  });

  // Streamed-only history: watched but never downloaded.
  for (final video in recents) {
    if (seen.contains(video.id)) continue;
    entries.add(LibraryEntry(
      vodId: video.id,
      title: video.title,
      channel: channelNames[video.id],
      watchProgress: video.watchProgress,
      video: video,
    ));
  }

  entries.sort((a, b) {
    final da = a.sortDate;
    final db = b.sortDate;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return db.compareTo(da);
  });
  return entries;
}

List<LibraryEntry> filterLibraryEntries(List<LibraryEntry> entries, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return entries;
  return entries
      .where((e) =>
          e.title.toLowerCase().contains(q) ||
          (e.channel?.toLowerCase().contains(q) ?? false) ||
          e.vodId.contains(q))
      .toList();
}
