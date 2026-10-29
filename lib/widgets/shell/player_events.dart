import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../services/downloads_controller.dart';
import '../../services/log_store.dart';
import '../../services/player_service.dart';
import '../../state/activity_state.dart';
import '../../state/download_history.dart';
import '../../state/settings_repository.dart';
import '../../state/watch_history_controller.dart';
import 'vod_actions.dart' show ShowMessage;

/// What the player service reports, and where each report goes.
///
/// PlayerService has a callback per event - a player starting or stopping,
/// a line of output, a watch position, a download's progress and its end -
/// and the main screen set all of them in initState, about two hundred lines
/// of closures over its fields. They are here now, as they were, with what
/// each one touches passed in: the log, the watch history, the saved
/// download queue, the registry, the repository, and the screen's repaint,
/// pulse and messages.
///
/// The callbacks are left in place when the screen goes, deliberately. Its
/// dispose stops the players, asynchronously, and the stops that follow are
/// what write each one's final position ([WatchHistoryController.playbackStopped]);
/// each callback checks [_mounted] before it touches anything else.
class PlayerEvents {
  PlayerEvents({
    required PlayerService player,
    required LogNotifier logs,
    required WatchHistoryController history,
    required DownloadsController downloads,
    required DownloadHistory downloadHistory,
    required Map<String, String> Function() registry,
    required SettingsRepository repository,
    required AppSettings Function() settings,
    required DateTime Function() clock,
    required bool Function() mounted,
    required VoidCallback repaint,
    required VoidCallback updatePulse,
    required VoidCallback rescan,
    required VoidCallback libraryChanged,
    required ShowMessage showMessage,
    required SnackBarAction Function(String logKey) viewLog,
    required Future<bool> Function() windowHidden,
    required Future<void> Function(String title, String body) notify,
  })  : _player = player,
        _logs = logs,
        _history = history,
        _downloads = downloads,
        _downloadHistory = downloadHistory,
        _registry = registry,
        _repository = repository,
        _settings = settings,
        _clock = clock,
        _mounted = mounted,
        _repaint = repaint,
        _updatePulse = updatePulse,
        _rescan = rescan,
        _libraryChanged = libraryChanged,
        _showMessage = showMessage,
        _viewLog = viewLog,
        _windowHidden = windowHidden,
        _notify = notify;

  final PlayerService _player;
  final LogNotifier _logs;
  final WatchHistoryController _history;
  final DownloadsController _downloads;
  final DownloadHistory _downloadHistory;
  final Map<String, String> Function() _registry;
  final SettingsRepository _repository;
  final AppSettings Function() _settings;
  final DateTime Function() _clock;
  final bool Function() _mounted;

  /// The whole screen rebuilds: the grid reads the service's maps in build.
  final VoidCallback _repaint;
  final VoidCallback _updatePulse;

  /// Brings the downloaded badges and the registry in step with the disk.
  final VoidCallback _rescan;

  /// The registry changed under the Library's rows.
  final VoidCallback _libraryChanged;
  final ShowMessage _showMessage;

  /// "View log" for a failure message, deep-linking to that session.
  final SnackBarAction Function(String logKey) _viewLog;
  final Future<bool> Function() _windowHidden;

  /// Raises an OS notification, ignoring a platform that refuses.
  final Future<void> Function(String title, String body) _notify;

  /// Everything currently downloading or playing. Kept as a ValueNotifier so
  /// the activity pill and the Library's live rows repaint on a progress tick
  /// without rebuilding the whole screen.
  final ValueNotifier<ActivitySnapshot> activity =
      ValueNotifier(ActivitySnapshot.empty);

  /// Last whole-percent bucket and status per download, used to collapse the
  /// several-per-second progress callbacks into at most one rebuild per
  /// percent (see progressTickIsVisible).
  final Map<String, int> _progressBuckets = {};
  final Map<String, String?> _progressStatuses = {};

  /// Recomputes the activity snapshot from the service's live maps.
  void publishActivity() {
    activity.value = buildActivitySnapshot(
      downloadTaskIds: _player.activeDownloadTasks.keys,
      downloadQueue: _player.downloadQueue,
      startedIds: _player.activeDownloadProcesses.keys.toSet(),
      downloadTitles: _player.downloadTitles,
      downloadProgress: _player.activeDownloadsProgress,
      downloadStatuses: _player.activeDownloadTasks,
      playingVodIds: _player.playingVodIds,
      runningChannels: _player.runningChannels,
      vodTitles: {
        for (final entry in _history.playing.entries)
          entry.key: entry.value.title,
      },
    );
  }

  /// Sets every callback on the player service, and where yt-dlp keeps its
  /// archive.
  void bind({required String archivePath}) {
    _player.downloadArchiveFilePath = archivePath;
    // A queue that outlives a Settings save follows it.
    _player.currentSettings = _settings;
    // Retention deletes only what the app downloaded.
    _player.isOwnDownload = (vodId) =>
        _registry().containsKey(vodId) || _downloadHistory.contains(vodId);
    _player.onPlayerLog = (key, line) {
      // Not once the screen is gone: dispose stops the players, which is
      // asynchronous, and their last lines arrived after the log was
      // disposed - an error for each, like the callbacks below already
      // guard against.
      if (!_mounted()) return;
      _logs.appendLog(key, line);
    };

    // The service mutates playingVodIds/runningChannels internally with no
    // notification of its own, so this callback is the only signal that
    // playback began - it must stay even though the console tab it used to
    // select is gone.
    _player.onPlayerStarted = (key, title) {
      if (!_mounted()) return;
      _logs.beginSession(key, title);
      publishActivity();
      _updatePulse();
      _repaint();
    };

    _player.onPlayerStopped = (key, exitCode, userInitiated) {
      // Releases the "user is watching a VOD" marker, and writes the position
      // playback stopped at.
      _history.playbackStopped(key);
      if (!_mounted()) return;
      _logs.endSession(key, exitCode);

      publishActivity();
      _updatePulse();
      _repaint();
      // A player that never opened is otherwise silent: the console drawer
      // used to be the only hint. Surface it, with the log one tap away.
      //
      // userInitiated excludes deliberate stops: taskkill makes the process
      // exit non-zero, so without it every "Stop" reported a failure.
      if (shouldReportPlaybackFailure(
          exitCode: exitCode, userInitiated: userInitiated)) {
        final label = _logs.session(key)?.label ?? 'playback';
        _showMessage('Playback failed for $label', isError: true,
            action: _viewLog(key));
        // Only when the window is hidden, which is the auto-play case: a
        // failure the user is watching happen does not need a tray popup
        // on top of the message they can already see.
        _windowHidden().then((hidden) {
          if (hidden) _notify('Playback failed', label);
        });
      }
    };

    // One chokepoint for every position a player reports, and it can say no
    // (WatchHistoryController.record); the tracker pushes to Twitch only what
    // it keeps.
    _player.recordWatchProgress = _history.record;

    _player.onDownloadProgress = (vodId, progress, status) {
      if (!_mounted()) return;
      // Always cheap, and drives the pill plus the Library's live rows.
      publishActivity();
      // The full rebuild is still needed because VodsGrid reads the service
      // maps directly during build - but at most once per whole percent
      // instead of the ~10/second it used to fire.
      if (progressTickIsVisible(
        previousBucket: _progressBuckets[vodId],
        progress: progress,
        previousStatus: _progressStatuses[vodId],
        status: status,
      )) {
        _progressBuckets[vodId] = (progress * 100).floor();
        _progressStatuses[vodId] = status;
        _repaint();
      }
    };

    _player.onDownloadEnded = (vodId, exitCode) {
      if (!_mounted()) return;
      _logs.endSession(logKeyForDownload(vodId), exitCode);
    };

    // A download that completed, failed or was cancelled leaves the saved
    // queue (DownloadsController); one queued from anywhere joins it. Ending
    // downloads to exit or update reports none of these, so the queue stays
    // saved for the next launch.
    _player.onDownloadQueued = _downloads.remember;

    _player.onDownloadCancelled = (vodId) {
      _downloads.forget(vodId);
      _progressBuckets.remove(vodId);
      _progressStatuses.remove(vodId);
      if (_mounted()) {
        // Only the user's Cancel reports this; an exit, an update or the
        // session ending stops downloads without it, and their saved queue
        // resumes them. The user said no to this VOD, so the auto-download
        // pass leaves it alone from now on, as it does one downloaded once
        // (DownloadHistory): it used to queue it again a minute later. A
        // Download by hand still fetches it.
        if (_downloadHistory.record(vodId, _clock())) {
          _repository.requestSave();
        }
        publishActivity();
        _repaint();
        _libraryChanged();
        // Not an error - the user asked for it.
        _showMessage('Download cancelled.', isError: false);
      }
    };

    _player.onDownloadCompleted = (vodId, title, filePath) {
      _downloads.forget(vodId);
      if (_mounted()) {
        // With no file too: yt-dlp exits 0 without one for a VOD its archive
        // says it already downloaded.
        _downloadHistory.record(vodId, _clock());
        if (filePath.isNotEmpty) {
          _registry()[vodId] = filePath;
        }
        _repaint();
        _progressBuckets.remove(vodId);
        _progressStatuses.remove(vodId);
        publishActivity();
        _rescan();
        // With the queue change forget() asked for: downloads finish in
        // bursts (a backlog resumed at launch), one write for the burst.
        _repository.requestSave();
        _libraryChanged();
        _showMessage('Download completed: $title', isError: false);
        if (_settings().notifyDownloadComplete) {
          _notify('VOD Download Completed', title);
        }
      }
    };

    _player.onDownloadFailed = (vodId, title, exitCode) {
      _downloads.forget(vodId);
      _progressBuckets.remove(vodId);
      _progressStatuses.remove(vodId);
      if (_mounted()) {
        publishActivity();
        _repaint();
        _showMessage('Download failed for: $title (Exit code $exitCode)',
            isError: true, action: _viewLog(logKeyForDownload(vodId)));
      }
      // A failure is at least as worth knowing about as a success, and
      // downloads are exactly what runs while the app sits in the tray. No new
      // setting: it rides the toggle that already governs the outcome of a
      // download, now honestly labelled as covering both.
      if (_settings().notifyDownloadComplete) {
        _notify('VOD Download Failed', title);
      }
    };
  }

  void dispose() => activity.dispose();
}
