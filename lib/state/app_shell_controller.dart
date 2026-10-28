import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../models/app_settings.dart';
import '../services/crash_log.dart';
import '../services/desktop_shell.dart';
import '../services/session_end.dart';
import '../services/storage_service.dart';
import '../services/update_service.dart';
import '../utils/window_bounds.dart';
import 'settings_repository.dart';

/// The app's shell: its window, its tray icon, the way out, and the update
/// that replaces it.
///
/// This lived in `_MainScreenState`, where the same few facts - whether the
/// window is on screen, whether the app is exiting, whether an update is
/// installing - were each read and written from a dozen methods apart. It is
/// the single owner of them now, and it decides nothing about what the
/// screen shows: what a window coming back refreshes, what an Exit has to
/// confirm and what a tray item opens are the screen's, handed in as
/// closures and read at call time.
class AppShellController with WindowListener {
  AppShellController({
    required AppWindow window,
    required AppTray tray,
    required AppNotifications notifications,
    required UpdateService updates,
    required SettingsRepository repository,
    required AppSettings Function() settings,
    required Future<void> Function() stopAll,
    required Iterable<String> Function() liveFavorites,
    required bool startHidden,
    required this.onVisibilityChanged,
    required this.onCameBack,
    required this.confirmExit,
    required this.showMessage,
    required this.onTrayWatch,
    required this.onTrayOpenLibrary,
    required this.onExitCommitted,
    required this.onSessionEnding,
    required this.onSessionContinues,
    MethodChannel singleInstanceChannel = defaultSingleInstanceChannel,
  })  : _window = window,
        _tray = tray,
        _notifications = notifications,
        _updates = updates,
        _repository = repository,
        _settings = settings,
        _stopAll = stopAll,
        _liveFavorites = liveFavorites,
        _singleInstanceChannel = singleInstanceChannel,
        _windowVisible = !startHidden;

  /// The runner's second-launch notification ("activate"); see [attach].
  static const MethodChannel defaultSingleInstanceChannel =
      MethodChannel('streamlink_gui/single_instance');

  /// The longest quitting or updating waits for players and downloads to end.
  static const Duration stopAllTimeout = Duration(seconds: 5);

  /// Set while the window is hidden because the user hid it (closed or
  /// minimized to the tray), and cleared when it is shown again; see
  /// [hideWindow]. Read by main()'s check after the first frame, which runs
  /// outside any screen and must not bring back a window put away on purpose.
  static bool windowHiddenByUser = false;

  final AppWindow _window;
  final AppTray _tray;
  final AppNotifications _notifications;
  final UpdateService _updates;
  final SettingsRepository _repository;
  final AppSettings Function() _settings;
  final Future<void> Function() _stopAll;
  final Iterable<String> Function() _liveFavorites;
  final MethodChannel _singleInstanceChannel;

  /// [windowVisible] changed, which gates the screen's pulse.
  final void Function() onVisibilityChanged;

  /// The window came back into view - shown from the tray, restored or
  /// focused - debounced, and never while exiting.
  final void Function() onCameBack;

  /// Whatever an Exit has to ask first (downloads that would pause, a queue
  /// that could not be saved). True to go on.
  final Future<bool> Function() confirmExit;

  /// An in-app message, for an Exit refused while an update installs.
  final void Function(String message) showMessage;

  /// The tray's `Watch <name>` items.
  final void Function(String username) onTrayWatch;

  /// The tray's "Open Library", once the window is up.
  final void Function() onTrayOpenLibrary;

  /// The app has committed to quitting: the screen's own timers stop now.
  final void Function() onExitCommitted;

  /// Windows is ending the session, before the save (see [SessionEnd]).
  final void Function() onSessionEnding;

  /// The session end was called off, or the process outlived it.
  final void Function() onSessionContinues;

  bool _disposed = false;

  /// Hooks the shell up: window events, the runner's second-launch call, the
  /// tray icon and Windows ending the session.
  void attach() {
    _window.addListener(this);
    // A second launch hands over to this instance (windows/runner): the
    // runner has already shown or restored the window, re-shown its content
    // and taken the foreground by the time this arrives, so nothing here may
    // hide anything - it only brings Dart's bookkeeping up to date.
    _singleInstanceChannel.setMethodCallHandler((call) async {
      if (call.method == 'activate') {
        // The runner showed the window, past [showWindow], which is what
        // clears this mark: a window back on screen stayed marked as one
        // the user put away.
        windowHiddenByUser = false;
        await syncWindowVisible();
        try {
          await _window.focus();
        } catch (_) {}
      }
      return null;
    });
    unawaited(_initTray());
    // Windows ending the session (shutdown, restart, sign-out) is given the
    // chance to save the queue, the progress and the window first.
    SessionEnd.listen(
      onEnding: _saveForSessionEnd,
      onCancelled: onSessionContinues,
      // Answered, yet not ended: the Restart Manager asking for an installer
      // (ENDSESSION_CLOSEAPP). Without this the queue stayed frozen for the
      // rest of the run.
      onSurvived: () {
        CrashLog.current?.milestone(
            '[session] still running after the session end; saving normally');
        onSessionContinues();
      },
    );
  }

  void dispose() {
    _disposed = true;
    _window.removeListener(this);
    _singleInstanceChannel.setMethodCallHandler(null);
    _windowSaveTimer?.cancel();
    _cameBackTimer?.cancel();
    SessionEnd.stopListening();
  }

  // ---------------------------------------------------------------------------
  // The window

  /// Whether the window is on screen, which gates the pulse.
  ///
  /// Written in one place only, [syncWindowVisible], which reads it back
  /// from the window itself. It used to be set by hand on the few paths that
  /// remembered to (tray Show/Hide, minimize, restore), so closing to the
  /// tray, starting minimized, a toast's click or a second launch each left
  /// it wrong - a pulse running in the tray, or one frozen on screen.
  bool get windowVisible => _windowVisible;
  bool _windowVisible;

  /// Brings the window forward from wherever it is: the tray, minimized, or
  /// never shown yet because the app started hidden.
  ///
  /// Through the runner rather than windowManager.show(), because the
  /// runner knows how the window was restored: started hidden from a
  /// maximized session, its first appearance must be maximized, and a plain
  /// show brought it back at its normal size.
  Future<void> showWindow() async {
    windowHiddenByUser = false;
    try {
      await _window.showNative();
    } catch (_) {
      await _window.show();
      await _window.focus();
    }
  }

  /// The user's own hide: close or minimize to the tray, or the tray's Hide
  /// App. Marked first, so the check after the first frame leaves it hidden.
  Future<void> hideWindow() async {
    windowHiddenByUser = true;
    await _window.hide();
  }

  /// Re-reads [windowVisible] from the window. Every way of showing or
  /// hiding it ends in a window event ([onWindowEvent]) or, for a second
  /// launch, the runner's activate call, and both land here.
  Future<void> syncWindowVisible() async {
    bool visible;
    try {
      visible = await _window.isVisible() && !await _window.isMinimized();
    } catch (_) {
      return;
    }
    if (_disposed || visible == _windowVisible) return;
    _windowVisible = visible;
    onVisibilityChanged();
  }

  /// Whether the window is somewhere the user can actually read a SnackBar.
  ///
  /// The app's normal state is minimised to the tray, where an in-app message
  /// is shown to nobody - and auto-play and auto-download run precisely then.
  Future<bool> isHidden() async {
    try {
      if (!await _window.isVisible()) return true;
      return await _window.isMinimized();
    } catch (_) {
      // Unknown: prefer the OS notification over silence.
      return true;
    }
  }

  @override
  void onWindowEvent(String eventName) {
    switch (eventName) {
      case 'show':
      case 'hide':
      case kWindowEventMinimize:
      case kWindowEventRestore:
      case kWindowEventMaximize:
      case kWindowEventUnmaximize:
        unawaited(syncWindowVisible());
    }
    // Going to the tray is often the last thing a session does before
    // Windows shuts down around it, so the geometry is captured on the way.
    if (eventName == 'hide') saveWindowState();
    // Coming back into view, what it shows is brought up to date.
    if (eventName == 'show' ||
        eventName == kWindowEventRestore ||
        eventName == kWindowEventFocus) {
      _onWindowCameBack();
    }
  }

  /// Debounces the window's show, restore and focus events.
  Timer? _cameBackTimer;

  /// What the window shows is fetched again if it is old (see the screen's
  /// [onCameBack]). Nothing did this, so a grid left in the tray overnight
  /// came back showing last night. Debounced: one restore fires several of
  /// these, and alt-tabbing fires them constantly. Never while exiting:
  /// Exit shows the window first, for its dialogs, and from the tray that
  /// show is a window coming back too.
  void _onWindowCameBack() {
    _cameBackTimer?.cancel();
    _cameBackTimer = Timer(const Duration(milliseconds: 300), () {
      _cameBackTimer = null;
      if (_disposed || _isExiting) return;
      onCameBack();
    });
  }

  Timer? _windowSaveTimer;

  /// Debounced: a drag emits a stream of moves. The write is the
  /// repository's debounced one too, config only - every move, resize and
  /// trip to the tray rewrote the progress sidecar as well. Exit and session
  /// end capture the geometry and flush it themselves.
  void saveWindowState() {
    _windowSaveTimer?.cancel();
    _windowSaveTimer = Timer(const Duration(milliseconds: 300), () async {
      _windowSaveTimer = null;
      if (await captureWindowState()) {
        _repository.requestSave();
      }
    });
  }

  /// Copies the window's current geometry into the settings; returns whether
  /// there was anything to copy.
  ///
  /// Physical pixels and the monitor, from the runner. The logical fields
  /// are kept up to date in the meaning older builds gave them (divided by
  /// the window's own scale), so a downgrade still finds the window.
  Future<bool> captureWindowState() async {
    _windowSaveTimer?.cancel();
    _windowSaveTimer = null;
    try {
      final state = await _window.state();
      // Minimized, there is nothing new to say: the normal bounds are what
      // they were, and "maximized" is not readable until it is restored.
      if (state == null || state.minimized) return false;
      final s = state.scale;
      final settings = _settings();
      settings.windowPlacement = SavedWindowPlacement.fromState(state);
      settings.windowX = state.bounds.left / s;
      settings.windowY = state.bounds.top / s;
      settings.windowWidth = state.bounds.width / s;
      settings.windowHeight = state.bounds.height / s;
      settings.isWindowMaximized = state.maximized;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void onWindowResized() => saveWindowState();

  @override
  void onWindowMoved() => saveWindowState();

  @override
  void onWindowMaximize() => saveWindowState();

  @override
  void onWindowUnmaximize() => saveWindowState();

  @override
  void onWindowClose() async {
    final isPreventClose = await _window.isPreventClose();
    if (!isPreventClose) return;
    // Already quitting, for Exit or for an update, or handing over to the
    // updater (see _handingOverToUpdater). The updater closes the window of
    // an app that has not exited by the end of its wait, or at once when it
    // cannot wait on this process (an updater from before --wait-pid, a pid
    // it could not open); hiding to the tray, with its one-time "still
    // running" toast, would be the wrong answer to any of them.
    // A user's own close in the handover's few seconds is lost with it.
    if (_isExiting || _handingOverToUpdater) return;
    if (_settings().closeAction == 'exit') {
      await requestExit();
      return;
    }
    await hideWindow();
    _maybeShowTrayNotice();
  }

  @override
  void onWindowMinimize() async {
    // Default is the Windows convention (taskbar); 'tray' preserves the old
    // behavior for users who want it.
    if (_settings().minimizeAction == 'tray') {
      await hideWindow();
    }
  }

  /// One-time heads-up that closing the window left the app running.
  Future<void> _maybeShowTrayNotice() async {
    final settings = _settings();
    if (settings.trayNoticeShown) return;
    settings.trayNoticeShown = true;
    await _repository.saveNow();
    try {
      await _notifications.show(AppNotification(
        title: 'Still running in the tray',
        body:
            'Twitch Streamlink GUI keeps monitoring your favorites. Right-click the tray icon and choose Exit to quit for real. You can change the close behavior in Settings.',
        silent: true,
      ));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // The tray

  /// Signature of the last-built tray menu. system_tray 2.0.3 leaks the
  /// native HMENU on every setContextMenu, so the menu is only rebuilt when
  /// the live-favorites set actually changes - never per poll.
  String? _traySignature;

  Future<void> _initTray() async {
    await _tray.init(
      title: "Twitch Streamlink GUI",
      iconPath: 'assets/app_icon.ico',
      toolTip: "Twitch Streamlink GUI",
    );
    await rebuildTrayMenu();

    _tray.onEvent((event) {
      if (event == TrayEvent.click || event == TrayEvent.doubleClick) {
        showWindow();
      } else if (event == TrayEvent.rightClick) {
        _tray.popUpMenu();
      }
    });
  }

  /// Rebuilds the menu, its tooltip and its icon if the live favourites it
  /// lists changed - or, with [force], because the setting that shows them
  /// may have.
  Future<void> rebuildTrayMenu({bool force = false}) async {
    if (force) _traySignature = null;
    final liveNames = _settings().trayLiveMenuEnabled
        ? _liveFavorites().take(5).toList()
        : <String>[];
    final signature = liveNames.join('|');
    if (signature == _traySignature) return;
    _traySignature = signature;

    try {
      await _tray.setMenu([
        for (final name in liveNames)
          // Resolved by name at click time (onTrayWatch): menu items can
          // outlive a poll cycle.
          TrayMenuEntry('Watch $name', () => onTrayWatch(name)),
        if (liveNames.isNotEmpty) const TrayMenuEntry.separator(),
        TrayMenuEntry('Show App', showWindow),
        TrayMenuEntry('Hide App', hideWindow),
        TrayMenuEntry('Open Library', () async {
          await showWindow();
          onTrayOpenLibrary();
        }),
        const TrayMenuEntry.separator(),
        TrayMenuEntry('Exit', requestExit),
      ]);
      await _tray.setToolTip(
        liveNames.isEmpty
            ? 'Twitch Streamlink GUI'
            : 'Twitch Streamlink GUI - ${liveNames.length} favorite${liveNames.length == 1 ? '' : 's'} live',
      );
      await _tray.setImage(
        liveNames.isEmpty ? 'assets/app_icon.ico' : 'assets/app_icon_live.ico',
      );
    } catch (_) {
      // A failed tray refresh must never break polling; retry on next change.
      _traySignature = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Exit

  /// Set while an exit request is being answered (its dialogs are open), so a
  /// second Exit from the tray does not stack a second set on top.
  bool _exitRequestOpen = false;

  /// Set once the app has committed to quitting.
  bool get isExiting => _isExiting;
  bool _isExiting = false;

  /// Exit from the tray, or a close with "close exits" set.
  Future<void> requestExit() async {
    if (_exitRequestOpen || _isExiting) return;
    _exitRequestOpen = true;
    try {
      await showWindow();

      // The binaries are being replaced underneath the process and the
      // update restarts the app by itself; quitting now would leave neither
      // the old version running nor the new one installed. The update's own
      // failure path re-enables this.
      if (_isUpdateInProgress) {
        showMessage('An update is being installed. The app restarts by itself '
            'when it is done.');
        return;
      }

      if (!await confirmExit()) return;
      // A dialog answered while an update started (from Settings, say) must
      // not quit underneath it either.
      if (_isUpdateInProgress) return;
    } finally {
      _exitRequestOpen = false;
    }

    await shutDownAndExit();
  }

  /// Makes sure the saved download queue is on disk before the downloads are
  /// stopped, so they resume after the app restarts. Shared by the tray-exit
  /// and update paths, which check storageWriteFailure right after.
  ///
  /// The queue is saved as it changes now (DownloadsController), so this
  /// only makes the last change land immediately rather than a second later.
  /// Stopping the downloads afterwards does not take them off the saved
  /// queue: only completing, failing or being cancelled does.
  Future<void> persistQueueForRestart() => _repository.saveNow();

  /// Everything that has to happen before the process goes, then the exit.
  ///
  /// No Dart runs after windowManager.destroy(): the runner tears the engine
  /// down as soon as its message loop ends. Anything still pending then was
  /// lost - the debounced window save (a 300ms timer that never fired), a
  /// progress write still queued, the tray icon left behind until the mouse
  /// passed over it - and players were killed without being waited for.
  Future<void> shutDownAndExit() async {
    if (_isExiting) return;
    _isExiting = true;
    final log = CrashLog.current;
    log?.milestone('[exit] requested');
    // A line per step, timed from the request: an exit seen taking 6.9s
    // (against well under one second usually) left nothing to say which
    // step it was.
    final steps = TimedMilestones('exit', log);

    // Nothing new may start while this runs - including the refresh a
    // window coming back arms. Exit shows the window first (for its
    // dialogs), so its own show and focus armed one, and it fired in the
    // middle of the shutdown, which waits up to five seconds on the players.
    onExitCommitted();
    _cameBackTimer?.cancel();
    _cameBackTimer = null;

    // The window's last geometry, now rather than in 300ms.
    await captureWindowState();

    // Players and downloads first, so whatever their stopping reports (a
    // final watch position, a download's resume state) is already in memory
    // when the saves below snapshot it.
    await stopAllBounded('exit');
    steps.mark('players stopped');

    // Each save resolves only once its file's writer has drained, earlier
    // fire-and-forget writes to the same file included - and the config,
    // progress and recents all go, including a watch position the progress
    // delay was still holding. A file not yet read at startup is left alone.
    try {
      await _repository.flushNow();
    } catch (e, st) {
      log?.error('exit: saving', e, st);
    }
    steps.mark('saved');

    _window.removeListener(this);
    _singleInstanceChannel.setMethodCallHandler(null);
    SessionEnd.stopListening();
    try {
      await _tray.destroy();
    } catch (_) {}
    steps.mark('tray destroyed');

    log?.milestone('[exit] saved and stopped; closing');
    await _window.destroy();
  }

  /// [stopAll], awaited but never for longer than [stopAllTimeout].
  ///
  /// Awaited so the children are gone before the saves (exit) or the binary
  /// swap (update). Unbounded, a taskkill that never returned would strand
  /// the app: the exit guard ignores every later Exit, so the window could
  /// not be closed, and the update dialog has no way out at all. Going on is
  /// safe: the runner's kill-on-close job ends whatever is left when this
  /// process goes, and the updater ends what runs from the install folder
  /// before it swaps.
  Future<void> stopAllBounded(String during) async {
    try {
      await _stopAll().timeout(stopAllTimeout);
    } on TimeoutException {
      CrashLog.current?.milestone('[$during] players still stopping after '
          '${stopAllTimeout.inSeconds}s; going on without them');
    } catch (e, st) {
      CrashLog.current?.error('$during: stopping players', e, st);
    }
  }

  /// Windows is ending the session: save what a restart should find.
  ///
  /// No dialogs and no stopping anything: the session is going whatever
  /// happens, and the runner only waits a few seconds. Downloads are ended
  /// by Windows along with everything else, and report that as failures, so
  /// the queue is frozen first ([onSessionEnding]) and resumes at the next
  /// launch.
  Future<void> _saveForSessionEnd() async {
    final log = CrashLog.current;
    log?.milestone('[session] Windows is ending the session; saving');
    onSessionEnding();
    try {
      await captureWindowState();
      await _repository.flushNow();
      log?.milestone('[session] saved');
    } catch (e, st) {
      log?.error('session end: saving', e, st);
    }
  }

  // ---------------------------------------------------------------------------
  // The update

  /// Whether the update prompt is up; the screen shows it.
  bool updatePromptOpen = false;

  /// From the user accepting an update until it fails: the binaries are
  /// being replaced, so Exit is refused and automation stands down.
  bool get isUpdateInProgress => _isUpdateInProgress;
  bool _isUpdateInProgress = false;

  /// An update is offered or installing; nothing new may start.
  bool get isUpdateActive => updatePromptOpen || _isUpdateInProgress;

  /// Set from just before the updater is started until the app is exiting
  /// for it, or the handover has failed.
  ///
  /// The updater signals that it is ready and may then close the window,
  /// while the app only sees the signal at its next poll, up to 50ms later,
  /// and only then starts exiting. A close landing in between went the
  /// normal way: hidden to the tray with the "still running" toast, or an
  /// Exit request refused because an update is running.
  bool _handingOverToUpdater = false;

  /// Downloads, verifies and applies [info], then exits for the updater.
  ///
  /// [report] is given each new status line, and the download's progress as
  /// a [fraction] of one.
  /// Throws what stopped it, once the app is running as before again and
  /// can be closed as usual; the caller tells the user.
  Future<void> applyUpdate(
    UpdateInfo info, {
    required void Function({String? status, double? fraction}) report,
  }) async {
    _isUpdateInProgress = true;
    Directory? extractDir;
    var updaterStarting = false;
    var handedOver = false;
    try {
      final zipFile = await _updates.downloadUpdate(info.downloadUrl, (pct) {
        report(fraction: pct);
      });

      report(status: 'Verifying download integrity...', fraction: 0.0);
      await _updates.verifyChecksum(zipFile, info.checksumUrl);

      report(status: 'Extracting update files...');
      extractDir = await _updates.extractAndVerifyZip(zipFile);

      report(status: 'Closing running downloads and streams...');

      // Now, so the save of the resume list below writes it too: if the
      // updater has to end this process before its own shutdown finishes,
      // the geometry is already on disk.
      await captureWindowState();

      // Shut down cleanly before the installation is replaced. This path
      // previously called exit(0) directly: streamlink/yt-dlp children were
      // orphaned and kept writing while the updater swapped the very
      // binaries they were running from, and any in-flight downloads were
      // lost with no resume record.
      await persistQueueForRestart();
      // Same reasoning as the tray exit, without a second modal on top of
      // the progress dialog: if the resume list did not reach disk, stop
      // before killing the downloads it was meant to describe. The update
      // is still there to apply once the disk problem is resolved.
      final saveFailure = storageWriteFailure.value;
      if (saveFailure != null) {
        throw Exception(
            'could not save the download queue (${saveFailure.path}), so the '
            'update was not applied. Downloads in progress are untouched.');
      }
      // Awaited: stopAll() kills asynchronously, and the children must be
      // gone before the updater starts replacing the binaries they run
      // from. The job object and the updater's own sweep would end them
      // anyway, but not before the swap began. Bounded, because Exit is
      // refused while an update runs: a stop that never returned would
      // leave this dialog up with nothing the user could do about it.
      await stopAllBounded('update');

      report(status: 'Applying update and restarting...');
      updaterStarting = true;
      _handingOverToUpdater = true;
      await _updates.startUpdater(extractDir);
      handedOver = true;
    } catch (_) {
      _handingOverToUpdater = false;
      _isUpdateInProgress = false;
      // The extracted build is ~300 MB that only a sweep a day later would
      // reclaim. Safe to delete while no updater can be copying out of it,
      // which is every failure before startUpdater began; that
      // method cleans up its own failures before it starts the updater,
      // and after it, a late updater may still need the files.
      final extracted = extractDir;
      if (extracted != null && !updaterStarting) {
        unawaited(_updates.discardExtractedUpdate(extracted));
      }
      rethrow;
    }
    if (handedOver) await _exitForUpdate();
  }

  /// Leaves for the updater, which is now running outside this app's job and
  /// waits for the process to end before it swaps the files and relaunches.
  ///
  /// The same way out as Exit: the saves flushed, the tray icon removed, the
  /// runner's ordered teardown. This used to be a Dart exit(0) inside the
  /// update service, which skipped all of it and left a ghost tray icon
  /// beside the relaunched app until the mouse passed over it.
  Future<void> _exitForUpdate() async {
    CrashLog.current?.milestone('[update] updater started; exiting for it');
    try {
      await shutDownAndExit();
    } catch (e, st) {
      // Never stay up half shut down: the updater is waiting on this
      // process, and would end it within half a minute regardless.
      CrashLog.current?.error('update: shutting down', e, st);
      exit(0);
    }
  }
}
