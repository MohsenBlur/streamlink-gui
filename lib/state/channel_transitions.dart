import '../models/twitch_channel.dart';

/// Pure went-live / went-offline logic for the channel poll.
///
/// It lived inline in `_refreshAllChannels`, next to the toasts and the
/// automation it fed, where no test could reach it - and a regression in it
/// silently breaks notifications and auto-play.

/// What a channel looked like before a refresh pass touched it.
class ChannelSnapshot {
  const ChannelSnapshot({
    required this.isLive,
    required this.streamId,
    required this.wentLiveTime,
    required this.observed,
  });

  ChannelSnapshot.of(TwitchChannel channel)
      : isLive = channel.isLive,
        streamId = channel.streamId,
        wentLiveTime = channel.wentLiveTime,
        observed = channel.lastUpdated != null;

  final bool isLive;
  final String? streamId;
  final DateTime? wentLiveTime;

  /// Whether the channel had ever been refreshed successfully. A channel's
  /// first answer is a baseline, not an edge: it may have been live for hours.
  final bool observed;
}

/// Snapshots keyed by identity: TwitchChannel has no value equality, and the
/// favourite and the followed-list object for one streamer are two channels.
Map<TwitchChannel, ChannelSnapshot> snapshotChannels(
        Iterable<TwitchChannel> channels) =>
    Map<TwitchChannel, ChannelSnapshot>.identity()
      ..addEntries(channels.map((c) => MapEntry(c, ChannelSnapshot.of(c))));

/// The result of [detectLiveTransitions].
class LiveTransitions {
  const LiveTransitions({
    required this.wentLive,
    required this.wentOffline,
    required this.announced,
  });

  /// Channels to announce as live, in list order.
  final List<TwitchChannel> wentLive;

  /// Channels that were known to be live and no longer are.
  final List<TwitchChannel> wentOffline;

  /// The clean usernames now known to be live; pass it back next time.
  final Set<String> announced;
}

/// Who just went live, and who just went offline.
///
/// [announced] holds the clean usernames already known to be live. That set,
/// not a before/after comparison, decides what is announced, so a broadcast is
/// announced once however its state was learned (the poll, a selection's
/// refresh, an add). A live channel missing from it joins it, and is
/// announced unless:
/// - [isInitialLoad]: the first pass of a session reports what was already
///   live when the app started, which is not news;
/// - the channel had never been refreshed before this pass ([before] says it
///   was not observed): a new follow, or one only just added, may have been
///   live for hours.
///
/// An offline channel leaves the set. Nothing here reads a failed or
/// rate-limited refresh as offline: the service leaves `isLive` alone for
/// those (a failing channel only drops after several in a row).
LiveTransitions detectLiveTransitions({
  required List<TwitchChannel> channels,
  required Map<TwitchChannel, ChannelSnapshot> before,
  required Set<String> announced,
  required bool isInitialLoad,
}) {
  final next = Set<String>.of(announced);
  final wentLive = <TwitchChannel>[];
  final wentOffline = <TwitchChannel>[];
  for (final channel in channels) {
    final name = channel.username.toLowerCase().trim();
    if (channel.isLive) {
      if (next.add(name) &&
          !isInitialLoad &&
          (before[channel]?.observed ?? false)) {
        wentLive.add(channel);
      }
    } else if (next.remove(name)) {
      wentOffline.add(channel);
    }
  }
  return LiveTransitions(
    wentLive: wentLive,
    wentOffline: wentOffline,
    announced: next,
  );
}

/// Whether [channel]'s broadcast changed since [before]: it went live, went
/// offline, or a new broadcast replaced the old one. Each of those changes
/// what is in its archive. A channel seen for the first time has changed
/// nothing anyone saw.
bool broadcastChanged(ChannelSnapshot? before, TwitchChannel channel) {
  if (before == null || !before.observed) return false;
  return before.isLive != channel.isLive || before.streamId != channel.streamId;
}

/// Gives a channel that has just gone live a start time when its refresh did
/// not supply one.
///
/// Helix's `started_at` is the broadcast's own start, so it is kept: the old
/// code overwrote it with the poll's clock on every offline-to-live edge,
/// which put "live for" and the newly-live highlight up to a minute late, and
/// far later after the PC woke from sleep into a stream already an hour old.
/// Only when nothing better exists is the moment the edge was seen the best
/// estimate: no start time at all, or DecAPI's answer (it has no start time
/// and no stream id), which leaves whatever an earlier broadcast set.
void applyWentLiveFallback(
  Iterable<TwitchChannel> channels,
  Map<TwitchChannel, ChannelSnapshot> before, {
  required bool isInitialLoad,
  required DateTime now,
}) {
  if (isInitialLoad) return;
  for (final channel in channels) {
    final was = before[channel];
    if (was == null || was.isLive || !channel.isLive) continue;
    final unset = channel.wentLiveTime == null;
    final leftOver =
        channel.streamId == null && channel.wentLiveTime == was.wentLiveTime;
    if (unset || leftOver) channel.wentLiveTime = now;
  }
}
