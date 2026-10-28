import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../models/twitch_video.dart';
import '../state/automation_decisions.dart';
import 'twitch_api_service.dart' show VodsFetchResult;

/// Runs the favourites automation: auto-play of the highest-priority live
/// favourite, and auto-download of its new VODs.
///
/// The rules themselves are pure and live in automation_decisions.dart. This
/// is everything around them that used to sit inline in the main screen: one
/// pass at a time, the memory of which broadcast was already auto-played,
/// and carrying out what the decisions call for. Everything it reads or
/// does outside itself comes in through the constructor as a function, so a
/// whole pass can run in a test against fakes - and so the settings and
/// lists are read when they are used, never captured, exactly as the inline
/// code read the screen's fields.
class AutomationService {
  AutomationService({
    required this.favorites,
    required this.settings,
    required this.runningChannels,
    required this.isWatchingVod,
    required this.isUpdateActive,
    required this.playLive,
    required this.stopLive,
    required this.fetchVods,
    required this.localProgress,
    required this.isVodHandled,
    required this.queueDownload,
    required this.showNotification,
    this.onVodsFetched,
    void Function(String message)? log,
  }) : _log = log ?? print;

  /// The favourites, in the user's order.
  final List<TwitchChannel> Function() favorites;

  final AppSettings Function() settings;

  /// Channels with a live player open, in any case.
  final Iterable<String> Function() runningChannels;

  /// True while a VOD is being watched, so auto-play stands down.
  final bool Function() isWatchingVod;

  /// True while an update is offered or being installed.
  final bool Function() isUpdateActive;

  final void Function(TwitchChannel channel) playLive;

  /// Stops the live player of [channel] (lowercased).
  final void Function(String channel) stopLive;

  /// One page of [channel]'s VODs, newest first. The pass renders nothing,
  /// so the app fetches these without per-VOD game names.
  final Future<VodsFetchResult> Function(TwitchChannel channel) fetchVods;

  /// Locally recorded watch positions by VOD id, in seconds.
  final Map<String, int> Function() localProgress;

  /// Whether a VOD is already downloaded, downloading or queued.
  final bool Function(String vodId) isVodHandled;

  final void Function(TwitchVideo vod, TwitchChannel channel,
      {bool? overrideDisablePostProcessing}) queueDownload;

  final Future<void> Function(String title, String body) showNotification;

  /// HOOK for whoever caches VOD lists: called with every list the
  /// auto-download pass fetched, empty ones included, before anything is
  /// queued from it. Lists come from [fetchVods], so they carry no game
  /// names. A throw here is logged and does not stop the pass. Unset, the
  /// lists are used for the pass and dropped, as before.
  void Function(TwitchChannel channel, VodsFetchResult result)? onVodsFetched;

  final void Function(String message) _log;

  /// Lowercased channel -> the session key last auto-played for it.
  final Map<String, String> _playedSessions = {};

  bool _passRunning = false;

  /// True while [runPass] is running.
  bool get isPassRunning => _passRunning;

  /// What has been auto-played this broadcast, by lowercased channel.
  Map<String, String> get playedSessions => Map.unmodifiable(_playedSessions);

  /// Forgets [channel]'s auto-played session, so a channel removed from the
  /// favourites cannot resurface as one later.
  void forgetChannel(String channel) =>
      _playedSessions.remove(channel.toLowerCase().trim());

  /// One automation pass: auto-play, then auto-download.
  ///
  /// A call while a pass is still running does nothing. The 60s timer can
  /// fire again while a pass is still awaiting VOD lists, and overlapping
  /// passes each queued the same downloads.
  Future<void> runPass() async {
    if (_passRunning) return;
    _passRunning = true;
    try {
      await _runAutoPlayPass();
      await _runAutoDownloadPass();
    } finally {
      _passRunning = false;
    }
  }

  Future<void> _runAutoPlayPass() async {
    final channels = favorites();

    // Forget sessions for channels that are no longer live, so the next
    // broadcast is treated as new.
    final liveNames = channels
        .where((c) => c.isLive)
        .map((c) => c.username.toLowerCase().trim())
        .toSet();
    _playedSessions.removeWhere((name, _) => !liveNames.contains(name));

    final decision = decideAutoPlay(
      channels: channels,
      runningChannels:
          runningChannels().map((c) => c.toLowerCase().trim()).toSet(),
      playedSessions: _playedSessions,
      isWatchingVod: isWatchingVod(),
      isUpdateActive: isUpdateActive(),
      preemptLowerPriority: settings().autoPlayPreemptLowerPriority,
    );

    if (decision.sessionChannel != null &&
        decision.sessionKeyToRecord != null) {
      _playedSessions[decision.sessionChannel!] = decision.sessionKeyToRecord!;
    }

    // Applied before the early return: the highest-priority stream may already
    // be running, and lower-priority ones still need stopping in that case.
    for (final lower in decision.channelsToPreempt) {
      _log('[Auto-Play] Preempting lower priority stream @$lower');
      stopLive(lower);
    }

    if (!decision.shouldLaunch) {
      if (decision.reason != AutoPlaySkipReason.none) {
        _log('[Auto-Play] No action: ${decision.reason.name}');
      }
      return;
    }

    final target = decision.channelToPlay!;
    final cleanName = target.username.toLowerCase().trim();

    _playedSessions[cleanName] = decision.sessionKey!;
    _log('[Auto-Play] Launching @${target.username} (session ${decision.sessionKey})');

    playLive(target);

    if (settings().notifyAutoPlay) {
      try {
        await showNotification(
          'Auto-Playing Live Stream',
          '${target.username} is now live\nPlaying ${target.game ?? "Twitch"}',
        );
      } catch (e) {
        _log('[Auto-Play Notification Error]: $e');
      }
    }
  }

  Future<void> _runAutoDownloadPass() async {
    final channels = favorites().where((c) => c.autoDownloadVods).toList();
    if (channels.isEmpty) return;

    // Auto-download writes to disk, so a configured folder is required. This
    // used to be skipped entirely, and startVodDownload then threw on every
    // single queued item.
    if (settings().vodDownloadFolder.trim().isEmpty) {
      _log('[Auto-Download] Skipped: no VOD download folder configured.');
      return;
    }

    for (final channel in channels) {
      try {
        final result = await fetchVods(channel);

        final handOff = onVodsFetched;
        if (handOff != null) {
          try {
            handOff(channel, result);
          } catch (e) {
            _log('[Auto-Download] VOD list hand-off failed for @${channel.username}: $e');
          }
        }

        if (result.vods.isEmpty) continue;

        final selected = selectVodsToAutoDownload(
          channel: channel,
          vods: result.vods,
          localProgress: localProgress(),
          settings: settings(),
          isAlreadyHandled: isVodHandled,
        );

        for (final vod in selected) {
          _log('[Auto-Download] Queueing ${vod.id} for @${channel.username}');
          queueDownload(
            vod,
            channel,
            // Tri-state: only override when the channel opts in. Passing false
            // unconditionally made the per-channel default beat the global
            // "Fast VOD Downloads" setting, so every automatic download ran the
            // slow post-processing path the Downloads tab promised to skip.
            overrideDisablePostProcessing:
                channel.autoDownloadFastDownload ? true : null,
          );

          if (settings().notifyAutoDownloadStart) {
            try {
              await showNotification(
                'Auto-Downloading VOD',
                'Started auto-downloading VOD for @${channel.username}:\n${vod.title}',
              );
            } catch (e) {
              _log('[Auto-Download Notification Error]: $e');
            }
          }
        }
      } catch (e) {
        _log('[Auto-Download Error] Failed for @${channel.username}: $e');
      }
    }
  }
}
