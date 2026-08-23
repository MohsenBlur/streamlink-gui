import 'download_view_state.dart';

/// What kind of work an [ActivityItem] represents.
///
/// The kind is carried explicitly so callers never parse key strings to decide
/// how to stop something — routing a `dl-` key into `PlayerService.killProcess`
/// trips an assert there, because downloads must be cancelled (which cleans up
/// the partial file) rather than killed.
enum ActivityKind {
  /// yt-dlp is running for this VOD.
  downloading,

  /// Queued for download; no process yet, so cancelling loses nothing.
  queued,

  /// A live stream is open in the player.
  liveStream,

  /// A VOD is open in the player (streamed or a local file).
  playingVod,
}

class ActivityItem {
  const ActivityItem({
    required this.kind,
    required this.id,
    required this.label,
    this.progress,
    this.status,
  });

  final ActivityKind kind;

  /// The VOD id for downloads and VOD playback; the channel name for streams.
  final String id;

  final String label;

  /// 0..1 for a running download; null otherwise.
  final double? progress;

  /// yt-dlp's status text, e.g. "45.2% at 3.1MiB/s".
  final String? status;

  /// The log session key for this item, matching what PlayerService registers.
  String get logKey => switch (kind) {
        ActivityKind.downloading || ActivityKind.queued =>
          logKeyForDownload(id),
        ActivityKind.liveStream => logKeyForLiveStream(id),
        ActivityKind.playingVod => id,
      };

  bool get isDownload =>
      kind == ActivityKind.downloading || kind == ActivityKind.queued;
}

/// The log session key for a download, as PlayerService registers it.
///
/// Hand-built as 'dl-$vodId' at several call sites; one spelling of it means a
/// mismatch cannot silently point "View log" at a session that does not exist.
String logKeyForDownload(String vodId) => 'dl-$vodId';

/// The log session key for a live stream. Lowercased: Twitch logins are
/// case-insensitive and reach this from sources that disagree about case.
String logKeyForLiveStream(String channel) =>
    'stream_${channel.toLowerCase()}';

/// Everything currently happening, in the order the UI should show it.
class ActivitySnapshot {
  const ActivitySnapshot({
    required this.downloading,
    required this.queued,
    required this.playing,
  });

  static const empty =
      ActivitySnapshot(downloading: [], queued: [], playing: []);

  final List<ActivityItem> downloading;
  final List<ActivityItem> queued;
  final List<ActivityItem> playing;

  int get total => downloading.length + queued.length + playing.length;

  /// True when nothing is happening — the activity pill hides entirely.
  bool get isIdle => total == 0;

  List<ActivityItem> get all => [...downloading, ...queued, ...playing];

  /// Mean progress across running downloads, or null when none are running.
  double? get meanDownloadProgress {
    if (downloading.isEmpty) return null;
    final known = downloading.map((d) => d.progress ?? 0.0).toList();
    return known.reduce((a, b) => a + b) / known.length;
  }
}

/// Builds the snapshot the pill, its popover and the Library live rows all read.
///
/// [startedIds] is the set of ids with a live yt-dlp process — the single
/// source of truth that separates "downloading" from "queued". A VOD that is
/// both downloading and playing yields two items with distinct [ActivityItem.logKey]s,
/// which is correct: they are two processes.
ActivitySnapshot buildActivitySnapshot({
  required Iterable<String> downloadTaskIds,
  required List<String> downloadQueue,
  required Set<String> startedIds,
  required Map<String, String> downloadTitles,
  required Map<String, double> downloadProgress,
  required Map<String, String> downloadStatuses,
  required Set<String> playingVodIds,
  required Set<String> runningChannels,
  required Map<String, String> vodTitles,
}) {
  final split = splitDownloadIds(
    taskIds: downloadTaskIds,
    queueIds: downloadQueue,
    startedIds: startedIds,
  );

  String titleFor(String id) => downloadTitles[id] ?? 'VOD $id';

  final downloading = [
    for (final id in split.active)
      ActivityItem(
        kind: ActivityKind.downloading,
        id: id,
        label: titleFor(id),
        progress: downloadProgress[id],
        status: downloadStatuses[id],
      ),
  ];

  final queued = [
    for (final id in split.queued)
      ActivityItem(
        kind: ActivityKind.queued,
        id: id,
        label: titleFor(id),
        status: downloadStatuses[id],
      ),
  ];

  final playing = <ActivityItem>[
    for (final channel in runningChannels)
      ActivityItem(
        kind: ActivityKind.liveStream,
        id: channel,
        label: channel,
      ),
    for (final vodId in playingVodIds)
      ActivityItem(
        kind: ActivityKind.playingVod,
        id: vodId,
        label: vodTitles[vodId] ?? 'VOD $vodId',
      ),
  ];

  return ActivitySnapshot(
    downloading: downloading,
    queued: queued,
    playing: playing,
  );
}

/// Whether a player exiting deserves a failure message.
///
/// Stopping playback deliberately kills the process, which on Windows means
/// taskkill and a non-zero exit code — identical to a crash from the outside.
/// Reporting that as "playback failed" told the user their own click had
/// broken something. The same trap already bit downloads once, which is why
/// PlayerService tracks cancelled downloads; players now do the same.
bool shouldReportPlaybackFailure({
  required int exitCode,
  required bool userInitiated,
}) {
  if (userInitiated) return false;
  return exitCode != 0;
}

/// Whether a download progress tick is worth a full-app rebuild.
///
/// `onDownloadProgress` fires several times a second per download and used to
/// call `setState` on the whole main screen every time — rebuilding the
/// sidebar and every VOD card along with it. Nothing on screen resolves finer
/// than a whole percent, so ticks are collapsed to percent buckets. Status
/// changes always pass, because they carry non-numeric transitions like
/// "Queued" -> "Starting..." -> "Finalizing file...".
bool progressTickIsVisible({
  required int? previousBucket,
  required double progress,
  required String? previousStatus,
  required String? status,
}) {
  if (previousBucket == null) return true; // first sample for this download
  if (status != previousStatus) return true;
  return (progress * 100).floor() != previousBucket;
}
