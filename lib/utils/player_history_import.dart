/// Recovering watch positions from the player's own history.
///
/// The app is not the only thing that remembers where you were. MPC-HC keeps a
/// `MediaHistory` of its own — the media's URL and a `FilePosition` in
/// milliseconds — and that history survives episodes where the app's copy did
/// not: a crash, a force-kill, or (until it was fixed) a piping session that
/// wrote a relative clock over an absolute one.
///
/// The URLs are usable as identity. A Twitch VOD's CDN path is shaped
///
///   `<hash>_<channel>_<streamid>_<unixtime>/<quality>/index-dvr.m3u8`
///
/// and the trailing number is the broadcast's start time. Checked against real
/// data: 1789028629 → 2026-09-10 and 1788942604 → 2026-09-09, matching the ages
/// the app displayed for those VODs. So an entry can be tied to a VOD by
/// channel plus published time, without the app ever having recorded the URL.
///
/// Pure and IO-free: reading the registry belongs to the caller, and the part
/// worth testing is the parsing and the matching.
library;

/// One entry from a player's history.
class PlayerHistoryEntry {
  const PlayerHistoryEntry({
    required this.url,
    required this.positionSeconds,
    this.lastOpened,
  });

  final String url;
  final int positionSeconds;
  final DateTime? lastOpened;
}

/// What a Twitch CDN URL says about itself.
class CdnIdentity {
  const CdnIdentity({required this.channel, required this.startedAt});

  final String channel;
  final DateTime startedAt;
}

/// Pulls the channel and broadcast time out of a Twitch CDN media URL.
///
/// Returns null for anything that is not one — the history is full of local
/// files and unrelated media, and guessing at those would invent positions.
CdnIdentity? identifyCdnUrl(String url) {
  if (!url.contains('cloudfront.net') && !url.contains('.ttvnw.net')) {
    return null;
  }
  // The segment directly after the host, e.g.
  // f589ea12f111f2824e39_limmy_316000806994_1789028629
  final match = RegExp(r'/([0-9a-f]{8,}_[A-Za-z0-9_]+?_\d+_(\d{9,11}))/')
      .firstMatch(url);
  if (match == null) return null;

  final whole = match.group(1)!;
  final epoch = int.tryParse(match.group(2)!);
  if (epoch == null) return null;

  // channel is everything between the leading hash and the last two numbers.
  final parts = whole.split('_');
  if (parts.length < 4) return null;
  final channel = parts.sublist(1, parts.length - 2).join('_');
  if (channel.isEmpty) return null;

  return CdnIdentity(
    channel: channel.toLowerCase(),
    startedAt: DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true),
  );
}

/// A VOD the app knows about, reduced to what matching needs.
class VodIdentity {
  const VodIdentity({
    required this.id,
    required this.channel,
    required this.publishedAt,
    required this.durationSeconds,
  });

  final String id;
  final String channel;
  final DateTime publishedAt;
  final int durationSeconds;
}

/// How far apart a CDN timestamp and a VOD's published time may be and still
/// be the same broadcast.
///
/// Twitch's `published_at` and the CDN path's start time describe the same
/// event but are not written by the same system, so they can differ by a
/// little. Ten minutes is far tighter than the gap between two streams.
const Duration kBroadcastMatchWindow = Duration(minutes: 10);

class RecoveredPosition {
  const RecoveredPosition({
    required this.vodId,
    required this.seconds,
    required this.url,
  });

  final String vodId;
  final int seconds;
  final String url;
}

/// Matches player history against known VODs.
///
/// Deliberately conservative: an entry that matches nothing, matches more than
/// one VOD, or claims a position past the VOD's duration is dropped rather than
/// guessed at. Restoring a position onto the wrong VOD would be worse than the
/// loss being repaired.
List<RecoveredPosition> matchHistoryToVods(
  List<PlayerHistoryEntry> history,
  List<VodIdentity> vods,
) {
  final out = <RecoveredPosition>[];
  for (final entry in history) {
    if (entry.positionSeconds <= 0) continue;
    final id = identifyCdnUrl(entry.url);
    if (id == null) continue;

    final candidates = vods.where((v) {
      if (v.channel.toLowerCase() != id.channel) return false;
      final delta = v.publishedAt.toUtc().difference(id.startedAt).abs();
      return delta <= kBroadcastMatchWindow;
    }).toList();

    if (candidates.length != 1) continue;
    final vod = candidates.first;
    if (vod.durationSeconds > 0 &&
        entry.positionSeconds > vod.durationSeconds + 60) {
      continue;
    }
    out.add(RecoveredPosition(
        vodId: vod.id, seconds: entry.positionSeconds, url: entry.url));
  }
  return out;
}
