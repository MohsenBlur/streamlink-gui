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
    this.presumedOffline = false,
  });

  ChannelSnapshot.of(TwitchChannel channel)
      : isLive = channel.isLive,
        streamId = channel.streamId,
        wentLiveTime = channel.wentLiveTime,
        observed = channel.lastUpdated != null,
        presumedOffline = isPresumedOffline(channel);

  final bool isLive;
  final String? streamId;
  final DateTime? wentLiveTime;

  /// Whether the channel had ever been refreshed successfully. A channel's
  /// first answer is a baseline, not an edge: it may have been live for hours.
  final bool observed;

  /// Offline only because its refreshes kept failing (see
  /// [isPresumedOffline]).
  final bool presumedOffline;
}

/// Whether [channel] shows offline only because its refreshes kept failing:
/// the service drops a live channel after several failures in a row, but
/// Twitch never said its broadcast ended. A refresh that answered clears the
/// error, so an offline channel still showing one was never answered.
bool isPresumedOffline(TwitchChannel channel) =>
    !channel.isLive && channel.errorMessage != null;

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
    this.knownBroadcasts = const {},
  });

  /// Channels to announce as live, in list order.
  final List<TwitchChannel> wentLive;

  /// Channels that were known to be live and no longer are.
  final List<TwitchChannel> wentOffline;

  /// The clean usernames now known to be live; pass it back next time.
  final Set<String> announced;

  /// The broadcast last known live on each clean username - its stream id, or
  /// '' when its refresh named none (DecAPI's) - while it is live or only
  /// presumed offline. Pass it back next time.
  final Map<String, String> knownBroadcasts;
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
///   live for hours;
/// - it is the broadcast [knownBroadcasts] already holds for it, which only
///   seemed to end because its refreshes kept failing.
///
/// An offline channel leaves the set. Nothing here reads a rate-limited
/// refresh as offline: the service leaves `isLive` alone for those. A failing
/// channel does drop, after several failures in a row, but Twitch never said
/// its broadcast ended. Forgetting that broadcast too announced it again - and
/// auto-played it again - as soon as requests worked: an outage of three
/// polls, a refused token signed in again, or a Wi-Fi drop during a few
/// presses of Refresh.
///
/// Only then. Once Twitch itself has said the channel is offline, its return
/// is announced, and auto-played, again - even on the same stream id, which
/// a stream that drops and reconnects can come back on. Kept across that
/// too, a reconnect came back silently and auto-play left it closed.
LiveTransitions detectLiveTransitions({
  required List<TwitchChannel> channels,
  required Map<TwitchChannel, ChannelSnapshot> before,
  required Set<String> announced,
  required bool isInitialLoad,
  Map<String, String> knownBroadcasts = const {},
}) {
  final next = Set<String>.of(announced);
  final known = Map<String, String>.of(knownBroadcasts);
  final wentLive = <TwitchChannel>[];
  final wentOffline = <TwitchChannel>[];
  for (final channel in channels) {
    final name = channel.username.toLowerCase().trim();
    if (channel.isLive) {
      final broadcast = channel.streamId ?? '';
      final seenBefore = known[name] == broadcast;
      known[name] = broadcast;
      if (next.add(name) &&
          !isInitialLoad &&
          !seenBefore &&
          (before[channel]?.observed ?? false)) {
        wentLive.add(channel);
      }
    } else {
      if (next.remove(name)) wentOffline.add(channel);
      // Twitch saying the channel is offline (an answer, so no error) ends
      // the broadcast it knew, stream id or none; failing refreshes do not.
      if (!isPresumedOffline(channel)) known.remove(name);
    }
  }
  return LiveTransitions(
    wentLive: wentLive,
    wentOffline: wentOffline,
    announced: next,
    knownBroadcasts: known,
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
/// and no stream id), which leaves whatever an earlier broadcast set - unless
/// that broadcast only seemed to end ([ChannelSnapshot.presumedOffline]):
/// with nothing to tell them apart it is still the same one, and a new start
/// time would make it a new auto-play session, launched again.
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
    final leftOver = channel.streamId == null &&
        channel.wentLiveTime == was.wentLiveTime &&
        !was.presumedOffline;
    if (unset || leftOver) channel.wentLiveTime = now;
  }
}
