import 'dart:async';

/// When the config, the watch-progress sidecar and the recently-watched list
/// reach disk.
///
/// The app saved through about thirty direct calls, which left three problems
/// nothing could fix in one place:
///  * A save could run before the file it rewrites had been read. The sidecar
///    (`watch_progress.json`: the furthest point reached and the undo trail)
///    was read last at startup, after the network refresh, and anything that
///    saved in the meantime - resuming unfinished downloads, the window
///    settling into place - first rewrote it from the flat compatibility
///    copy in the config. Every VOD's furthest point collapsed onto its
///    current position and its trail was erased, for good, which is exactly
///    the loss the sidecar exists to prevent.
///  * A playing VOD reported its position every two seconds and each report
///    rewrote all three files, each fsync'd: about nine thousand rounds over
///    a five-hour VOD.
///  * A write could not be put off and then caught up with, so there was no
///    way to make sure the last one landed before the app went.
///
/// So each file now has a gate: nothing is written to it until its contents
/// have been loaded ([markConfigLoaded], [markHistoryLoaded]). A write asked
/// for before that is held, not dropped, and goes out once the gate opens.
/// Watch positions are written at most every [progressDelay] ([noteProgress])
/// and at once when playback stops ([flushProgress]) or the app goes
/// ([flushNow]).
///
/// The writers are injected: what goes into each file belongs to the app,
/// when it is written belongs here. They are expected to report a failed
/// write themselves (StorageService's `storageWriteFailure`) rather than
/// throw.
class SettingsRepository {
  SettingsRepository({
    required Future<void> Function() writeConfig,
    required Future<void> Function() writeProgress,
    required Future<void> Function() writeRecents,
    this.saveDelay = const Duration(seconds: 1),
    this.progressDelay = const Duration(seconds: 20),
    void Function(Object error, StackTrace stack)? onError,
  })  : _writeConfig = writeConfig,
        _writeProgress = writeProgress,
        _writeRecents = writeRecents,
        _onError = onError;

  final Future<void> Function() _writeConfig;
  final Future<void> Function() _writeProgress;
  final Future<void> Function() _writeRecents;
  final void Function(Object error, StackTrace stack)? _onError;

  /// How long [requestSave] waits, so a burst of changes is one write.
  final Duration saveDelay;

  /// The longest a watch position waits to be written. Long enough that a
  /// two-second tracker costs a write every few ticks rather than three per
  /// tick; short enough that a crash or a power cut loses at most this much
  /// of a session.
  final Duration progressDelay;

  bool _configLoaded = false;
  bool _historyLoaded = false;

  bool _configDirty = false;
  bool _progressDirty = false;
  bool _recentsDirty = false;

  Timer? _saveTimer;
  Timer? _progressTimer;
  bool _disposed = false;

  /// Whether the config has been read, so it may be written.
  bool get configLoaded => _configLoaded;

  /// Whether the watch-progress sidecar and the recently-watched list have
  /// been read, so they may be written.
  bool get historyLoaded => _historyLoaded;

  /// Whether a write has been asked for that has not gone out yet.
  bool get hasPendingWrites => _configDirty || _progressDirty || _recentsDirty;

  /// The config has been read into memory; a save held until now goes out.
  void markConfigLoaded() {
    if (_configLoaded) return;
    _configLoaded = true;
    if (_configDirty) _flushInBackground();
  }

  /// The sidecar and the recents list have been read and merged into memory;
  /// a write held until now goes out.
  void markHistoryLoaded() {
    if (_historyLoaded) return;
    _historyLoaded = true;
    if (_progressDirty || _recentsDirty) _flushInBackground();
  }

  /// Writes the config and the watch progress now: what a save always did.
  ///
  /// Completes once both writes have finished (a failure is reported through
  /// the writers, not thrown). A file whose gate is still closed is written
  /// when it opens instead, and the returned future does not wait for that.
  Future<void> saveNow() {
    _configDirty = true;
    _progressDirty = true;
    return _flush();
  }

  /// Writes the config [saveDelay] from now, together with anything else
  /// asked for meanwhile: for changes that come in bursts, like a dozen VODs
  /// queued at once, or the registry scan.
  void requestSave() {
    _configDirty = true;
    _schedule(isProgress: false);
  }

  /// A watch position moved, and with [recents] the recently-watched list
  /// too. Written within [progressDelay] - with the config, which carries the
  /// flat copy of every position for older builds - instead of on every tick.
  void noteProgress({bool recents = false}) {
    _configDirty = true;
    _progressDirty = true;
    if (recents) _recentsDirty = true;
    _schedule(isProgress: true);
  }

  /// Writes whatever [noteProgress] is holding, now: playback stopped, so the
  /// position it stopped at is the one to keep.
  Future<void> flushProgress() {
    if (!_progressDirty && !_recentsDirty) return Future<void>.value();
    return _flush();
  }

  /// Writes all three files now, pending or not: the app is about to go.
  Future<void> flushNow() {
    _configDirty = true;
    _progressDirty = true;
    _recentsDirty = true;
    return _flush();
  }

  void _schedule({required bool isProgress}) {
    if (_disposed) {
      // Nothing will be left to fire a timer for; write now instead.
      _flushInBackground();
      return;
    }
    // Not restarted by later requests: a steady stream of them (a progress
    // tick every two seconds) must not put the write off forever.
    if (isProgress) {
      _progressTimer ??= Timer(progressDelay, _flushInBackground);
    } else {
      _saveTimer ??= Timer(saveDelay, _flushInBackground);
    }
  }

  Future<void> _flush() {
    // Whatever these timers were holding goes out now - or, for a file whose
    // gate is still closed, when the gate opens, which flushes by itself.
    _saveTimer?.cancel();
    _saveTimer = null;
    _progressTimer?.cancel();
    _progressTimer = null;

    final writes = <Future<void>>[];
    if (_configDirty && _configLoaded) {
      _configDirty = false;
      writes.add(Future.sync(_writeConfig));
    }
    if (_progressDirty && _historyLoaded) {
      _progressDirty = false;
      writes.add(Future.sync(_writeProgress));
    }
    if (_recentsDirty && _historyLoaded) {
      _recentsDirty = false;
      writes.add(Future.sync(_writeRecents));
    }
    if (writes.isEmpty) return Future<void>.value();
    return Future.wait(writes).then((_) {});
  }

  /// A flush nobody awaits: a throw from it would otherwise surface as an
  /// unhandled error in the zone.
  void _flushInBackground() {
    _flush().catchError((Object e, StackTrace st) => _onError?.call(e, st));
  }

  /// Stops the timers, writing out anything they were holding.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (hasPendingWrites) {
      _flushInBackground();
    } else {
      _saveTimer?.cancel();
      _progressTimer?.cancel();
    }
    _saveTimer = null;
    _progressTimer = null;
  }
}
