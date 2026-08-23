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
class VodCache {
  final Map<String, List<TwitchVideo>> _byChannel = {};

  bool has(String username) => _byChannel.containsKey(_key(username));

  /// A fresh list, or null when nothing is cached. Null and an empty list mean
  /// different things here: "never fetched" versus "fetched, and there are
  /// none".
  List<TwitchVideo>? read(String username) {
    final stored = _byChannel[_key(username)];
    return stored == null ? null : List<TwitchVideo>.from(stored);
  }

  void store(String username, Iterable<TwitchVideo> vods) {
    _byChannel[_key(username)] = List<TwitchVideo>.from(vods);
  }

  void remove(String username) => _byChannel.remove(_key(username));

  void clear() => _byChannel.clear();

  int get length => _byChannel.length;

  // Twitch logins are case-insensitive, and channels reach this cache from the
  // API, the followed list and hand-typed input, which disagree about case.
  static String _key(String username) => username.trim().toLowerCase();
}
