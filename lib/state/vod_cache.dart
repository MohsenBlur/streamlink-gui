import '../models/twitch_video.dart';

/// Per-channel VOD lists, cached so switching back to a channel is instant.
///
/// The class exists to make one invariant structural: **a caller never shares a
/// list with the cache**. Handing out the stored list is what made a single
/// `_channelVods.clear()` on channel switch empty the cache entry in place, so
/// every channel visited once was thereafter cached as "no past broadcasts" -
/// with no spinner, because a cache hit means there is nothing to load.
///
/// Copying on both store and read costs one shallow list copy per switch, over
/// at most a few dozen entries; the alternative is remembering to write
/// `List.from` at every call site forever.
///
/// Every entry also remembers when Twitch was asked for it. Entries used to be
/// timeless: the background prefetch skipped any channel that had one, so a
/// list fetched at startup was what that channel showed six hours later - and
/// when the fetch on opening it failed, it went on showing it with no sign
/// that it was old.
class VodCache {
  VodCache({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  /// How long an entry counts as current. Past this the prefetch fetches it
  /// again.
  ///
  /// Half an hour, not ten minutes: at ten the prefetch alone re-read up to
  /// ten favourites' lists every ten minutes, around the clock, for lists
  /// nobody had opened. A favourite whose broadcast starts or ends is
  /// fetched again regardless (VodBrowserController.prefetch), and opening a
  /// channel always fetches its first page.
  static const Duration ttl = Duration(minutes: 30);

  final DateTime Function() _now;
  final Map<String, _Entry> _byChannel = {};

  /// Whether anything is cached, however old.
  bool has(String username) => _byChannel.containsKey(_key(username));

  /// Whether an entry exists and is younger than [maxAge].
  bool isFresh(String username, {Duration maxAge = ttl}) {
    final at = fetchedAt(username);
    return at != null && _now().difference(at) < maxAge;
  }

  /// When the cached list was requested from Twitch, or null when nothing is
  /// cached.
  DateTime? fetchedAt(String username) => _byChannel[_key(username)]?.fetchedAt;

  /// A fresh list, or null when nothing is cached. Null and an empty list mean
  /// different things here: "never fetched" versus "fetched, and there are
  /// none".
  List<TwitchVideo>? read(String username) {
    final stored = _byChannel[_key(username)];
    return stored == null ? null : List<TwitchVideo>.from(stored.vods);
  }

  /// Stores [vods] as what Twitch said at [fetchedAt] (default: now).
  ///
  /// Refused, returning false, when the entry already holds the answer to a
  /// LATER request: two fetches for one channel can finish in either order,
  /// and the slower, older one must not overwrite the newer list.
  bool store(String username, Iterable<TwitchVideo> vods, {DateTime? fetchedAt}) {
    final key = _key(username);
    final at = fetchedAt ?? _now();
    final existing = _byChannel[key];
    if (existing != null && existing.fetchedAt.isAfter(at)) return false;
    _byChannel[key] = _Entry(List<TwitchVideo>.from(vods), at);
    return true;
  }

  void remove(String username) => _byChannel.remove(_key(username));

  void clear() => _byChannel.clear();

  int get length => _byChannel.length;

  // Twitch logins are case-insensitive, and channels reach this cache from the
  // API, the followed list and hand-typed input, which disagree about case.
  static String _key(String username) => username.trim().toLowerCase();
}

class _Entry {
  _Entry(this.vods, this.fetchedAt);

  final List<TwitchVideo> vods;
  final DateTime fetchedAt;
}
