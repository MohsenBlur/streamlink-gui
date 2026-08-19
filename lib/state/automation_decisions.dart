import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../models/twitch_video.dart';

/// Pure decision logic for the "Auto Download & Play" features.
///
/// Deliberately free of I/O and Flutter: every rule here previously lived inline
/// in a 3,400-line State class where it could not be exercised, and several of
/// the rules were silently inert as a result. Keeping the decisions pure means
/// they can be tested directly.

/// Why an auto-play pass produced no action. Surfaced for logging.
enum AutoPlaySkipReason {
  none,
  watchingVod,
  updateInProgress,
  stillLoadingLiveStatus,
  noPriorityChannels,
  nothingLive,
  higherPriorityActive,
  alreadyPlayedThisSession,
  alreadyRunning,
}

class AutoPlayDecision {
  const AutoPlayDecision({
    this.channelToPlay,
    this.sessionKey,
    this.channelsToPreempt = const [],
    this.reason = AutoPlaySkipReason.none,
    this.sessionKeyToRecord,
    this.sessionChannel,
  });

  /// The channel to launch, or null when nothing should start.
  final TwitchChannel? channelToPlay;

  /// Session key for [channelToPlay].
  final String? sessionKey;

  /// Lower-priority channels whose streams should be stopped first.
  final List<String> channelsToPreempt;

  /// Why nothing was launched.
  final AutoPlaySkipReason reason;

  /// Session key to remember even though nothing was launched (the stream is
  /// already running, so it must not be treated as new next tick).
  final String? sessionKeyToRecord;

  /// Lowercased channel the recorded session belongs to.
  ///
  /// Carried explicitly rather than letting the caller recover it by splitting
  /// the session key: that only round-trips for names free of the key's
  /// separators, and a name containing one would be recorded under a key the
  /// lookup can never match.
  final String? sessionChannel;

  bool get shouldLaunch => channelToPlay != null;
}

/// Identifies one continuous live session of a channel.
///
/// Must stay stable for the whole broadcast, otherwise "activate once per live
/// session" cannot work. This previously fell back to [TwitchChannel.uptime],
/// a human-readable string that includes seconds and therefore changed on every
/// poll - so closing the player caused the stream to be relaunched a minute
/// later, with a duplicate notification, for as long as the broadcast lasted.
///
/// [streamId] (Helix `stream.id`) is stable for a broadcast and is preferred.
/// [wentLiveTime] is the next best thing. The final fallback is the channel
/// name alone, which is stable but cannot distinguish consecutive broadcasts -
/// still far better than a value that changes every minute.
String buildSessionKey(TwitchChannel channel) {
  final name = channel.username.toLowerCase().trim();
  final streamId = channel.streamId;
  if (streamId != null && streamId.isNotEmpty) {
    return '$name#$streamId';
  }
  final wentLive = channel.wentLiveTime;
  if (wentLive != null) {
    return '$name@${wentLive.millisecondsSinceEpoch}';
  }
  return '$name#live';
}

/// Decides which favourite (if any) should be auto-played.
///
/// [runningChannels] are the lowercased names of channels already playing.
/// [playedSessions] maps a lowercased channel name to the session key that was
/// last auto-played for it.
AutoPlayDecision decideAutoPlay({
  required List<TwitchChannel> channels,
  required Set<String> runningChannels,
  required Map<String, String> playedSessions,
  required bool isWatchingVod,
  required bool isUpdateActive,
  required bool preemptLowerPriority,
}) {
  // Stand down while the user is watching a VOD or an update is in flight.
  if (isWatchingVod) {
    return const AutoPlayDecision(reason: AutoPlaySkipReason.watchingVod);
  }
  if (isUpdateActive) {
    return const AutoPlayDecision(reason: AutoPlaySkipReason.updateInProgress);
  }

  final priority = channels.where((c) => c.autoPlayLive).toList()
    ..sort((a, b) => a.autoPlayPriority.compareTo(b.autoPlayPriority));

  if (priority.isEmpty) {
    return const AutoPlayDecision(reason: AutoPlaySkipReason.noPriorityChannels);
  }

  // Every priority channel must have finished refreshing, or a lower-priority
  // channel could be launched before a higher-priority one is known to be live.
  if (priority.any((c) => c.isLoading)) {
    return const AutoPlayDecision(reason: AutoPlaySkipReason.stillLoadingLiveStatus);
  }

  for (var i = 0; i < priority.length; i++) {
    final candidate = priority[i];
    if (!candidate.isLive) continue;

    final cleanName = candidate.username.toLowerCase().trim();

    // A higher-priority channel that is live, or already playing, wins.
    final higherActive = priority.take(i).any(
          (c) => c.isLive || runningChannels.contains(c.username.toLowerCase().trim()),
        );
    if (higherActive) {
      return const AutoPlayDecision(reason: AutoPlaySkipReason.higherPriorityActive);
    }

    final sessionKey = buildSessionKey(candidate);

    if (playedSessions[cleanName] == sessionKey) {
      return AutoPlayDecision(
        reason: AutoPlaySkipReason.alreadyPlayedThisSession,
        sessionKey: sessionKey,
      );
    }

    final toPreempt = <String>[];
    if (preemptLowerPriority) {
      for (var k = i + 1; k < priority.length; k++) {
        final lower = priority[k].username.toLowerCase().trim();
        if (runningChannels.contains(lower)) toPreempt.add(lower);
      }
    }

    if (runningChannels.contains(cleanName)) {
      // Already playing: remember the session so closing the player does not
      // cause a relaunch on the next tick. Preemption still applies - the
      // whole point is that only the highest-priority stream should be
      // playing, and returning early here left lower-priority streams running
      // whenever the top one happened to start first.
      return AutoPlayDecision(
        reason: AutoPlaySkipReason.alreadyRunning,
        sessionKey: sessionKey,
        sessionKeyToRecord: sessionKey,
        sessionChannel: cleanName,
        channelsToPreempt: toPreempt,
      );
    }

    return AutoPlayDecision(
      channelToPlay: candidate,
      sessionKey: sessionKey,
      channelsToPreempt: toPreempt,
    );
  }

  return const AutoPlayDecision(reason: AutoPlaySkipReason.nothingLive);
}

/// Chooses which of a channel's VODs should be auto-downloaded.
///
/// [vods] is expected newest-first, as the Twitch API returns them.
/// The result is oldest-first so the user can watch in chronological order.
List<TwitchVideo> selectVodsToAutoDownload({
  required TwitchChannel channel,
  required List<TwitchVideo> vods,
  required Map<String, int> localProgress,
  required AppSettings settings,
  required bool Function(String vodId) isAlreadyHandled,
}) {
  // The exclusion threshold is the user-facing control, so it governs.
  //
  // These two rules used to be evaluated the other way round: the per-channel
  // "stop at last watched (>5%)" break ran first, so every surviving VOD had
  // progress <= 5% and therefore always passed the threshold test. With the
  // per-channel option enabled - its default - dragging the exclusion slider
  // changed nothing at all.
  final thresholdFraction = settings.vodWatchExclusionThreshold.clamp(5, 90) / 100.0;

  double progressOf(TwitchVideo vod) {
    final local = localProgress[vod.id];
    if (local != null && local > 0) {
      final total = parseDurationSeconds(vod.duration);
      if (total > 0) return local / total;
    }
    return vod.watchProgress ?? 0.0;
  }

  final candidates = <TwitchVideo>[];
  for (final vod in vods) {
    final progress = progressOf(vod);

    // Walking newest-first, the first VOD the user has already started marks
    // where they left off; everything older has presumably been seen.
    if (channel.stopAtLastWatchedVod && progress > thresholdFraction) {
      break;
    }
    if (progress < thresholdFraction) {
      candidates.add(vod);
    }
  }

  candidates.sort((a, b) => a.publishedAt.compareTo(b.publishedAt));

  // "Keep Max VODs" caps the WINDOW of VODs this channel maintains, not how
  // many are fetched per pass.
  //
  // Take the oldest N first and only then drop the ones already downloaded or
  // in flight. Filling the quota with unhandled VODs instead would make it a
  // per-pass download quota: once the oldest N were on disk the pass would keep
  // walking further down the list and pull in N more, and so on until the whole
  // channel history had been downloaded.
  final keep = channel.maxVodKeepCount.clamp(1, 5);
  final window = candidates.take(keep);
  return window.where((vod) => !isAlreadyHandled(vod.id)).toList();
}

/// Parses Twitch's duration format ("1h2m3s") into seconds.
int parseDurationSeconds(String duration) {
  int part(String suffix) {
    final match = RegExp(r'(\d+)' + suffix).firstMatch(duration);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  return part('h') * 3600 + part('m') * 60 + part('s');
}
