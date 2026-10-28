/// Every VOD the app has downloaded, by id, with when it first did: what
/// keeps the auto-download pass from fetching a VOD a second time.
///
/// Nothing else remembers a download once its file is gone. The registry
/// drops the entry, and since deleting a VOD takes its line out of yt-dlp's
/// archive too, yt-dlp no longer skips it either. Two loops followed. With
/// retention (keep at most N downloads) set below the auto-download windows,
/// retention deleted a VOD still inside its window, the pass found it not
/// downloaded and fetched it again, and retention deleted the next one,
/// every pass. And a VOD the user deleted while it was still unwatched in its
/// window came straight back a minute later.
///
/// This record outlives the file, the registry entry and the archive line.
/// Only the pass reads it: a download queued by hand goes ahead, which is
/// how a VOD deleted on purpose is brought back.
///
/// A VOD whose download the user cancelled is recorded too. Nothing else
/// remembered the cancel either, so the pass queued that VOD again a minute
/// later. Recorded, it holds its place in its window like one downloaded
/// and deleted.
class DownloadHistory {
  /// How long an id is kept. The pass reads past broadcasts only, which
  /// Twitch deletes after 60 days at the most, and a VOD is downloaded after
  /// it was published - so an id older than this cannot be on any list the
  /// pass reads again.
  static const Duration keepFor = Duration(days: 90);

  /// The most ids kept, the oldest dropped first: more than [keepFor] holds
  /// for anyone short of twenty downloads a day, and few enough to keep the
  /// config small.
  static const int maxEntries = 2000;

  /// Id to when it was first downloaded, in milliseconds since the epoch.
  final Map<String, int> _firstDownloadedMs = <String, int>{};

  /// Whether [vodId] was downloaded before, whether or not it still is.
  bool contains(String vodId) => _firstDownloadedMs.containsKey(vodId);

  int get length => _firstDownloadedMs.length;

  /// Notes that [vodId] was downloaded at [now]. One already noted keeps its
  /// first time. Returns whether anything changed, which is what wants
  /// saving.
  bool record(String vodId, DateTime now) => addAll([vodId], now);

  /// [record] for each of [vodIds].
  bool addAll(Iterable<String> vodIds, DateTime now) =>
      _add(vodIds, now.millisecondsSinceEpoch, now);

  /// [addAll] for ids worth less than every one already held: each is
  /// stamped a millisecond before the oldest held (or before [now]), so past
  /// [maxEntries] these go first, in the order they came.
  ///
  /// For the seed from yt-dlp's archive. It is read after the registry's
  /// seed ([restore]), and maybe after the scan has found files on disk, and
  /// stamped later than either it outranked them: past the cap, VODs the
  /// app still had a file or a registry entry for were dropped before
  /// archive lines from builds long gone.
  bool addBeneath(Iterable<String> vodIds, DateTime now) {
    var oldest = now.millisecondsSinceEpoch;
    for (final at in _firstDownloadedMs.values) {
      if (at < oldest) oldest = at;
    }
    return _add(vodIds, oldest - 1, now);
  }

  bool _add(Iterable<String> vodIds, int at, DateTime now) {
    final before = _firstDownloadedMs.length;
    for (final id in vodIds) {
      if (id.isEmpty) continue;
      _firstDownloadedMs.putIfAbsent(id, () => at);
    }
    final added = _firstDownloadedMs.length != before;
    return _prune(now) || added;
  }

  /// Takes the record the config held ([toJson]); with none - a config
  /// written before this record existed - starts from [seed], every VOD
  /// the app still knows it downloaded, as of [now]. Without the seed the
  /// first upgrade would treat all of them as never downloaded, and fetch
  /// each again the first time retention or the user deleted it.
  void restore(Map<String, int>? saved,
      {required Iterable<String> seed, required DateTime now}) {
    _firstDownloadedMs.clear();
    if (saved == null) {
      addAll(seed, now);
      return;
    }
    _firstDownloadedMs.addAll(saved);
    _prune(now);
  }

  /// What the config keeps.
  Map<String, int> toJson() => Map<String, int>.of(_firstDownloadedMs);

  bool _prune(DateTime now) {
    final before = _firstDownloadedMs.length;
    final oldest = now.subtract(keepFor).millisecondsSinceEpoch;
    _firstDownloadedMs.removeWhere((_, at) => at < oldest);
    if (_firstDownloadedMs.length > maxEntries) {
      // Oldest first; ids noted at the same moment (a seed) in the order
      // they came, which for yt-dlp's archive is the order of download.
      final byAge = _firstDownloadedMs.entries.toList();
      final order = {for (var i = 0; i < byAge.length; i++) byAge[i].key: i};
      byAge.sort((a, b) {
        final byTime = a.value.compareTo(b.value);
        return byTime != 0 ? byTime : order[a.key]!.compareTo(order[b.key]!);
      });
      for (final entry in byAge.take(_firstDownloadedMs.length - maxEntries)) {
        _firstDownloadedMs.remove(entry.key);
      }
    }
    return _firstDownloadedMs.length != before;
  }
}
