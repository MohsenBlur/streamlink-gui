import '../models/twitch_video.dart';

/// Pure list logic for keeping a channel's VOD grid current without
/// re-selecting it.
///
/// The grid used to be fetched only when a channel was selected, so the only
/// way to see a VOD that appeared - or an in-progress one's duration grow -
/// was to click another channel and back. Refreshing by REPLACING the list is
/// not an answer either: it drops the pages loaded with "Load more" and the
/// cursor that continues them. So a refreshed first page is merged in by id.

/// What [mergeFirstPage] produced.
class VodMerge {
  const VodMerge({
    required this.vods,
    required this.cursor,
    required this.added,
    required this.changed,
  });

  /// The list to show.
  final List<TwitchVideo> vods;

  /// The "Load more" cursor that continues [vods].
  final String? cursor;

  /// Entries that were not in the list before, in the fresh page's order
  /// (newest first).
  final List<TwitchVideo> added;

  /// Whether anything a viewer could see differs from the list before.
  final bool changed;
}

/// Merges a freshly fetched first page ([fresh], continued by [freshCursor])
/// into [current], the list on screen.
///
/// - A VOD new to the list appears in its place at the top.
/// - A VOD already shown takes the fresh entry: its title, duration (an
///   in-progress broadcast's grows), thumbnail and view count can all change.
///   What the fresh entry lacks is carried over - games, which a fetch that
///   skipped the per-VOD lookup does not have, and a watch position.
/// - With [hasLoadedMore], the pages the user loaded below the first stay,
///   and so does [currentCursor], which continues after them. Without it the
///   list is the first page alone, so the fresh cursor takes over.
/// - A VOD missing from the fresh page although it is newer than the page's
///   oldest entry was deleted on Twitch, and goes. One older than that may
///   simply have been pushed onto page two by a new one, and stays - unless
///   the fresh page is the whole archive (no cursor), which settles it.
VodMerge mergeFirstPage({
  required List<TwitchVideo> current,
  required String? currentCursor,
  required bool hasLoadedMore,
  required List<TwitchVideo> fresh,
  required String? freshCursor,
}) {
  final previous = {for (final v in current) v.id: v};
  final merged = <TwitchVideo>[];
  final added = <TwitchVideo>[];
  final placed = <String>{};

  for (final incoming in fresh) {
    if (!placed.add(incoming.id)) continue;
    final old = previous[incoming.id];
    if (old == null) {
      added.add(incoming);
    } else {
      _carryOver(from: old, to: incoming);
    }
    merged.add(incoming);
  }

  final freshIsWholeArchive = freshCursor == null || freshCursor.isEmpty;
  String? cursor;
  if (!hasLoadedMore) {
    cursor = freshCursor;
  } else if (freshIsWholeArchive) {
    cursor = null;
  } else {
    final oldestFresh = _oldest(fresh);
    for (final v in current) {
      if (placed.contains(v.id)) continue;
      if (oldestFresh != null && !v.publishedAt.isBefore(oldestFresh)) continue;
      placed.add(v.id);
      merged.add(v);
    }
    cursor = currentCursor;
  }

  return VodMerge(
    vods: merged,
    cursor: cursor,
    added: added,
    changed: cursor != currentCursor || !sameVodLists(current, merged),
  );
}

/// [current] followed by the entries of [page] it does not already hold.
///
/// Pages are fetched by cursor, and a VOD published between two requests
/// shifts every later page by one, so the next page can repeat the last entry
/// of the one before. Appending it blindly showed that VOD twice.
List<TwitchVideo> appendVodPage(List<TwitchVideo> current, List<TwitchVideo> page) {
  final seen = {for (final v in current) v.id};
  return [
    ...current,
    for (final v in page)
      if (seen.add(v.id)) v,
  ];
}

/// Whether two lists would look the same in the grid.
bool sameVodLists(List<TwitchVideo> a, List<TwitchVideo> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (identical(x, y)) continue;
    if (x.id != y.id ||
        x.title != y.title ||
        x.duration != y.duration ||
        x.thumbnailUrl != y.thumbnailUrl ||
        x.viewCount != y.viewCount ||
        x.watchPosition != y.watchPosition ||
        !_sameStrings(x.games, y.games)) {
      return false;
    }
  }
  return true;
}

void _carryOver({required TwitchVideo from, required TwitchVideo to}) {
  if (to.games.isEmpty && from.games.isNotEmpty) to.games = from.games;
  if (to.watchPosition == null && from.watchPosition != null) {
    to.watchPosition = from.watchPosition;
    to.watchProgress = from.watchProgress;
  }
}

DateTime? _oldest(List<TwitchVideo> vods) {
  DateTime? oldest;
  for (final v in vods) {
    if (oldest == null || v.publishedAt.isBefore(oldest)) oldest = v.publishedAt;
  }
  return oldest;
}

bool _sameStrings(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Recognises a VOD that has just become available, from successive first
/// pages of a channel's archive.
///
/// "New" means FINISHED and not seen before. A broadcast's archive exists from
/// the moment it starts, so while the channel is live its newest VOD is the
/// broadcast still in progress - which the went-live notification already
/// announced. That one counts once the stream has ended and it shows up in a
/// page fetched with the channel offline.
///
/// The first page ever seen for a channel is a baseline and announces
/// nothing, so opening the app does not report a channel's whole archive -
/// unless [observe] is told which broadcast it is looking for
/// (`endedBroadcastStart`), which is how a stream that ended during this
/// session is announced even for a channel whose list was never fetched.
///
/// Only entries newer than everything already known can be new: a VOD
/// deleted from the first page pulls an older one up into it, and that one is
/// not news.
class NewVodDetector {
  /// How far before the broadcast's own start time its archive may be dated.
  /// Twitch stamps the archive within seconds of `started_at`; this leaves
  /// room for clock skew and a reconnect.
  static const Duration archiveSlack = Duration(minutes: 10);

  final Map<String, _Seen> _seen = {};

  /// Feeds in a first page for [username], newest first. Returns the VODs that
  /// became available since the last one, newest first.
  ///
  /// [isLive] and [liveSince] describe the channel as the page was fetched:
  /// while it is live, entries dated from [liveSince] on (or the newest entry
  /// when the start is unknown) are the broadcast in progress.
  List<TwitchVideo> observe(
    String username,
    List<TwitchVideo> firstPage, {
    required bool isLive,
    DateTime? liveSince,
    DateTime? endedBroadcastStart,
  }) {
    final key = username.trim().toLowerCase();
    final finished = <TwitchVideo>[
      for (var i = 0; i < firstPage.length; i++)
        if (!_inProgress(firstPage, i, isLive: isLive, liveSince: liveSince))
          firstPage[i],
    ];

    final seen = _seen[key];
    final List<TwitchVideo> fresh;
    if (seen == null) {
      final since = endedBroadcastStart?.subtract(archiveSlack);
      fresh = since == null
          ? const <TwitchVideo>[]
          : [
              for (final v in finished)
                if (!v.publishedAt.isBefore(since)) v,
            ];
    } else {
      fresh = [
        for (final v in finished)
          if (!seen.ids.contains(v.id) &&
              (seen.newest == null || v.publishedAt.isAfter(seen.newest!)))
            v,
      ];
    }

    final record = _seen[key] ??= _Seen();
    for (final v in finished) {
      record.ids.add(v.id);
      if (record.newest == null || v.publishedAt.isAfter(record.newest!)) {
        record.newest = v.publishedAt;
      }
    }
    return fresh;
  }

  /// Whether anything has been observed for [username].
  bool knows(String username) => _seen.containsKey(username.trim().toLowerCase());

  void forget(String username) => _seen.remove(username.trim().toLowerCase());

  static bool _inProgress(
    List<TwitchVideo> page,
    int index, {
    required bool isLive,
    DateTime? liveSince,
  }) {
    if (!isLive) return false;
    if (liveSince == null) return index == 0;
    return !page[index].publishedAt.isBefore(liveSince.subtract(archiveSlack));
  }
}

class _Seen {
  final Set<String> ids = <String>{};
  DateTime? newest;
}
