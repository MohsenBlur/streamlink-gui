import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../models/twitch_video.dart';
import '../state/automation_decisions.dart';
import '../state/channel_transitions.dart' show isPresumedOffline;
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
    required this.readWatchProgress,
    required this.localProgress,
    required this.isVodHandled,
    required this.wasDownloaded,
    required this.queueDownload,
    required this.showNotification,
    this.onVodsFetched,
    this.folderProblem,
    this.allPositionsEvery = const Duration(minutes: 30),
    DateTime Function()? clock,
    void Function(String message)? log,
  })  : _now = clock ?? DateTime.now,
        _log = log ?? print;

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
  /// so the app fetches these without per-VOD game names - and without the
  /// browser token's watch positions, which [readWatchProgress] reads for
  /// the VODs that need them.
  final Future<VodsFetchResult> Function(TwitchChannel channel) fetchVods;

  /// Reads the browser token's watch positions into [vods], merging in the
  /// local ones as [fetchVods] does: one GQL request per VOD.
  final Future<void> Function(List<TwitchVideo> vods) readWatchProgress;

  /// How often the pass reads every VOD's position, not only those of the
  /// VODs it would queue (see [_selectWithPositions]).
  final Duration allPositionsEvery;

  final DateTime Function() _now;

  /// Locally recorded watch positions by VOD id, in seconds.
  final Map<String, int> Function() localProgress;

  /// Whether a VOD is already downloaded, downloading or queued.
  final bool Function(String vodId) isVodHandled;

  /// Whether the app ever downloaded a VOD, though its file may be gone, or
  /// the user cancelled its download (DownloadHistory). The pass never
  /// fetches one of those again: a file retention or the user deleted came
  /// back on the next pass, and with retention below the windows, in a
  /// loop; a cancelled one came back a minute later. A download queued by
  /// hand is not asked.
  final bool Function(String vodId) wasDownloaded;

  final void Function(TwitchVideo vod, TwitchChannel channel,
      {bool? overrideDisablePostProcessing}) queueDownload;

  final Future<void> Function(String title, String body) showNotification;

  /// Why VODs cannot be saved in a folder right now, or null when they can
  /// (VodActions.folderProblem). Unset, the folder is not checked.
  final String? Function(String folder)? folderProblem;

  /// How long a VOD whose automatic download failed waits before the pass
  /// queues it again, by how many times it has been queued; the last applies
  /// from then on.
  ///
  /// A failure is recorded nowhere else (unlike a completion or a cancel, in
  /// the download history), so the next pass, a minute later, queued it again
  /// - and with a folder that could not be made, or a download that keeps
  /// failing, the same VODs failed every minute, two toasts and a snackbar
  /// each, for as long as it lasted.
  static const List<Duration> retryAfterFailure = <Duration>[
    Duration(minutes: 10),
    Duration(minutes: 30),
    Duration(hours: 2),
    Duration(hours: 6),
  ];

  /// HOOK for whoever caches VOD lists: called with every list the
  /// auto-download pass fetched, empty ones included, before anything is
  /// queued from it, and with the moment its request began, so a cache can
  /// tell it from a fetch that started later but finished first. Lists come
  /// from [fetchVods], so they carry no game names. A throw here is logged
  /// and does not stop the pass. Unset, the lists are used for the pass and
  /// dropped, as before.
  void Function(
          TwitchChannel channel, VodsFetchResult result, DateTime fetchedAt)?
      onVodsFetched;

  final void Function(String message) _log;

  /// Lowercased channel -> the session key last auto-played for it.
  final Map<String, String> _playedSessions = {};

  /// Lowercased channel -> when the pass last read every one of its VODs'
  /// positions.
  final Map<String, DateTime> _allPositionsReadAt = {};

  /// The VODs this pass has queued, by id, until they are in the download
  /// history. One the pass finds neither in flight nor downloaded again
  /// failed: a cancel and a deletion are in that history.
  final Map<String, ({int times, DateTime at})> _queuedByPass = {};

  /// The download folder's problem the log last reported, so an unplugged
  /// drive is said once, not every minute.
  String? _reportedFolderProblem;

  bool _passRunning = false;

  /// True while [runPass] is running.
  bool get isPassRunning => _passRunning;

  /// What has been auto-played this broadcast, by lowercased channel.
  Map<String, String> get playedSessions => Map.unmodifiable(_playedSessions);

  /// Forgets [channel]'s auto-played session, so a channel removed from the
  /// favourites cannot resurface as one later.
  void forgetChannel(String channel) =>
      _playedSessions.remove(channel.toLowerCase().trim());

  /// Which of [appeared], just found on [channel]'s [firstPage], a "New VOD"
  /// toast should still mention: not the ones this service's own pass
  /// queues and announces (see [newVodsLeftToAnnounce]). Read with the
  /// settings and progress the pass itself reads.
  List<TwitchVideo> newVodsToAnnounce(TwitchChannel channel,
          List<TwitchVideo> appeared, List<TwitchVideo> firstPage) =>
      newVodsLeftToAnnounce(
        channel: channel,
        appeared: appeared,
        firstPage: firstPage,
        localProgress: localProgress(),
        settings: settings(),
      );

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

    // Forget sessions that could be mistaken for the channel's next
    // broadcast once it is over, so that one is treated as new. A session
    // keyed by its stream id never can be, so it is kept - and so is any
    // session of a channel only presumed offline because its refreshes kept
    // failing. Forgetting those relaunched the same broadcast, unasked, as
    // soon as requests worked again.
    final keep = <String>{
      for (final c in channels)
        if (c.isLive || isPresumedOffline(c)) c.username.toLowerCase().trim(),
    };
    final favoriteNames =
        channels.map((c) => c.username.toLowerCase().trim()).toSet();
    _playedSessions.removeWhere((name, key) =>
        !favoriteNames.contains(name) ||
        (!keep.contains(name) && !sessionKeyNamesBroadcast(key)));

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
    final folder = settings().vodDownloadFolder.trim();
    if (folder.isEmpty) {
      _log('[Auto-Download] Skipped: no VOD download folder configured.');
      return;
    }

    _queuedByPass.removeWhere((id, _) => wasDownloaded(id));
    final now = _now();
    bool waitingToRetry(String vodId) {
      final queued = _queuedByPass[vodId];
      if (queued == null) return false;
      final step = (queued.times - 1).clamp(0, retryAfterFailure.length - 1);
      return now.difference(queued.at) < retryAfterFailure[step];
    }

    // Looked at once a pass, and only once there is something to queue. A
    // folder that cannot be made - an unplugged drive, a NAS out of reach -
    // failed every download the pass queued into it.
    bool? folderUsable;
    bool canQueue() {
      if (folderUsable == null) {
        final problem = folderProblem?.call(folder);
        if (problem != _reportedFolderProblem && problem != null) {
          _log('[Auto-Download] Skipped: the VOD download folder cannot be '
              'used ($problem).');
        }
        _reportedFolderProblem = problem;
        folderUsable = problem == null;
      }
      return folderUsable!;
    }

    for (final channel in channels) {
      try {
        final fetchedAt = DateTime.now();
        final result = await fetchVods(channel);

        final handOff = onVodsFetched;
        if (handOff != null) {
          try {
            handOff(channel, result, fetchedAt);
          } catch (e) {
            _log('[Auto-Download] VOD list hand-off failed for @${channel.username}: $e');
          }
        }

        if (result.vods.isEmpty) continue;

        final selected = await _selectWithPositions(
          channel,
          result.vods,
          () => selectVodsToAutoDownload(
            channel: channel,
            vods: result.vods,
            localProgress: localProgress(),
            settings: settings(),
            isAlreadyHandled: (id) =>
                isVodHandled(id) || wasDownloaded(id) || waitingToRetry(id),
          ),
        );

        for (final vod in selected) {
          if (!canQueue()) return;
          final before = _queuedByPass[vod.id];
          _queuedByPass[vod.id] = (times: (before?.times ?? 0) + 1, at: now);
          _log('[Auto-Download] Queueing ${vod.id} for @${channel.username}'
              '${before == null ? '' : ' again, after a failed download'}');
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

          // Announced once: a retry after a failure has its failure's toast.
          if (before == null && settings().notifyAutoDownloadStart) {
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

  /// What [select] picks from [vods] once the VODs it picks have their
  /// watch positions from Twitch.
  ///
  /// The pass read every VOD's position, one GQL request each, for every
  /// auto-download favourite every minute - though a VOD it will not queue
  /// (on disk, downloaded once, outside the window) needs none. Now it reads
  /// only those it would queue, and again for any the window moves onto
  /// when one of them turns out watched: each VOD it queues has had its own
  /// position read this pass, as before, and a pass with nothing to queue
  /// sends no request at all. A VOD watched on Twitch rather than in the app moves
  /// the window too, though, so every [allPositionsEvery] - and on the first
  /// pass - every VOD's position is read, as before.
  Future<List<TwitchVideo>> _selectWithPositions(
    TwitchChannel channel,
    List<TwitchVideo> vods,
    List<TwitchVideo> Function() select,
  ) async {
    final key = channel.username.toLowerCase().trim();
    final now = _now();
    final readAll = _allPositionsReadAt[key];
    if (readAll == null || now.difference(readAll) >= allPositionsEvery) {
      await readWatchProgress(vods);
      _allPositionsReadAt[key] = now;
      return select();
    }
    final read = <String>{};
    while (true) {
      final selected = select();
      final unread = [
        for (final vod in selected)
          if (read.add(vod.id)) vod,
      ];
      if (unread.isEmpty) return selected;
      await readWatchProgress(unread);
    }
  }
}
