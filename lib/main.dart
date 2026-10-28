import 'dart:async';
import 'package:flutter/material.dart';

import 'app_services.dart';
import 'app_startup.dart';

import 'models/app_settings.dart';
import 'models/twitch_channel.dart';
import 'models/twitch_video.dart';
import 'services/crash_log.dart';
import 'services/desktop_shell.dart';
import 'services/storage_service.dart';
import 'state/twitch_auth_notifier.dart';
import 'state/watch_history_controller.dart';
import 'utils/twitch_auth_status.dart';
import 'services/twitch_api_service.dart';
import 'services/player_service.dart';
import 'services/update_service.dart';
import 'services/log_store.dart';
import 'state/activity_state.dart';
import 'state/download_history.dart';
import 'state/settings_repository.dart';
import 'state/settings_save.dart';
import 'services/downloads_controller.dart';
import 'widgets/shell/announcements.dart';
import 'widgets/shell/app_dialogs.dart';
import 'widgets/shell/app_frame.dart';
import 'widgets/shell/app_snackbar.dart';
import 'widgets/shell/channel_actions.dart';
import 'widgets/shell/channel_dashboard.dart';
import 'widgets/shell/home_view.dart';
import 'widgets/shell/player_events.dart';
import 'widgets/shell/status_banners.dart';
import 'widgets/shell/update_flow.dart';
import 'widgets/shell/vod_actions.dart';
import 'widgets/shell/app_layout.dart';
import 'widgets/shell/motion.dart';
import 'state/channels_controller.dart';
import 'state/vod_browser_controller.dart';
import 'state/vod_selection.dart';
import 'widgets/log_viewer_dialog.dart';
import 'widgets/sidebar_panel.dart';
import 'widgets/settings_dialog.dart';

import 'state/account_controller.dart';
import 'state/app_shell_controller.dart';
import 'state/library_controller.dart';
import 'state/stored_config.dart';
import 'widgets/library_view.dart';
import 'widgets/onboarding_wizard.dart';
import 'services/automation_service.dart';
import 'theme/material/lit_surface.dart';
import 'theme/app_theme.dart';
import 'theme/neu_theme.dart';
import 'widgets/neumorphic/neu_pulse.dart';
import 'theme/theme_notifier.dart';


Future<void> main(List<String> args) async {
  // One guarded zone around everything: the binding, the startup and runApp
  // must share a zone, and an error thrown anywhere in them has to reach the
  // crash log. A release build has no console, so before this an exception
  // here simply ended startup - with the window never shown - and left nothing
  // behind to say why.
  await runZonedGuarded<Future<void>>(
    () => startApp(args,
        app: (startup, startHidden) => TwitchStreamlinkApp(
            startup: startup, startHidden: startHidden)),
    (error, stack) {
      final log = CrashLog.current;
      if (log != null) {
        log.error('zone', error, stack);
      } else {
        debugPrint('Uncaught before the crash log opened: $error\n$stack');
      }
    },
  );
}

class TwitchStreamlinkApp extends StatefulWidget {
  const TwitchStreamlinkApp({
    super.key,
    this.startup,
    this.startHidden = false,
    this.services,
  });

  /// The config as main() read it, for the first load.
  final StartupConfig? startup;

  /// The window starts hidden to the tray.
  final bool startHidden;

  /// See [MainScreen.services].
  final AppServices? services;

  @override
  State<TwitchStreamlinkApp> createState() => _TwitchStreamlinkAppState();
}

class _TwitchStreamlinkAppState extends State<TwitchStreamlinkApp> {
  /// The shell's live heartbeat, provided ABOVE the navigator.
  ///
  /// Provided from MainScreen's own build it would reach only the main route,
  /// and the LEDs in dialogs - routes of their own - would keep private
  /// controllers. The controller lives in MainScreen (it is gated on what is
  /// live there), below the navigator, so this proxy is what the tree sees:
  /// MainScreen attaches its controller, and until then it rests at 1.0, the
  /// parked value.
  final ProxyAnimation _shellPulse = ProxyAnimation(kAlwaysCompleteAnimation);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeNotifier,
      builder: (context, _) {
        final isDark = themeNotifier.isDarkTheme;
        return MaterialApp(
          title: 'Twitch Streamlink GUI',
          debugShowCheckedModeBanner: false,
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          // Rebuilt per notification: both read the live accent and the
          // active material.
          theme: buildAppTheme(isDark: false),
          darkTheme: buildAppTheme(isDark: true),
          builder: (context, child) => NeuPulse(
            pulse: _shellPulse,
            child: child ?? const SizedBox.shrink(),
          ),
          home: MainScreen(
            startup: widget.startup,
            startHidden: widget.startHidden,
            shellPulse: _shellPulse,
            services: widget.services,
          ),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    this.startup,
    this.startHidden = false,
    this.shellPulse,
    this.services,
  });

  /// The config main() read at startup. Used by the first load only.
  final StartupConfig? startup;

  /// The window starts hidden to the tray, so it is not on screen.
  final bool startHidden;

  /// Where the shell's heartbeat is published for the whole app; see
  /// [_TwitchStreamlinkAppState._shellPulse].
  final ProxyAnimation? shellPulse;

  /// What the screen talks to outside itself; the real ones when null.
  final AppServices? services;

  bool get isFirstRun => startup?.isFirstRun ?? false;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  // Services (see AppServices). Late, so they are read from the widget once
  // it is mounted.
  late final AppServices _services = widget.services ?? AppServices();
  late final StorageService _storageService = _services.storage;
  late final TwitchApiService _apiService = _services.api;
  late final PlayerService _playerService = _services.player;
  late final AppWindow _window = _services.window;
  late final AppNotifications _notifications = _services.notifications;

  // Logging
  final LogNotifier _logNotifier = LogNotifier();

  // UI state variables
  final List<TwitchChannel> _channels = [];
  TwitchChannel? _selectedChannel;
  bool _isGlobalLoading = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _sidebarSearchFocus = FocusNode();
  final GlobalKey<SidebarPanelState> _sidebarKey = GlobalKey<SidebarPanelState>();
  bool _isAdding = false;
  
  AppSettings _settings = AppSettings();
  
  Timer? _favoritesLiveCheckTimer;
  Timer? _downloadCheckTimer;
  
  List<TwitchChannel> get _followedChannels => _channelsCtl.followed;
  bool get _isLoadingFollowed => _channelsCtl.isLoadingFollowed;
  int _sidebarTab = 0; 
  
  // The open channel's VOD list lives in _vodBrowser (see the refresh block
  // by _selectChannel); these read it for the code that predates it.
  List<TwitchVideo> get _channelVods => _vodBrowser.vods;
  set _vodsError(String? value) => _vodBrowser.error = value;

  /// The open channel's game filter, search and selection (VodSelection).
  final VodSelection _selection = VodSelection();
  AnimationController? _pulseController;
  bool _sidebarCollapsed = false;
  bool _isWebTokenExpired = false;
  Set<String> _downloadedVodIds = {};
  Map<String, String> _downloadedVodsRegistry = {};

  /// Every VOD ever downloaded, file or no file, or cancelled by the user,
  /// so auto-download never fetches one twice (DownloadHistory); saved with
  /// the registry.
  final DownloadHistory _downloadHistory = DownloadHistory();

  /// Watch positions, the recently-watched list and the VODs playing
  /// (WatchHistoryController); wired to PlayerService in initState.
  late final WatchHistoryController _history = WatchHistoryController(
    storage: _storageService,
    repository: _settingsRepo,
    api: _apiService,
    settings: () => _settings,
    openVods: () => _channelVods,
    log: _logNotifier.appendLog,
    onLoadError: (e, st) =>
        CrashLog.current?.error('loading watch history', e, st),
    clock: _services.clock,
  );

  /// What a channel's own buttons do (ChannelActions): add, star or unstar,
  /// watch live.
  late final ChannelActions _channelActions = ChannelActions(
    channels: _channelsCtl,
    favorites: _channels,
    automation: _automation,
    player: _playerService,
    api: _apiService,
    settings: () => _settings,
    context: () => context,
    mounted: () => mounted,
    showMessage: _showSnackBar,
    save: _saveChannels,
    select: _selectChannel,
    setAdding: (adding) => setState(() => _isAdding = adding),
    clearSearch: _searchController.clear,
    removed: (cleanName) {
      if (!mounted) return;
      setState(() {
        if (_selectedChannel?.username == cleanName) _selectedChannel = null;
      });
    },
    changed: () {
      if (mounted) setState(() {});
    },
  );

  /// What a VOD's own buttons do (VodActions): play, download, cancel and
  /// delete, one VOD or a selection.
  late final VodActions _vods = VodActions(
    player: _playerService,
    api: _apiService,
    history: _history,
    settings: () => _settings,
    registry: () => _downloadedVodsRegistry,
    context: () => context,
    mounted: () => mounted,
    showMessage: _showSnackBar,
    save: _saveChannels,
    rescan: _checkDownloadedVods,
    changed: () {
      if (mounted) setState(() {});
    },
  );

  /// What the player service reports, and where each report goes
  /// (PlayerEvents); bound in initState.
  late final PlayerEvents _players = PlayerEvents(
    player: _playerService,
    logs: _logNotifier,
    history: _history,
    downloads: _downloads,
    downloadHistory: _downloadHistory,
    registry: () => _downloadedVodsRegistry,
    repository: _settingsRepo,
    settings: () => _settings,
    clock: _services.clock,
    mounted: () => mounted,
    repaint: () => setState(() {}),
    updatePulse: _updatePulse,
    rescan: _checkDownloadedVods,
    libraryChanged: _library.refreshIfOpen,
    showMessage: _showSnackBar,
    viewLog: _viewLogAction,
    windowHidden: _shell.isHidden,
    notify: (title, body) => _notify(title, body),
  );

  // ---- Persistence and downloads -------------------------------------------
  // When the three files are written (SettingsRepository) and the saved
  // download queue plus the downloaded-file scan (DownloadsController). Both
  // are created on first use rather than in initState, so a save asked for
  // from anywhere, however early, finds them ready. Wired to PlayerService
  // and the session-end channel in initState.

  late final SettingsRepository _settingsRepo = SettingsRepository(
    writeConfig: _writeConfigFile,
    writeProgress: () =>
        _storageService.saveWatchProgress(_history.store.toJson()),
    writeRecents: () => _storageService.saveRecentWatchedVods(
        _history.recents.map((v) => v.toJson()).toList()),
    onError: (e, st) => CrashLog.current?.error('saving', e, st),
  );

  late final DownloadsController _downloads = DownloadsController(
    onQueueChanged: () => _settingsRepo.requestSave(),
    readScanInput: _downloadScanInput,
    onScanned: _applyDownloadScan,
  );

  // ---------------------------------------------------------------------------

  /// Set when the user dismisses the save-failure banner, so a persistent
  /// disk problem does not become an undismissable wall. Reset whenever a save
  /// succeeds, so a NEW failure is reported again.
  bool _saveWarningDismissed = false;

  /// Whether the startup sequence has finished: the poll, a window coming
  /// back and a token that starts working again (AccountController) all wait
  /// for it.
  bool _startupComplete = false;

  /// Re-arms the save-failure banner once a save succeeds, so a dismissal
  /// covers the problem the user saw and not every future one.
  ///
  /// A method, so dispose can take it off again: storageWriteFailure is
  /// global and outlives this screen, and the closure added here was never
  /// removed - one more listener holding a dead State for every screen that
  /// was ever built.
  void _onSaveFailureChanged() {
    if (!mounted) return;
    if (storageWriteFailure.value == null && _saveWarningDismissed) {
      setState(() => _saveWarningDismissed = false);
    } else {
      setState(() {});
    }
  }

  /// The Library screen: whether it shows, its cached rows, and what their
  /// buttons do (LibraryController).
  late final LibraryController _library = LibraryController(
    registry: () => _downloadedVodsRegistry,
    recents: () => _history.recents,
    localProgress: () => _history.flat,
    channelNames: () => _playerService.downloadChannelNames,
    downloadRoot: () => _settings.vodDownloadFolder,
    rescan: _checkDownloadedVods,
    play: _vods.play,
    deleteDownload: _vods.deleteDownload,
    confirmDelete: (title) => confirmDeleteDownload(context, title),
    forget: _history.forget,
  );

  /// The log viewer's entry for the app itself, beside the per-process ones.
  static const String _appLogKey = 'app';

  /// Puts what support asks first - which surface engine is painting, and
  /// where the crash log is - where "Copy all" in the log viewer picks it up.
  void _logAppDiagnostics() {
    _logNotifier.beginSession(_appLogKey, 'App');
    _logNotifier.appendLog(
        _appLogKey, '[System] Surface engine: ${LitSurfaceProgram.status}');
    final crashLog = CrashLog.current;
    if (crashLog != null) {
      _logNotifier.appendLog(
          _appLogKey, '[System] Crash log: ${crashLog.file.path}');
    }
    // Not a process: it has nothing to finish, so it is shown as done
    // rather than as running forever.
    _logNotifier.endSession(_appLogKey, 0);
  }
  // ---- Favorites automation (AutomationService) ----------------------
  // The pass, its once-at-a-time guard and the auto-played session memory
  // live in AutomationService; these closures are its view of the screen,
  // read at call time exactly as the inline code read these fields.
  late final AutomationService _automation = AutomationService(
    favorites: () => _channels,
    settings: () => _settings,
    runningChannels: () => _playerService.runningChannels,
    isWatchingVod: () => _isWatchingVod,
    isUpdateActive: () => _shell.isUpdateActive,
    playLive: (channel) => _playerService.launchStreamlinkForLive(
      channel.username,
      channel.isLive,
      channel.streamTitle,
      channel.game,
      _settings,
    ),
    stopLive: (channel) => _playerService.killLiveStream(channel),
    fetchVods: (channel) => _apiService.fetchVodsForChannel(
      channel: channel,
      settings: _settings,
      localVodsProgress: _history.flat,
      // This pass renders nothing, so the per-VOD game lookup is pure
      // overhead. It runs for every auto-download channel every minute.
      fetchGames: false,
      // Positions only for the VODs it would queue (readWatchProgress).
      fetchWatchProgress: false,
    ),
    readWatchProgress: (vods) => _apiService.fetchWatchProgressFor(
      vods: vods,
      settings: _settings,
      localVodsProgress: _history.flat,
    ),
    clock: _services.clock,
    localProgress: () => _history.flat,
    isVodHandled: (vodId) =>
        _downloadedVodsRegistry.containsKey(vodId) ||
        _playerService.activeDownloadTasks.containsKey(vodId) ||
        _playerService.activeDownloadProcesses.containsKey(vodId) ||
        _playerService.downloadQueue.contains(vodId),
    wasDownloaded: _downloadHistory.contains,
    queueDownload: (vod, channel, {overrideDisablePostProcessing}) =>
        _playerService.queueVodDownload(
      vod,
      channel.username,
      _settings,
      overrideDisablePostProcessing: overrideDisablePostProcessing,
    ),
    showNotification: (title, body) =>
        _notifications.show(AppNotification(title: title, body: body)),
    // What this pass already paid for reaches the VOD cache and, for the
    // open channel, the grid (VodBrowserController.ingest). It used to be
    // thrown away every minute. These lists skipped the game lookup, hence
    // detailed: false.
    onVodsFetched: (channel, result, fetchedAt) {
      if (_vodBrowser.ingest(channel, result,
          fetchedAt: fetchedAt, detailed: false)) {
        _checkDownloadedVods();
      }
    },
  );
  // ---- end favorites automation ---------------------------------------

  @override
  void initState() {
    super.initState();
    _shell.attach();

    // Created stopped. It used to `..repeat(reverse: true)` here and was
    // only ever touched again by dispose(), so it drove a 60fps rebuild for
    // the entire life of the process - including while the app sat in the
    // tray, which is its normal resting state, with nothing live to pulse.
    // Parked at 1.0, the value a stopped pulse settles at, so nothing that
    // breathes with it starts out dimmed.
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
      value: 1.0,
    );
    // Every pulsing indicator in the app - dialogs included - breathes with
    // this one controller, through the NeuPulse above the navigator.
    widget.shellPulse?.parent = _pulseController;

    _logAppDiagnostics();

    // Every report the player service makes, routed (PlayerEvents).
    _players.bind(
        archivePath:
            _storageService.getStorageFile('yt_dlp_archive.txt').path);

    // Channel and VOD refresh wiring: lib/state/channels_controller.dart and
    // vod_browser_controller.dart, driven from the block by _selectChannel.
    // Before _loadChannels, whose startup pass already reports through it.
    // The VOD browser, the watch history and the Library repaint only what
    // shows them (see build); the channels show nearly everywhere.
    _channelsCtl.addListener(_onRefreshStateChanged);
    _channelsCtl.onPass = _onChannelsPass;
    _vodBrowser.onNewVods = _announcements.newVods;

    storageWriteFailure.addListener(_onSaveFailureChanged);
    _account
      ..attach()
      ..addListener(_onRefreshStateChanged);
    _loadChannels();
    
    _downloadCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkDownloadedVods();
    });

    _favoritesLiveCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _onPollTick();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // First-run wizard fully resolves BEFORE the update check, so the
      // update prompt can never stack under (or over) the wizard dialog.
      await _runOnboarding();
      _checkForAppUpdates();
    });
  }

  Future<void> _runOnboarding() async {
    if (!widget.isFirstRun || _settings.onboardingCompleted) return;
    if (!mounted) return;
    final AppSettings? configured =
        await OnboardingWizard.show(context, settings: _settings);
    if (!mounted) return;
    setState(() {
      // Skipped/dismissed still marks completion - the wizard never returns.
      _settings = configured ?? _settings.copyWith(onboardingCompleted: true);
    });
    await _saveChannels();
    if (configured != null) {
      if (_settings.launchAtStartup) {
        _services.startup.sync(true);
      }
      if (_settings.twitchOauthToken.trim().isNotEmpty) {
        _account.loadFollowed();
      }
    }
  }

  Future<void> _checkForAppUpdates() async {
    try {
      final updateService = _services.updates;
      final updateInfo = await updateService.checkForUpdates();
      if (updateInfo != null && updateInfo.isUpdateAvailable && mounted) {
        _showUpdatePromptDialog(updateInfo);
      }
    } catch (_) {}
  }

  void _showUpdatePromptDialog(UpdateInfo info) {
    _shell.updatePromptOpen = true;
    showUpdatePrompt(context, info, onUpdate: () => _performAppUpdate(info)).then((_) {
      _shell.updatePromptOpen = false;
    });
  }

  void _performAppUpdate(UpdateInfo info) {
    runUpdateWithProgress(context, _shell, info, onFailed: (e) {
      // stopAll() may already have killed everything before the failure. The
      // app survives this path, so any session still marked running would
      // stay that way for the rest of the session - and eviction only
      // reclaims finished ones.
      _logNotifier.endAllRunning(-1);
      if (mounted) {
        // Matches the VOD fetch path: the user reads this, and
        // "Update failed: Exception: ..." is noise.
        _showSnackBar(
            'Update failed: ${e.toString().replaceFirst('Exception: ', '')}',
            isError: true);
      }
    });
  }

  /// The config file's contents, at the moment of writing.
  Future<void> _writeConfigFile() {
    // The saved queue is the controller's, stamped on at every write: a
    // settings object replaced wholesale must not bring back an old queue.
    final unfinished = _downloads.persisted;
    if (unfinished != null) _settings.unfinishedDownloads = unfinished;
    return _storageService.saveConfig(
        _channels, _settings, _history.flat, _downloadedVodsRegistry,
        downloadHistory: _downloadHistory.toJson());
  }

  /// Scroll state for the "Continue watching" strip, so its edges can fade.
  ///
  /// A horizontally scrolling row whose last card is hard-clipped at the window
  /// edge reads as a rendering fault rather than as "there is more" - which is
  /// exactly how it looked at 1181x720, one of the two sizes the screenshot
  /// matrix checks on either side of the wide-controls boundary.
  final ScrollController _recentScroll = ScrollController();
  bool _recentFadeLeft = false;
  bool _recentFadeRight = false;

  void _updateRecentFades() {
    if (!_recentScroll.hasClients) return;
    final max = _recentScroll.position.maxScrollExtent;
    final scrollable = max > 0.0;
    final left = scrollable && _recentScroll.offset > 2.0;
    final right = scrollable && _recentScroll.offset < max - 2.0;
    if (left != _recentFadeLeft || right != _recentFadeRight) {
      setState(() {
        _recentFadeLeft = left;
        _recentFadeRight = right;
      });
    }
  }

  @override
  void dispose() {
    _shell.dispose();
    // Detached before the controller goes: the proxy outlives this screen.
    widget.shellPulse?.parent = kAlwaysCompleteAnimation;
    _recentScroll.dispose();
    _selection.dispose();
    _pulseController?.dispose();
    _playerService.stopAll();
    _searchController.dispose();
    _sidebarSearchFocus.dispose();
    _downloadCheckTimer?.cancel();
    _favoritesLiveCheckTimer?.cancel();
    // Channel and VOD refresh wiring (see initState).
    _channelsCtl
      ..removeListener(_onRefreshStateChanged)
      ..dispose();
    _vodBrowser.dispose();
    _history.dispose();
    _library.dispose();
    // Persistence and downloads: anything still held is written out.
    _downloads.dispose();
    _settingsRepo.dispose();
    storageWriteFailure.removeListener(_onSaveFailureChanged);
    _account
      ..removeListener(_onRefreshStateChanged)
      ..dispose();
    _players.dispose();
    _logNotifier.dispose();
    super.dispose();
  }

  // ---- The shell (AppShellController) ------------------------------------
  // The window, the tray, the way out and the update. These closures are its
  // view of the screen, read at call time.
  late final AppShellController _shell = AppShellController(
    window: _window,
    tray: _services.tray,
    notifications: _notifications,
    updates: _services.updates,
    repository: _settingsRepo,
    settings: () => _settings,
    stopAll: _playerService.stopAll,
    liveFavorites: () =>
        _channels.where((c) => c.isLive).map((c) => c.username),
    startHidden: widget.startHidden,
    // The window's visibility gates the pulse.
    onVisibilityChanged: _updatePulse,
    onCameBack: _onWindowCameBack,
    confirmExit: _confirmExit,
    showMessage: (message) => _showSnackBar(message, isError: false),
    onTrayWatch: _channelActions.watchFromTray,
    onTrayOpenLibrary: _library.open,
    // Nothing new may start while the exit runs.
    onExitCommitted: () {
      _favoritesLiveCheckTimer?.cancel();
      _downloadCheckTimer?.cancel();
    },
    onSessionEnding: _downloads.freeze,
    onSessionContinues: _downloads.unfreeze,
  );
  // ---- end shell -------------------------------------------------------------

  /// What an Exit asks before it goes (see AppShellController.requestExit):
  /// whether to pause the downloads that are running, and whether to go
  /// anyway if their queue could not be saved. True to exit.
  Future<bool> _confirmExit() async {
    final hasUnfinished = _playerService.activeDownloadProcesses.isNotEmpty || _playerService.downloadQueue.isNotEmpty;
    if (!hasUnfinished) return true;
    if (!mounted) return false;
    final bool? confirmExit = await confirmExitWithDownloads(context);

    if (confirmExit != true) {
      return false;
    }

    await _shell.persistQueueForRestart();

    // They chose "Exit & Save Queue". If that save did not reach disk,
    // exiting now loses the queue with no trace - and the banner that would
    // normally report it goes with the window.
    if (storageWriteFailure.value != null && mounted) {
      final bool? exitAnyway = await confirmExitWithUnsavedQueue(context, storageWriteFailure.value?.path);
      if (exitAnyway != true) return false;
    }
    return true;
  }

  /// Runs the shared pulse only when something is actually pulsing and the
  /// user can see it.
  ///
  /// Deliberately ONE controller rather than one per consumer: every pulse in
  /// the app means the same thing ("this is live"), and independent
  /// controllers would drift out of phase, so a sidebar of live channels would
  /// shimmer instead of breathe.
  ///
  /// The LEDs follow this gate too, dialogs included (see NeuPulse): a
  /// pulsing LED only ever marks something live, so "nothing live" and "an
  /// LED is breathing" cannot both be true - with one exception this gate now
  /// covers, the open channel. Its header shows a breathing LED and badge
  /// while it is live, and a live followed channel that is not a favourite
  /// used to leave both parked.
  void _updatePulse() {
    final controller = _pulseController;
    if (controller == null) return;

    final somethingLive = _channels.any((c) => c.isLive) ||
        (_selectedChannel?.isLive ?? false) ||
        _playerService.runningChannels.isNotEmpty ||
        _playerService.playingVodIds.isNotEmpty;
    // Gated here rather than in each consumer, so honouring the setting is not
    // something five widgets each have to remember.
    final reducedMotion = mounted && NeuMotion.reduced(context);
    final shouldRun = somethingLive && _shell.windowVisible && !reducedMotion;

    if (shouldRun && !controller.isAnimating) {
      controller.repeat(reverse: true);
    } else if (!shouldRun && controller.isAnimating) {
      controller.stop();
      // Settle at full value rather than wherever it happened to stop, so a
      // paused pulse does not leave a badge stuck at 40% opacity.
      controller.value = 1.0;
    }
  }

  /// Brings the downloaded badges and the registry in step with the disk.
  ///
  /// Asynchronous now: the scan runs off the UI isolate, one folder listing
  /// per pass, and its result arrives in [_applyDownloadScan]. Calls while a
  /// scan is running fold into one follow-up pass (DownloadsController).
  void _checkDownloadedVods() {
    unawaited(_downloads.rescan());
  }

  /// What the next scan looks at, as it is right now.
  DownloadScanInput _downloadScanInput() => DownloadScanInput(
        downloadRoot: _settings.vodDownloadFolder.trim(),
        channelName: _selectedChannel?.username ?? '',
        vodIds: [for (final vod in _channelVods) vod.id],
        registry: Map<String, String>.from(_downloadedVodsRegistry),
        inFlight: {
          ..._playerService.activeDownloadTasks.keys,
          ..._playerService.activeDownloadProcesses.keys,
          ..._playerService.downloadQueue,
        },
      );

  void _applyDownloadScan(DownloadScanOutcome outcome) {
    if (!mounted) return;
    for (final vodId in outcome.stripFromArchive) {
      _playerService.removeVodFromArchive(vodId);
    }
    if (outcome.registryChanged) {
      _downloadedVodsRegistry
          .removeWhere((vodId, _) => outcome.prune.contains(vodId));
      _downloadedVodsRegistry.addAll(outcome.additions);
      // A file found on disk was downloaded, by this app or another build.
      _downloadHistory.addAll(outcome.additions.keys, _services.clock());
      _settingsRepo.requestSave();
      // The Library was built from the registry before this scan came back.
      _library.refreshIfOpen();
    }

    // Only when the badges actually change. This rebuilt the whole screen
    // every ten seconds, scan or no news, for as long as the app ran - the
    // tray included. Unverified entries stay badged: their location is
    // merely unreachable right now, and flickering the badge off for an
    // unplugged drive is a worse lie than leaving it on.
    final downloaded = outcome.downloaded;
    if (downloaded.length != _downloadedVodIds.length ||
        !downloaded.containsAll(_downloadedVodIds)) {
      setState(() => _downloadedVodIds = outcome.downloaded);
    }
  }

  /// Queues the downloads the last run left unfinished.
  ///
  /// Their saved copy was adopted by DownloadsController.restore when the
  /// config loaded, and is NOT cleared here: this used to empty it and save
  /// before queueing anything, so from then on the resumed queue lived only
  /// in memory, and a crash an hour later lost every item.
  void _resumeUnfinishedDownloads(List<ResumableDownload> downloads) {
    for (final download in downloads) {
      _playerService.queueVodDownload(
          download.vod, download.channelName, _settings);
    }
    if (downloads.isNotEmpty) {
      _showSnackBar('Resumed ${downloads.length} unfinished downloads.', isError: false);
    }
  }

  /// Whether the first load has consumed [MainScreen.startup].
  bool _startupConfigUsed = false;

  /// The rest of the download history's seed (see [_loadChannels]): the VODs
  /// yt-dlp's archive records. Builds before the history never took a line
  /// out of the archive, so it lists every VOD they downloaded, deleted ones
  /// too. Beneath what the registry and the disk say, past the cap.
  Future<void> _seedDownloadHistoryFromArchive() async {
    final ids = await _playerService.readArchivedVodIds();
    if (!mounted) return;
    if (_downloadHistory.addBeneath(ids, _services.clock())) {
      _settingsRepo.requestSave();
    }
  }

  Future<void> _loadChannels() async {
    setState(() => _isGlobalLoading = true);
    try {
      // The snapshot main() already read and decrypted, for this first load
      // only; null there means there was none or it was quarantined, and
      // reading again would only find the same.
      final startup = widget.startup;
      final config = startup != null && !_startupConfigUsed
          ? startup.data
          : await _storageService.loadConfig();
      _startupConfigUsed = true;
      List<TwitchChannel> loadedChannels = [];

      if (config != null) {
        // Each part read on its own, so one that cannot be read does not take
        // the rest with it (StoredConfig).
        final stored = StoredConfig.parse(config);
        loadedChannels = stored.channels;
        if (stored.skippedChannels > 0) {
          print('[Config] Skipped ${stored.skippedChannels} unreadable channel entries.');
        }
        if (stored.settingsError != null) {
          print('[Config] Settings unreadable, using defaults: ${stored.settingsError}');
        }
        final storedSettings = stored.settings;
        if (storedSettings != null) {
          try {
          setState(() {
            _settings = storedSettings;
            _sidebarCollapsed = _settings.sidebarCollapsed;
            // The Followed/Live tabs are hidden without a token; restoring a
            // persisted tab index would strand the user on an invisible tab.
            _sidebarTab = _settings.twitchOauthToken.trim().isEmpty
                ? 0
                : _settings.activeSidebarTab;
            applyStoredLook(_settings);
          });
          } catch (e) {
            // Keep going with what was read rather than aborting the whole
            // load - the outer catch would abandon the channel list too, and
            // the next autosave would persist the loss.
            print('[Config] Settings unreadable, using defaults: $e');
          }
        }
        final progress = stored.localProgress;
        if (progress != null) _history.restoreFlat(progress);
        final registry = stored.registry;
        if (registry != null) _downloadedVodsRegistry = registry;
        // A config from before the download history starts it from what the
        // registry holds, and from yt-dlp's archive once that is read - every
        // VOD downloaded so far, so the upgrade does not fetch each again the
        // next time retention or the user deletes it.
        _downloadHistory.restore(stored.downloadHistory,
            seed: _downloadedVodsRegistry.keys, now: _services.clock());
        if (stored.downloadHistory == null) {
          unawaited(_seedDownloadHistoryFromArchive());
        }
      }

      _channels.clear();
      // No seeded starter channel: a stranger's channel confused new users
      // and fired unsolicited API calls and go-live notifications on first
      // launch. The welcome screen points at the sidebar search instead.
      if (loadedChannels.isNotEmpty) {
        _channels.addAll(loadedChannels);
      }

      // The saved download queue is adopted before anything can save the
      // config, and stays saved until each item finishes; the downloads
      // themselves are queued once the first frame is up.
      final resumable = _downloads.restore(_settings.unfinishedDownloads);
      if (resumable.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _resumeUnfinishedDownloads(resumable);
        });
      }
      // Everything the config holds is in memory now, so it may be written.
      _settingsRepo.markConfigLoaded();

      // The watch history next, BEFORE any network wait. It used to be read
      // last, after the refresh below, and anything that saved meanwhile -
      // the resume above, the window settling - first rewrote the sidecar
      // from the flat copy, erasing every furthest point and undo trail.
      // Until markHistoryLoaded, no write can reach either file.
      await _history.load();

      await _refreshAllChannels(isInitialLoad: true);
      // Ask Twitch whether the token works BEFORE using it. The old gate was
      // `isNotEmpty`, which is a test of the string and not of the account, so
      // a revoked token spent every launch failing a real request and pasting
      // the raw 401 body into a snackbar.
      await _account.probe();
      if (twitchAuth.helix.value.isUsable) {
        _account.loadFollowed();
      }
    } catch (e) {
      _showSnackBar('Error loading saved channels: ${describeTwitchError(e)}', isError: true);
    } finally {
      // Whatever went wrong above, the app goes on and must be able to save,
      // as it always could (a no-op when already open). The history only once
      // it has been read, though: opened unread after a failure above, its
      // gate would let the next save replace the sidecar with the flat copy -
      // or with nothing - which is the loss the gate exists to stop.
      _settingsRepo.markConfigLoaded();
      if (!_settingsRepo.historyLoaded) await _history.load();
      // Arms the recovery refresh. Startup already fetches everything, so
      // arming earlier would make the first successful probe refresh it all a
      // second time.
      _startupComplete = true;
      if (mounted) setState(() => _isGlobalLoading = false);
    }
  }

  /// Writes the config and the watch progress now.
  ///
  /// A thin wrapper kept for its many callers: the writing itself, and the
  /// rule that nothing is written before it has been read, live in
  /// SettingsRepository. The rich progress record goes to its own file; the
  /// config keeps the flat copy for compatibility, so a config rewrite can no
  /// longer take the history with it.
  Future<void> _saveChannels() => _settingsRepo.saveNow();

  // ---------------------------------------------------------------------------
  // Channel and VOD refresh.
  //
  // The state and its rules live in lib/state/channels_controller.dart (the
  // poll, the followed list, went-live detection, adding a favourite) and
  // lib/state/vod_browser_controller.dart (the open channel's VOD list, its
  // cache, Load more, and the refreshes that keep it current). What stays
  // here is what needs the widget: toasts, setState, the tray, saving.

  late final ChannelsController _channelsCtl = ChannelsController(
    api: _apiService,
    settings: () => _settings,
    favorites: _channels,
    selected: () => _selectedChannel,
    clock: _services.clock,
  );

  /// The account token: sign-in, probe, the account and its followed list,
  /// and what a token that starts working again refreshes (AccountController).
  late final AccountController _account = AccountController(
    api: _apiService,
    channels: _channelsCtl,
    auth: twitchAuth,
    settings: () => _settings,
    signInServer: _services.signInServer,
    openLink: _openExternalLink,
    save: _saveChannels,
    mounted: () => mounted,
    startupComplete: () => _startupComplete,
    refreshChannels: _refreshAllChannels,
    refreshOpenVods: () {
      final open = _selectedChannel;
      if (open != null) {
        setState(() => _vodsError = null);
        unawaited(_fetchVodsForChannel(open));
      }
    },
    followedLoaded: () {
      // The open channel follows its streamer to the object the poll now
      // keeps current. A reload used to replace every object and leave it
      // pointing at one nothing refreshed any more.
      final open = _selectedChannel;
      if (open != null) {
        setState(() => _selectedChannel = _channelsCtl.canonical(open));
      }
    },
    showMessage: _showSnackBar,
  );

  /// The went-live and New VOD toasts, and what a click on one does
  /// (Announcements).
  late final Announcements _announcements = Announcements(
    notifications: _notifications,
    favorites: _channels,
    automation: _automation,
    player: _playerService,
    settings: () => _settings,
    mounted: () => mounted,
    windowVisible: () => _shell.windowVisible,
    libraryOpen: () => _library.isOpen,
    openChannel: () => _selectedChannel,
    showWindow: _shell.showWindow,
    select: _selectChannel,
  );

  late final VodBrowserController _vodBrowser = VodBrowserController(
    api: _apiService,
    settings: () => _settings,
    localProgress: () => _history.flat,
    clock: _services.clock,
  );

  bool get _hasAccountToken => _settings.twitchOauthToken.trim().isNotEmpty;

  /// The channels changed something on screen. The controller notifies once
  /// per refresh phase, so a poll repaints the sidebar and the welcome screen
  /// itself - it used to rely on an unrelated ten-second timer's setState,
  /// which an unreachable download folder skipped.
  void _onRefreshStateChanged() {
    if (mounted) setState(() {});
  }

  /// The one-minute timer.
  void _onPollTick() {
    // Nothing until startup has loaded the channels and run its own pass. A
    // tick that beat a slow startup polled channels the initial pass had not
    // seen yet, and announced every favourite that was already live.
    if (!_startupComplete) return;
    unawaited(_channelsCtl.tick());
    // The open channel's VODs, every few minutes while they can be seen -
    // with any token Helix reads videos for, which is not only a usable one
    // (see backgroundVodRefreshAllowed).
    if (_shell.windowVisible &&
        backgroundVodRefreshAllowed(twitchAuth.helix.value)) {
      unawaited(_refreshSelectedVods(
          maxAge: VodBrowserController.visibleRefreshInterval));
    }
    // The rest is on a slower clock, and only with a token that works: a
    // rejected one would just collect a 401 a minute until it is fixed, and
    // fixing it refreshes everything anyway (AccountController).
    if (!twitchAuth.helix.value.isUsable) return;
    if (_channelsCtl.isFollowedReloadDue) {
      unawaited(_account.loadFollowed(background: true));
    }
    final open = _selectedChannel;
    if (open != null && _channelsCtl.detailsDue(open)) {
      unawaited(_refreshChannelDetails(open));
    }
  }

  /// The window came back into view: shown from the tray, restored, or
  /// focused (debounced, and never while exiting: AppShellController). What
  /// it shows is fetched again if it is old - the channels when the last pass
  /// is over 30s old, the open VOD list when it is over a minute old.
  void _onWindowCameBack() {
    if (!mounted || !_startupComplete) return;
    unawaited(_channelsCtl.refreshIfOlderThan(const Duration(seconds: 30)));
    if (backgroundVodRefreshAllowed(twitchAuth.helix.value)) {
      unawaited(_refreshSelectedVods(maxAge: VodBrowserController.staleAfter));
    }
  }

  /// One refresh of every channel's live state, for the callers that want a
  /// current answer: startup, the Refresh button, a token that starts working
  /// again. Coalesced with any pass already running (see
  /// ChannelsController.refresh); the timer goes through [_onPollTick].
  Future<void> _refreshAllChannels({bool isInitialLoad = false}) =>
      _channelsCtl.refresh(isInitialLoad: isInitialLoad, force: true);

  /// Everything a refresh pass found that needs the widget. Called once per
  /// pass, however many callers shared it.
  void _onChannelsPass(ChannelsPass pass) {
    if (!mounted) return;
    final selected = pass.selected;
    final open = _selectedChannel;
    final stillOpen = open != null &&
        selected != null &&
        open.username == selected.username;
    if (stillOpen && !identical(open, selected)) {
      setState(() => _selectedChannel = selected);
    }

    // Announced first and automation after, as before: an auto-play's own
    // toast follows the went-live toast it is about.
    unawaited(_announcements.wentLive(pass).whenComplete(() {
      if (mounted) _checkFavoritesAutomation();
    }));
    // Liveness just changed, so the pulse may need to start or stop.
    _updatePulse();

    // The open channel's archive changed: the broadcast that ended is a VOD
    // now, or a new one has started. Until this, only clicking another
    // channel and back brought either into the grid.
    if (stillOpen && pass.selectedBroadcastChanged) {
      unawaited(_refreshSelectedVods(
          endedBroadcastStart: selected.isLive ? null : selected.wentLiveTime));
    }
    // A favourite's broadcast ended off screen: look for its VOD.
    if (_settings.notifyNewVod && _hasAccountToken) {
      for (final ended in pass.favoritesWentOffline) {
        if (stillOpen && ended.username == selected.username) continue;
        unawaited(_vodBrowser.checkForNewVods(ended,
            endedBroadcastStart: ended.wentLiveTime));
      }
    }

    // The open channel is left to its own refreshes; after "Go to
    // dashboard" there is none, though the browser still holds the last one.
    unawaited(_vodBrowser.prefetch(_channels, open: _selectedChannel));
    _shell.rebuildTrayMenu();
  }

  /// Selects a channel and loads its VODs.
  ///
  /// The one path for this. It used to be open-coded in three places - the
  /// sidebar, the welcome screen's live cards and the "went live" notification
  /// - and each had forgotten something different: the game filter left over
  /// from the previous channel, the stale error, the async fetch started from
  /// inside setState.
  void _selectChannel(TwitchChannel channel) {
    // The object the poll keeps current, whichever row was clicked.
    final target = _channelsCtl.canonical(channel);
    _library.close();
    setState(() => _selectedChannel = target);
    _selection.channelChanged();
    // The open channel is part of the pulse's gate (its header breathes
    // while it is live), so selecting one can start or stop it.
    _updatePulse();
    final hasToken = _hasAccountToken;
    unawaited(_applyVodOutcome(_vodBrowser.open(target, fetch: hasToken),
        userInitiated: true));
    // The batched poll leaves follower counts out; the open channel's come
    // from here, at most every half hour.
    if (hasToken && _channelsCtl.detailsDue(target)) {
      unawaited(_refreshChannelDetails(target));
    }
  }

  /// Fetches [channel]'s VODs into the grid: the next page with [loadMore],
  /// else its first page again - merged into the list on screen, or opened
  /// afresh when the grid shows another channel.
  Future<void> _fetchVodsForChannel(TwitchChannel channel, {bool loadMore = false}) {
    final Future<VodFetchOutcome?> fetch;
    if (loadMore) {
      fetch = _vodBrowser.loadMore();
    } else if (_vodBrowser.isShowing(channel)) {
      fetch = _vodBrowser.refresh(silent: false);
    } else {
      fetch = _vodBrowser.open(channel);
    }
    return _applyVodOutcome(fetch, userInitiated: true);
  }

  /// Fetches the open channel's first page again and merges it in, keeping
  /// the pages loaded with Load more, the scroll position and the selection.
  /// With [maxAge], only when the list on screen is older than that.
  Future<void> _refreshSelectedVods({
    Duration? maxAge,
    bool silent = true,
    DateTime? endedBroadcastStart,
  }) {
    final open = _selectedChannel;
    if (open == null || !_hasAccountToken || !_vodBrowser.isShowing(open)) {
      return Future<void>.value();
    }
    final fetch = maxAge != null
        ? _vodBrowser.refreshIfOlderThan(maxAge)
        : _vodBrowser.refresh(
            silent: silent, endedBroadcastStart: endedBroadcastStart);
    return _applyVodOutcome(fetch, userInitiated: !silent);
  }

  /// What a fetch that reached the grid is followed by: the downloaded
  /// badges for what it brought, and saving the watch positions it merged in
  /// from Twitch. Background refreshes skip both when nothing changed, and
  /// leave the browser-token warning to fetches the user asked for, so a
  /// dismissed warning is not raised again every few minutes.
  Future<void> _applyVodOutcome(Future<VodFetchOutcome?> fetch,
      {required bool userInitiated}) async {
    final outcome = await fetch;
    if (!mounted || outcome == null) return;
    if (userInitiated) {
      setState(() => _isWebTokenExpired = outcome.isWebTokenExpired);
    } else if (!outcome.changedVisible) {
      return;
    }
    _checkDownloadedVods();
    // Debounced, config only: this follows every fetch - each selection,
    // each refresh, the cadence while the grid is on screen - and wrote the
    // config and the progress sidecar at once, each fsync'd, every time.
    // What a fetch changes (the merged positions, a resolved channel id)
    // can wait a second; exit and session end flush it regardless.
    _settingsRepo.requestSave();
  }

  /// The open channel's full refresh, follower count included.
  Future<void> _refreshChannelDetails(TwitchChannel channel) async {
    final broadcastChanged = await _channelsCtl.refreshDetails(channel);
    if (!mounted) return;
    _updatePulse();
    if (broadcastChanged && identical(channel, _selectedChannel)) {
      unawaited(_refreshSelectedVods(
          endedBroadcastStart: channel.isLive ? null : channel.wentLiveTime));
    }
  }

  /// True while a VOD is being watched, so auto-play stands down.
  bool get _isWatchingVod =>
      _playerService.playingVodIds.isNotEmpty || _history.isWatching;

  /// One favorites automation pass (AutomationService.runPass); a call
  /// while one is still running does nothing.
  Future<void> _checkFavoritesAutomation() => _automation.runPass();

  Future<void> _bulkUpdateSelectedVods(bool markAsWatched) async {
    if (_selection.picked.isEmpty) {
      _showSnackBar('No VODs selected.', isError: true);
      return;
    }

    final successCount =
        _history.mark(_selection.pickedOf(_channelVods), watched: markAsWatched);
    _selection.end();

    if (successCount > 0) {
      await _saveChannels();
      _showSnackBar(_history.markedMessage(successCount, watched: markAsWatched),
          isError: false);
    }
  }

  Future<void> _openExternalLink(String url) async {
    try {
      if (!_services.launcher.isSupported) {
        _showSnackBar('Unsupported platform for launching external link', isError: true);
        return;
      }
      // Through Explorer, never `cmd /c start`, and quoted: see
      // ExplorerLauncher.openUrl.
      await _services.launcher.openUrl(url);
    } catch (e) {
      _showSnackBar('Failed to open link: $e', isError: true);
    }
  }

  /// Raises an OS notification, ignoring a platform that refuses.
  Future<void> _notify(String title, String body, {bool silent = false}) async {
    try {
      await _notifications
          .show(AppNotification(title: title, body: body, silent: silent));
    } catch (_) {}
  }

  void _showSnackBar(String message,
      {required bool isError, SnackBarAction? action}) {
    // Most callers report on something they awaited, and the screen can be
    // gone by then: ScaffoldMessenger.of a dead context throws. One check
    // here rather than one after every await.
    if (!mounted) return;
    showAppSnackBar(context, message, isError: isError, action: action);
  }

  /// "View log" for a failure message, deep-linking to that session.
  SnackBarAction _viewLogAction(String logKey) {
    return SnackBarAction(
      label: 'View log',
      // Sits on the danger fill; see the note in NeuDialog._primaryButton.
      textColor: NeuTheme.onAccent(NeuTheme.danger),
      onPressed: () => LogViewerDialog.show(context,
          logs: _logNotifier, initialKey: logKey),
    );
  }

  /// Stops or cancels one activity item, confirming first where something
  /// would be lost. Routing is by kind, never by parsing the key - sending a
  /// download key to killProcess trips an assert in PlayerService.
  Future<void> _stopActivity(ActivityItem item) async {
    switch (item.kind) {
      case ActivityKind.queued:
        // Nothing has started, so nothing is lost.
        await _vods.cancelDownload(
            item.id, _playerService.downloadChannelNames[item.id] ?? 'VOD');
      case ActivityKind.downloading:
        if (!await _confirmStop(isDownload: true)) return;
        await _vods.cancelDownload(
            item.id, _playerService.downloadChannelNames[item.id] ?? 'VOD');
      case ActivityKind.liveStream:
        if (!await _confirmStop(isDownload: false)) return;
        _playerService.killLiveStream(item.id);
      case ActivityKind.playingVod:
        if (!await _confirmStop(isDownload: false)) return;
        _playerService.killProcess(item.id);
    }
    if (mounted) {
      _players.publishActivity();
      setState(() {});
    }
  }

  Future<bool> _confirmStop({required bool isDownload}) async {
    final result = await confirmStopActivity(context, isDownload: isDownload);
    return result == true;
  }

  Future<void> _clearWatchProgress() async {
    await _history.clearAll();
    _showSnackBar('Local watch progress history cleared!', isError: false);
  }

  UpdateInfo? _pendingUpdateInfo;

  /// Saving Settings, and what a save sets off (SettingsSaveCoordinator).
  late final SettingsSaveCoordinator _settingsSave = SettingsSaveCoordinator(
    settings: () => _settings,
    adopt: (updated) => setState(() {
      _settings = updated;
      _isWebTokenExpired = false;
    }),
    save: _saveChannels,
    mounted: () => mounted,
    auth: twitchAuth,
    probeAccount: () => _account.probe(force: true),
    forgetFollowed: _channelsCtl.clearFollowed,
    startup: _services.startup,
    rebuildTrayMenu: () => _shell.rebuildTrayMenu(force: true),
    loadFollowed: () => unawaited(_account.loadFollowed()),
    signedOut: () {
      _account.signedOut();
      setState(() {
        _followedChannels.clear();
        _sidebarTab = 0;
      });
      // The saved tab too, as a tab click saves it. Left at Followed, a
      // token added again later opened the next launch on Followed.
      if (_settings.activeSidebarTab != 0) {
        _settings.activeSidebarTab = 0;
        _settingsRepo.requestSave();
      }
    },
    canvasTurnedOn: () {
      LitSurfaceProgram.disable('Simple rendering turned on in Settings');
      _logNotifier.appendLog(
          _appLogKey, '[System] Surface engine: ${LitSurfaceProgram.status}');
    },
    showMessage: (message) => _showSnackBar(message, isError: false),
  );

  void _showSettingsDialog() {
    SettingsDialog.show(
      context,
      settings: _settings,
      themeNotifier: themeNotifier,
      authenticatedUserLogin: _account.login,
      onRevalidateHelix: () => _account.probe(force: true),
      onConnectAccount: _account.signIn,
      openExternalLink: _openExternalLink,
      onClearWatchHistory: _clearWatchProgress,
      onOpenLogs: () => LogViewerDialog.show(context, logs: _logNotifier),
      apiService: _apiService,
      // Stash it; the prompt is offered AFTER the dialog closes. The old
      // post-frame callback fired while Settings was still open and stacked
      // the prompt behind the modal.
      onUpdateAvailable: (info) => _pendingUpdateInfo = info,
      onSave: _settingsSave.save,
    ).then((_) {
      final info = _pendingUpdateInfo;
      _pendingUpdateInfo = null;
      if (info != null && mounted && !_shell.isUpdateActive) {
        _showUpdatePromptDialog(info);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // One measurement, published to the subtree. Everything below reads
    // AppLayout.of(context) rather than re-deriving its own breakpoints.
    final layout = AppLayoutData.fromSize(MediaQuery.sizeOf(context));
    final isVertical = layout.isPortrait;
    final isNarrow = layout.isCompact;
    final effectiveSidebarCollapsed = layout.isRail ? true : _sidebarCollapsed;
    
    final sidebar = SidebarPanel(
      key: _sidebarKey,
      searchFocusNode: _sidebarSearchFocus,
      channels: _channels,
      followedChannels: _followedChannels,
      selectedChannel: _selectedChannel,
      settings: _settings,
      sidebarCollapsed: effectiveSidebarCollapsed,
      isHorizontal: isVertical,
      sidebarTab: _sidebarTab,
      isAdding: _isAdding,
      isGlobalLoading: _isGlobalLoading,
      isLoadingFollowed: _isLoadingFollowed,
      authenticatedUserLogin: _account.login,
      authenticatedUserAvatar: _account.avatar,
      pulseController: _pulseController!,
      searchController: _searchController,
      onChannelSelected: _selectChannel,
      onChannelDoubleTapped: _channelActions.watch,
      onChannelPlayPressed: _channelActions.watch,
      onAddChannel: _channelActions.add,
      onToggleFavorite: _channelActions.toggleFavorite,
      onToggleCollapse: (collapsed) {
        setState(() {
          _sidebarCollapsed = collapsed;
          _settings.sidebarCollapsed = collapsed;
        });
        _saveChannels();
      },
      onGoToDashboard: () {
        _library.close();
        setState(() => _selectedChannel = null);
      },
      onSaveAutomationSettings: () {
        _saveChannels();
        _checkFavoritesAutomation();
      },
      onTabChanged: (tabIdx) {
        setState(() {
          _sidebarTab = tabIdx;
          _settings.activeSidebarTab = tabIdx;
        });
        // A tab click is no reason to write the config at once; a run of
        // them is one debounced write.
        _settingsRepo.requestSave();
        if (tabIdx == 1 && _followedChannels.isEmpty && !_isLoadingFollowed) {
          _account.loadFollowed();
        }
      },
      onRefresh: () async {
        if (_sidebarTab == 0) {
          await _refreshAllChannels();
        } else if (_sidebarTab == 1) {
          await _account.loadFollowed();
        } else {
          await Future.wait([
            _refreshAllChannels(),
            _account.loadFollowed(),
          ]);
        }
      },
      onShowSettings: _showSettingsDialog,
      onShowLibrary: _library.open,
    );

    return AppFrame(
      layout: layout,
      liveCount: _channels.where((c) => c.isLive).length,
      activity: _players.activity,
      onStopActivity: _stopActivity,
      onThemeToggle: (isDark) {
        setState(() {
          themeNotifier.setDarkTheme(isDark);
          _settings.isDarkTheme = isDark;
        });
        _saveChannels();
      },
      banners: [
        ValueListenableBuilder<StorageWriteFailure?>(
          valueListenable: storageWriteFailure,
          builder: (context, failure, _) {
            if (failure == null || _saveWarningDismissed) {
              return const SizedBox.shrink();
            }
            return SaveFailureBanner(
              failure: failure,
              onDismiss: () => setState(() => _saveWarningDismissed = true),
            );
          },
        ),
        ValueListenableBuilder<TwitchAuthStatus>(
          valueListenable: twitchAuth.helix,
          builder: (context, status, _) {
            if (!_account.showsBanner(status)) {
              return const SizedBox.shrink();
            }
            return TwitchAuthBanner(
              status: status,
              // Reconnecting happens on the banner: see TwitchAuthBanner.
              onReconnect: _account.signIn,
              onDismiss: () => _account.dismissBanner(status.fault),
            );
          },
        ),
      ],
      sidebar: sidebar,
      // Each part repaints with the one controller it shows, not the whole
      // screen: these three are read nowhere else in build. The Library's
      // flag picks the part; the welcome screen shows the recents; the open
      // channel shows its VOD list, and the watch positions written into it.
      content: ListenableBuilder(
        listenable: _library,
        builder: (context, _) {
          if (_library.isOpen) return _buildLibraryView();
          final open = _selectedChannel;
          if (open == null) {
            return ListenableBuilder(
                listenable: _history, builder: (context, _) => _buildHome());
          }
          return ListenableBuilder(
              listenable: _dashboardSources,
              builder: (context, _) => _buildDashboard(open));
        },
      ),
      onEscape: _library.close,
      // Focus the sidebar search from anywhere. In layouts without the
      // inline field the search popover is the affordance instead.
      onFind: () {
        if (_sidebarCollapsed || isNarrow || isVertical) {
          // Expand first on wide layouts where the user collapsed it.
          if (!isNarrow && !isVertical && _sidebarCollapsed) {
            setState(() {
              _sidebarCollapsed = false;
              _settings.sidebarCollapsed = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _sidebarKey.currentState?.focusSearch();
            });
            return;
          }
        }
        _sidebarKey.currentState?.focusSearch();
      },
    );
  }

  Widget _buildHome() {
    return HomeView(
      channels: _channels,
      recentVods: _history.recents,
      runningDownloads: _players.activity.value.downloading,
      downloadedCount: _downloadedVodsRegistry.length,
      accountLogin: _account.login,
      recentScroll: _recentScroll,
      fadeLeft: _recentFadeLeft,
      fadeRight: _recentFadeRight,
      onRecentScrolled: _updateRecentFades,
      onAddChannel: () => _sidebarSearchFocus.requestFocus(),
      onSelectChannel: _selectChannel,
      // Not ChannelActions.watch, which compares the running set with the
      // clean name: this is what the live card always did.
      onLaunchLive: (channel) {
        if (_playerService.runningChannels.contains(channel.username)) return;
        _playerService.launchStreamlinkForLive(
          channel.username,
          channel.isLive,
          channel.streamTitle,
          channel.game,
          _settings,
        );
      },
      onPlayRecent: _vods.playRecent,
      onOpenLibrary: _library.open,
      onOpenSettings: _showSettingsDialog,
      onConnectAccount: _account.signIn,
    );
  }

  /// Where closing the Library would land, for the back control's label.
  String get _libraryBackLabel => _selectedChannel?.username ?? 'Home';

  /// Opens Explorer with [filePath] selected (AppLauncher.reveal).
  Future<void> _revealInExplorer(String filePath) async {
    try {
      await _services.launcher.reveal(filePath);
    } catch (e) {
      _showSnackBar('Could not open folder: $e', isError: true);
    }
  }

  Widget _buildLibraryView() {
    return LibraryView(
      onBack: _library.close,
      backLabel: _libraryBackLabel,
      entries: _library.entries,
      onRefresh: _library.rescanAndRefresh,
      onPlay: _library.play,
      onOpenFolder: (entry) {
        if (entry.filePath != null) _revealInExplorer(entry.filePath!);
      },
      onDelete: _library.delete,
      onRemoveFromHistory: _library.removeFromHistory,
      activity: _players.activity,
      onStopActivity: _stopActivity,
    );
  }

  /// What the open channel's dashboard shows changes with (see build).
  late final Listenable _dashboardSources =
      Listenable.merge([_vodBrowser, _history, _selection]);

  Widget _buildDashboard(TwitchChannel channel) {
    final channelName = _selectedChannel?.username ?? 'VOD';
    return ChannelDashboard(
      channel: channel,
      settings: _settings,
      vodBrowser: _vodBrowser,
      pulseController: _pulseController!,
      isPlaying: _playerService.runningChannels.contains(channel.username),
      isMultiSelectMode: _selection.isSelecting,
      selectedVodIds: _selection.picked,
      isWebTokenExpired: _isWebTokenExpired,
      selectedGamesFilter: _selection.games,
      vodSearchController: _selection.search,
      displayMenu: VodDisplayMenu(
        settings: _settings,
        vods: _channelVods,
        selectedGamesFilter: _selection.games,
        vodSearchController: _selection.search,
        update: _selection.update,
        onSave: _saveChannels,
      ),
      isVodPlaying: (id) => _playerService.playingVodIds.contains(id),
      isVodDownloaded: (id) => _downloadedVodIds.contains(id),
      downloadStatus: (id) => _playerService.activeDownloadTasks[id],
      downloadProgress: (id) => _playerService.activeDownloadsProgress[id],
      onPlayLive: () {
        _playerService.launchStreamlinkForLive(
          channel.username,
          channel.isLive,
          channel.streamTitle,
          channel.game,
          _settings
        );
      },
      // The whole channel: its details (follower count included, which the
      // batched poll leaves out) and its VOD list, merged in place.
      onRefreshChannel: () {
        unawaited(_refreshChannelDetails(channel));
        unawaited(_refreshSelectedVods(silent: false));
      },
      openExternalLink: _openExternalLink,
      onEnterSelection: _selection.enter,
      onExitSelection: _selection.end,
      onClearSelection: _selection.clearPicked,
      onSelectAllVisible: () => _selection.pickAllShown(_channelVods),
      onBulkMark: _bulkUpdateSelectedVods,
      // In the grid's order, as the order dialog lists them.
      onBulkDownload: () => _vods.downloadSelection(
          _selection.pickedInOrderOf(_channelVods),
          channelName: () => _selectedChannel?.username ?? 'VOD',
          endSelection: _selection.end),
      onBulkDelete: () => _vods.deleteSelection(
          _selection.pickedOf(_channelVods),
          channelName: _selectedChannel?.username ?? '',
          endSelection: _selection.end),
      onRefreshVods: () => _refreshSelectedVods(silent: false),
      onUpdateToken: _showSettingsDialog,
      onDismissWebTokenWarning: () => setState(() {
        _isWebTokenExpired = false;
      }),
      onGameFilterSelected: _selection.toggleGame,
      onClearGameFilter: _selection.clearGames,
      onPlayVod: (vod) => _vods.play(vod, channelName),
      onDownloadVod: (vod) => _vods.download(vod, channelName),
      onDeleteDownload: (id) => _vods.deleteDownload(id, channelName),
      onCancelDownload: (id) => _vods.cancelDownload(id, channelName),
      onVodSelectedChange: _selection.pick,
      onOpenFolder: (vod) {
        final path = _downloadedVodsRegistry[vod.id];
        if (path != null) _revealInExplorer(path);
      },
      onLoadMore: () => _fetchVodsForChannel(channel, loadMore: true),
    );
  }
}
