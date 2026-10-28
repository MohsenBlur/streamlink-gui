import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/twitch_video.dart';
import '../../services/player_service.dart';
import '../../services/twitch_api_service.dart';
import '../../state/library_entries.dart';
import '../../state/watch_history_controller.dart';
import '../../utils/twitch_auth_status.dart';
import '../download_folder_prompt.dart';
import 'app_dialogs.dart';

/// Shows a message along the bottom of the screen (showAppSnackBar).
typedef ShowMessage = void Function(String message,
    {required bool isError, SnackBarAction? action});

/// What a VOD's own buttons do: play it, download it, cancel or delete its
/// download, and the same for a selection of them.
///
/// Moved out of the main screen as it was. The screen keeps what is on
/// screen - which channel is open, what is selected - and hands it in; this
/// is what each button does with it, and what the user is told.
class VodActions {
  VodActions({
    required PlayerService player,
    required TwitchApiService api,
    required WatchHistoryController history,
    required AppSettings Function() settings,
    required Map<String, String> Function() registry,
    required BuildContext Function() context,
    required bool Function() mounted,
    required ShowMessage showMessage,
    required Future<void> Function() save,
    required VoidCallback rescan,
    required VoidCallback changed,
  })  : _player = player,
        _api = api,
        _history = history,
        _settings = settings,
        _registry = registry,
        _context = context,
        _mounted = mounted,
        _showMessage = showMessage,
        _save = save,
        _rescan = rescan,
        _changed = changed;

  final PlayerService _player;
  final TwitchApiService _api;
  final WatchHistoryController _history;
  final AppSettings Function() _settings;

  /// The downloaded-VOD registry: VOD id to the file it landed in.
  final Map<String, String> Function() _registry;

  /// The screen's, for the dialogs; read only while [_mounted].
  final BuildContext Function() _context;
  final bool Function() _mounted;
  final ShowMessage _showMessage;

  /// Writes the config now.
  final Future<void> Function() _save;

  /// Brings the downloaded badges in step with the disk.
  final VoidCallback _rescan;

  /// Something on screen changed.
  final VoidCallback _changed;

  /// Plays [vod]: the downloaded copy when there is one, else streamed.
  void play(TwitchVideo vod, String channelName) {
    // The service refuses a second launch silently, which is right for the
    // automation paths but reads as a broken button here: the card's corner
    // play control is not visibly disabled while a VOD is playing.
    if (_player.playingVodIds.contains(vod.id)) {
      _showMessage('Already playing "${vod.title}".', isError: false);
      return;
    }

    final settings = _settings();
    final localPos = _history.flat[vod.id];
    if (localPos != null && (vod.watchPosition == null || localPos > vod.watchPosition!)) {
      vod.watchPosition = localPos;
    }
    // Recompute progress from position UNCONDITIONALLY, not only when the
    // local value raised it. A stale-high watchProgress riding on a correct
    // watchPosition survives the raise-merge, crosses the watched threshold,
    // and zeroes the resume - the "my progress mark vanished" half of the
    // pause-death bug. Position is the ground truth; the percentage is
    // derived, so derive it.
    final knownTotalSeconds = _api.parseDurationToSeconds(vod.duration);
    if (knownTotalSeconds > 0 && vod.watchPosition != null) {
      vod.watchProgress = vod.watchPosition! / knownTotalSeconds;
    }

    _history.startPlaying(vod);
    File? file;
    final registeredPath = _registry()[vod.id];
    if (registeredPath != null) {
      file = File(registeredPath);
      if (!file.existsSync()) {
        file = null;
      }
    }

    file ??= _player.getDownloadedVodFile(
      vod.id,
      channelName,
      settings.vodDownloadFolder,
    );

    // The playing set is what auto-play reads to stand down, and only the
    // player stopping clears it. If a launch fails before the service can
    // arrange that callback, auto-play and auto-download stand down for the
    // rest of the session - the exact failure already documented and fixed
    // once for the live path.
    final Future<void> launch = (file != null && file.existsSync())
        ? _player.playDownloadedVod(file, vod, settings)
        : _player.launchStreamlinkForVod(vod, channelName, settings);

    // If this VOD is opening behind the furthest point ever reached, say so and
    // offer the one action that fixes it. The furthest point is only a safety
    // net if the user can actually reach it; a value kept in a file that
    // nothing surfaces would be a backup in name only.
    _offerFurthestPosition(vod);

    launch.catchError((Object e) {
      _history.launchFailed(vod.id);
      if (_mounted()) {
        _showMessage('Could not start playback: ${describeTwitchError(e)}', isError: true);
      }
    });
  }

  /// Plays [video] from the recently-watched list, which knows no channel.
  void playRecent(TwitchVideo video) => play(video, channelNameFor(video.id));

  /// Channel a VOD belongs to, best-effort: the registry path's channel
  /// folder, then this session's download bookkeeping. The recents carousel
  /// previously hardcoded 'VOD', which made a play look for the local file
  /// under `<root>/VOD/` and re-stream VODs that were sitting on disk.
  String channelNameFor(String vodId) {
    final path = _registry()[vodId];
    if (path != null) {
      final parsed = channelFromDownloadPath(path, _settings().vodDownloadFolder);
      if (parsed != null && parsed.isNotEmpty) return parsed;
    }
    return _player.downloadChannelNames[vodId] ?? 'VOD';
  }

  /// Offers to jump to the furthest point reached, when playback starts
  /// behind it (WatchHistoryController.offerFurthestPosition says when).
  void _offerFurthestPosition(TwitchVideo vod) {
    _history.offerFurthestPosition(vod,
        stillPlaying: () => _player.playingVodIds.contains(vod.id),
        offer: (best) {
      final label = WatchHistoryController.clockLabel(best);
      _showMessage(
        'You had reached $label in this VOD.',
        isError: false,
        action: SnackBarAction(
          label: 'Jump there',
          onPressed: () async {
            final ok =
                await _player.seekActiveVod(vod.id, best, _settings());
            if (!_mounted()) return;
            _showMessage(
                ok
                    ? 'Jumped to $label.'
                    : 'Could not reach the player to jump; seek there manually.',
                isError: !ok);
          },
        ),
      );
    });
  }

  /// Runs [onConfigured] once there is a download folder, asking for one
  /// first when there is none.
  Future<void> ensureDownloadFolder(VoidCallback onConfigured) async {
    if (_settings().vodDownloadFolder.trim().isNotEmpty) {
      onConfigured();
      return;
    }

    // Null when the prompt was cancelled or dismissed - including while its
    // folder dialog was still open, whose late answer the prompt drops.
    final path = await DownloadFolderPrompt.show(_context());
    if (!_mounted()) return;
    if (path == null) {
      _showMessage('Download cancelled: VOD Download Folder is required.', isError: true);
      return;
    }
    _settings().vodDownloadFolder = path;
    _changed();
    await _save();
    _rescan();
    onConfigured();
  }

  /// Queues [vod]'s download, by hand.
  void download(TwitchVideo vod, String channelName) {
    ensureDownloadFolder(() {
      _player.queueVodDownload(vod, channelName, _settings(),
          byHand: true);
      _changed();
    });
  }

  /// Cancels [vodId]'s download, queued or running.
  Future<void> cancelDownload(String vodId, String channelName) async {
    await _player.cancelVodDownload(vodId, channelName, _settings().vodDownloadFolder);
    if (_mounted()) _changed();
  }

  /// Deletes the files for [vodId], preferring the path recorded in the
  /// registry over re-deriving it from the currently selected channel.
  /// Returns how many files were actually removed.
  int _deleteFilesFor(String vodId, String channelName) {
    var deleted = 0;

    // The registry holds where the file really landed. Re-deriving
    // `<folder>/<selectedChannel>` orphaned files whenever the download
    // belonged to a different channel than the one currently selected.
    final registeredPath = _registry()[vodId];
    if (registeredPath != null) {
      try {
        final file = File(registeredPath);
        if (file.existsSync()) {
          file.deleteSync();
          deleted++;
        }
      } catch (_) {}
    }

    deleted += _player.deleteVodFiles(
      vodId,
      channelName,
      _settings().vodDownloadFolder,
    );
    return deleted;
  }

  /// Deletes [vodId]'s download and forgets it.
  Future<void> deleteDownload(String vodId, String channelName) async {
    final deleted = _deleteFilesFor(vodId, channelName);

    _player.removeVodFromArchive(vodId);
    _registry().remove(vodId);
    await _save();
    _rescan();

    // Report what actually happened rather than claiming success
    // unconditionally, which previously hid a failed delete while still
    // dropping the registry entry and orphaning the file.
    if (deleted > 0) {
      _showMessage('Deleted $deleted file(s) for VOD $vodId.', isError: false);
    } else {
      _showMessage('No downloaded files found for VOD $vodId.', isError: true);
    }
  }

  /// Queues the selection's downloads: one at once, several in the order the
  /// user picks. [channelName] is read when they are queued; [endSelection]
  /// leaves selection mode.
  void downloadSelection(
    List<TwitchVideo> selectedVods, {
    required String Function() channelName,
    required VoidCallback endSelection,
  }) {
    if (selectedVods.isEmpty) return;

    ensureDownloadFolder(() {
      if (selectedVods.length == 1) {
        _player.queueVodDownload(
            selectedVods.first, channelName(), _settings(),
            byHand: true);
        endSelection();
      } else {
        _queueInChosenOrder(selectedVods, channelName);
        endSelection();
      }
    });
  }

  Future<void> _queueInChosenOrder(
      List<TwitchVideo> selectedVods, String Function() channelName) async {
    String? chosenOrder = await chooseDownloadOrder(_context(), selectedVods.length);

    if (chosenOrder == null) return;

    final name = channelName();

    final sortedVods = List<TwitchVideo>.from(selectedVods);
    if (chosenOrder == 'newest') {
      sortedVods.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    } else {
      sortedVods.sort((a, b) => a.publishedAt.compareTo(b.publishedAt));
    }
    _showMessage('Queueing ${sortedVods.length} downloads...', isError: false);
    for (final vod in sortedVods) {
      _player.queueVodDownload(vod, name, _settings(),
          byHand: true);
    }
    _changed();
  }

  /// Deletes the downloads among [selected], after asking; [endSelection]
  /// leaves selection mode once they are gone.
  Future<void> deleteSelection(
    List<TwitchVideo> selected, {
    required String channelName,
    required VoidCallback endSelection,
  }) async {
    final settings = _settings();
    final toDelete = <TwitchVideo>[
      for (final vod in selected)
        if (_registry().containsKey(vod.id) ||
            _player.getDownloadedVodFile(
                    vod.id, channelName, settings.vodDownloadFolder) !=
                null)
          vod,
    ];

    if (toDelete.isEmpty) {
      _showMessage('No fully downloaded VODs found among selection.', isError: true);
      return;
    }

    final confirm = await confirmDeleteDownloads(_context(), toDelete);

    if (confirm != true) return;

    // Counts files actually deleted. This previously incremented once per
    // existing channel *directory*, so it reported a count even when nothing
    // was removed.
    int count = 0;
    for (final vod in toDelete) {
      try {
        count += _deleteFilesFor(vod.id, channelName);
        _player.removeVodFromArchive(vod.id);
        _registry().remove(vod.id);
      } catch (_) {}
    }
    await _save();
    if (!_mounted()) return;

    _rescan();
    endSelection();
    _showMessage('Deleted $count downloaded VOD files.', isError: false);
  }
}
