/// Pure classification of download ids for the Downloads Manager view.
///
/// The raw service state double-lists downloads in both directions:
/// - `queueVodDownload` writes `activeDownloadTasks[id] = 'Queued'` at queue
///   time, so queued items used to render under "Active Downloads".
/// - The running id stays at the head of `downloadQueue` until it finishes,
///   so the active download used to render under "Queue List" too.
///
/// The single source of truth for "actually running" is
/// `activeDownloadProcesses` (a yt-dlp process exists). Everything else that
/// is tracked is queued.
class DownloadIdSplit {
  const DownloadIdSplit({required this.active, required this.queued});

  /// Ids with a live download process, in task-map order.
  final List<String> active;

  /// Ids waiting in the queue (no process yet), in queue order.
  final List<String> queued;
}

DownloadIdSplit splitDownloadIds({
  required Iterable<String> taskIds,
  required List<String> queueIds,
  required Set<String> startedIds,
}) {
  final active = <String>[];
  final queued = <String>[];
  final seen = <String>{};

  for (final id in taskIds) {
    if (!seen.add(id)) continue;
    if (startedIds.contains(id)) {
      active.add(id);
    } else {
      queued.add(id);
    }
  }

  // Defensive: a queued id should always have a task entry, but if it does
  // not, it must still be visible somewhere.
  for (final id in queueIds) {
    if (!seen.add(id)) continue;
    if (startedIds.contains(id)) {
      active.add(id);
    } else {
      queued.add(id);
    }
  }

  // Keep the queue's own ordering for the queued section: the queue list is
  // what actually drains, so its order is the truth.
  queued.sort((a, b) {
    final ia = queueIds.indexOf(a);
    final ib = queueIds.indexOf(b);
    if (ia == -1 && ib == -1) return 0;
    if (ia == -1) return 1;
    if (ib == -1) return -1;
    return ia.compareTo(ib);
  });

  return DownloadIdSplit(active: active, queued: queued);
}
