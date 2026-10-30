import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../models/twitch_video.dart';
import '../state/download_registry.dart';
import 'player_service.dart';

/// A saved download to put back in the queue at launch.
class ResumableDownload {
  const ResumableDownload(this.vod, this.channelName);

  final TwitchVideo vod;

  /// The channel the download belongs to, which names its folder.
  final String channelName;
}

/// What a downloaded-file scan looks at, captured on the UI isolate.
///
/// Plain data, so it can be sent to the isolate the scan runs on.
class DownloadScanInput {
  const DownloadScanInput({
    required this.downloadRoot,
    required this.channelName,
    required this.vodIds,
    required this.registry,
    required this.inFlight,
  });

  /// The configured download folder, trimmed; empty when none is set.
  final String downloadRoot;

  /// The open channel, whose folder is searched for [vodIds]' files.
  final String channelName;

  /// The open channel's VODs, matched against its folder so files that
  /// arrived without going through this app are picked up.
  final List<String> vodIds;

  /// The downloaded-VOD registry, id to path, as it was when the scan began.
  final Map<String, String> registry;

  /// Downloads running or queued; see [planRegistryScan].
  final Set<String> inFlight;
}

/// What a scan changes, already checked against the registry as it is when
/// the scan comes back. Nothing here has been applied yet.
class DownloadScanOutcome {
  const DownloadScanOutcome({
    required this.downloaded,
    required this.prune,
    required this.stripFromArchive,
    required this.additions,
  });

  /// The ids to show as downloaded.
  final Set<String> downloaded;

  /// Registry ids whose file is gone from a folder the scan could read.
  final Set<String> prune;

  /// Ids to remove from yt-dlp's archive; a subset of [prune].
  final Set<String> stripFromArchive;

  /// Files found on disk to record, id to path.
  final Map<String, String> additions;

  bool get registryChanged => prune.isNotEmpty || additions.isNotEmpty;
}

/// The scan itself: one listing of the open channel's folder, then the plan.
///
/// Runs on a background isolate (see [DownloadsController.rescan]). It used to
/// run on the UI isolate every ten seconds, listing the channel's folder once
/// PER VOD - a hundred listings for a channel scrolled back a few pages - plus
/// an existence check per registry entry, all synchronous. On a slow network
/// share, which the registry rules exist for, each of those can block for
/// seconds, and the window froze with them.
///
/// Null when the download folder cannot be seen at all - an unplugged drive,
/// a share that is down. Every check below would then answer "gone", and
/// acting on that would forget every download that is merely offline; null
/// means "change nothing".
RegistryScanPlan? scanDownloadFolder(DownloadScanInput input) {
  try {
    if (!Directory(input.downloadRoot).existsSync()) return null;
  } catch (_) {
    return null;
  }

  // Where each of the open channel's VODs would live. The same folder and the
  // same matching as PlayerService.getDownloadedVodFile, which this replaces
  // here: the first completed file in listing order.
  final candidates = <String, String>{};
  if (input.vodIds.isNotEmpty) {
    var files = const <String>[];
    try {
      final dir = Directory(p.join(input.downloadRoot, input.channelName));
      if (dir.existsSync()) {
        files = [
          for (final entity in dir.listSync())
            if (entity is File) entity.path,
        ];
      }
    } catch (_) {}
    for (final vodId in input.vodIds) {
      final pattern = PlayerService.vodFinalFilePattern(vodId);
      for (final file in files) {
        if (pattern.hasMatch(file)) {
          candidates[vodId] = file;
          break;
        }
      }
    }
  }

  return planRegistryScan(
    registry: input.registry,
    inFlightIds: input.inFlight,
    candidates: candidates,
    fileExists: _isFile,
    directoryExists: _isDirectory,
  );
}

bool _isFile(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

bool _isDirectory(String path) {
  try {
    return Directory(path).existsSync();
  } catch (_) {
    return false;
  }
}

/// Fits a [plan] made against [scanned] to the app as it is [now].
///
/// The scan is asynchronous, and the registry moves on while it runs: a
/// download completes and is recorded, a file is deleted from the Library, a
/// VOD is queued again. Applying the plan as made would undo those - prune an
/// entry that was just recorded at a new path, re-badge one just deleted - so
/// an entry is only changed when it is still exactly what the scan looked at.
DownloadScanOutcome reconcileDownloadScan({
  required DownloadScanInput scanned,
  required RegistryScanPlan plan,
  required DownloadScanInput now,
}) {
  bool untouched(String id) =>
      now.registry[id] == scanned.registry[id] && !now.inFlight.contains(id);

  final prune = {for (final id in plan.prune) if (untouched(id)) id};
  final additions = {
    for (final entry in plan.additions.entries)
      if (untouched(entry.key)) entry.key: entry.value,
  };
  return DownloadScanOutcome(
    downloaded: {
      for (final id in {...plan.present, ...plan.unverified})
        if (now.registry.containsKey(id) || additions.containsKey(id)) id,
    },
    prune: prune,
    stripFromArchive: {
      for (final id in plan.stripFromArchive)
        if (prune.contains(id)) id,
    },
    additions: additions,
  );
}

/// The download queue as it is saved, and the scan that keeps the
/// downloaded-VOD registry in step with the disk.
///
/// The queue used to reach disk only when the user chose Exit or an update
/// ran: a crash, a sign-out or a Windows Update restart lost every queued
/// VOD. And the resume at launch cleared the saved copy before re-queueing,
/// so a crash an hour after a normal restart lost the resumed ones too.
///
/// Now the saved queue is kept here, changed as downloads are queued and
/// finish, and handed to every config save ([persisted]). An entry stays
/// saved until its download completes, fails or is cancelled - so stopping
/// everything to exit or update, which ends downloads without finishing
/// them, leaves the queue saved exactly as it was.
class DownloadsController {
  DownloadsController({
    required void Function() onQueueChanged,
    required DownloadScanInput Function() readScanInput,
    required void Function(DownloadScanOutcome outcome) onScanned,
    Future<RegistryScanPlan?> Function(DownloadScanInput input)? runScan,
  })  : _onQueueChanged = onQueueChanged,
        _readScanInput = readScanInput,
        _onScanned = onScanned,
        _runScan = runScan ?? _scanInBackground;

  /// The saved queue changed; it should reach disk soon.
  final void Function() _onQueueChanged;
  final DownloadScanInput Function() _readScanInput;
  final void Function(DownloadScanOutcome outcome) _onScanned;
  final Future<RegistryScanPlan?> Function(DownloadScanInput input) _runScan;

  /// Static, so the closure sent to the isolate captures nothing but [input].
  static Future<RegistryScanPlan?> _scanInBackground(DownloadScanInput input) =>
      Isolate.run(() => scanDownloadFolder(input));

  bool _disposed = false;

  // ---- The saved queue ----

  /// Unfinished downloads by id, in the order they were queued (a map
  /// literal keeps insertion order), each in the shape `unfinished_downloads`
  /// has always had: `{vod, channelName}`.
  final Map<String, Map<String, dynamic>> _unfinished = {};

  /// Whether [restore] has adopted the queue saved at the last run. Until it
  /// has, there is nothing here to save over it with.
  bool _restored = false;

  /// The queue as it was when Windows began ending the session; see [freeze].
  List<Map<String, dynamic>>? _frozen;

  /// Adopts the queue saved at the last run, and returns what to queue again.
  ///
  /// The saved copy is NOT cleared: each entry stays saved until its download
  /// finishes, exactly as if the app had never stopped. Entries that cannot
  /// be read are dropped, so they are not carried forward forever.
  List<ResumableDownload> restore(List<dynamic> saved) {
    final adopted = <String, Map<String, dynamic>>{};
    final resumable = <ResumableDownload>[];
    var dropped = false;
    for (final item in saved) {
      final download = _readSaved(item);
      if (download == null) {
        dropped = true;
        continue;
      }
      if (adopted.containsKey(download.vod.id)) continue;
      adopted[download.vod.id] = _entryFor(download.vod, download.channelName);
      resumable.add(download);
    }
    // Anything queued before the restore - nothing should be - follows the
    // saved queue rather than replacing it.
    for (final entry in _unfinished.entries) {
      adopted.putIfAbsent(entry.key, () => entry.value);
    }
    _unfinished
      ..clear()
      ..addAll(adopted);
    _restored = true;
    if (dropped) _onQueueChanged();
    return resumable;
  }

  static ResumableDownload? _readSaved(dynamic item) {
    if (item is! Map) return null;
    final vod = TwitchVideo.tryFromJson(item['vod']);
    final channelName = item['channelName'];
    if (vod == null || channelName is! String) return null;
    return ResumableDownload(vod, channelName);
  }

  static Map<String, dynamic> _entryFor(TwitchVideo vod, String channelName) =>
      {'vod': vod.toJson(), 'channelName': channelName};

  /// A download was queued (PlayerService.onDownloadQueued).
  void remember(TwitchVideo vod, String channelName) {
    if (_unfinished.containsKey(vod.id)) return;
    _unfinished[vod.id] = _entryFor(vod, channelName);
    _onQueueChanged();
  }

  /// A download completed, failed or was cancelled: it will not resume.
  void forget(String vodId) {
    if (_unfinished.remove(vodId) != null) _onQueueChanged();
  }

  /// The queue to save, or null before [restore], when the config's own copy
  /// must be left as it is.
  ///
  /// Read by every config save rather than written into the settings when the
  /// queue changes, so a settings object replaced wholesale (by the Settings
  /// dialog, say, from a copy taken before the queue moved) cannot bring an
  /// old queue back.
  List<Map<String, dynamic>>? get persisted {
    final frozen = _frozen;
    if (frozen != null) return _copy(frozen);
    if (!_restored) return null;
    return _copy(_unfinished.values);
  }

  static List<Map<String, dynamic>> _copy(
          Iterable<Map<String, dynamic>> entries) =>
      [for (final entry in entries) Map<String, dynamic>.from(entry)];

  /// Holds the saved queue as it is now, whatever happens to the downloads,
  /// until [unfreeze].
  ///
  /// For Windows ending the session: it ends the downloads along with
  /// everything else, and a download ended that way reports itself as failed
  /// - which would otherwise drop it from the queue that is about to be
  /// saved for the next launch.
  ///
  /// A hold already in place stays: a second session end before the first
  /// one's hold is released (see SessionEnd's survival grace) would otherwise
  /// take its copy from a queue the first one's kills had already shortened.
  void freeze() {
    if (!_restored || _frozen != null) return;
    _frozen = _copy(_unfinished.values);
  }

  /// The session is going on after all: back to saving the queue as it is.
  void unfreeze() {
    if (_frozen == null) return;
    _frozen = null;
    _onQueueChanged();
  }

  // ---- The downloaded-file scan ----

  Future<void>? _scanning;
  bool _scanAgain = false;
  bool _scanRunning = false;

  /// Checks the registry against the disk, off the UI isolate, and reports
  /// the result to `onScanned`.
  ///
  /// At most one scan runs at a time: a request while one is running is
  /// folded into a single pass after it - which then sees whatever changed in
  /// the meantime - so a slow share never has more than one listing in
  /// flight, however often the timer and the download callbacks ask.
  Future<void> rescan() {
    final running = _scanning;
    if (running != null) {
      _scanAgain = true;
      return running;
    }
    _scanRunning = true;
    final scan = _scanLoop();
    // With no download folder the loop awaits nothing, so it has already run
    // to its end here, its finally included. Kept anyway, the finished scan
    // was the "one running" every later request joined: no scan ever ran
    // again that session, folder set or not.
    if (_scanRunning) _scanning = scan;
    return scan;
  }

  Future<void> _scanLoop() async {
    try {
      do {
        _scanAgain = false;
        final input = _readScanInput();
        RegistryScanPlan? plan;
        if (input.downloadRoot.isEmpty) {
          // No folder: nothing can be downloaded, so nothing is badged - and
          // nothing is pruned either, the registry is simply not consulted.
          plan = const RegistryScanPlan(
            present: {},
            unverified: {},
            prune: {},
            stripFromArchive: {},
            additions: {},
          );
        } else {
          try {
            plan = await _runScan(input);
          } catch (_) {
            plan = null; // a scan that failed changes nothing
          }
        }
        if (_disposed) return;
        if (plan != null) {
          _onScanned(reconcileDownloadScan(
              scanned: input, plan: plan, now: _readScanInput()));
        }
      } while (_scanAgain && !_disposed);
    } finally {
      _scanning = null;
      _scanRunning = false;
    }
  }

  /// Stops reporting scans; one still running is dropped when it returns.
  void dispose() {
    _disposed = true;
  }
}
