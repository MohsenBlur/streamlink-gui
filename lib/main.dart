import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:local_notifier/local_notifier.dart';

import 'app_services.dart';

import 'models/app_settings.dart';
import 'models/twitch_channel.dart';
import 'models/twitch_video.dart';
import 'services/crash_log.dart';
import 'services/desktop_shell.dart';
import 'services/native_window.dart';
import 'services/storage_service.dart';
import 'state/twitch_auth_notifier.dart';
import 'state/watch_progress_store.dart';
import 'utils/twitch_auth_status.dart';
import 'services/twitch_api_service.dart';
import 'services/player_service.dart';
import 'services/update_service.dart';
import 'services/log_store.dart';
import 'state/activity_state.dart';
import 'state/settings_repository.dart';
import 'services/downloads_controller.dart';
import 'theme/material/app_material.dart';
import 'theme/type_probe.dart';
import 'widgets/shell/app_chassis.dart';
import 'widgets/shell/channel_dashboard.dart';
import 'widgets/shell/home_view.dart';
import 'widgets/shell/status_banners.dart';
import 'widgets/shell/app_layout.dart';
import 'widgets/shell/motion.dart';
import 'widgets/shell/neu_dialog.dart';
import 'widgets/neumorphic/neu_progress.dart';
import 'state/channels_controller.dart';
import 'state/vod_browser_controller.dart';
import 'widgets/activity_pill.dart';
import 'widgets/log_viewer_dialog.dart';
import 'widgets/sidebar_panel.dart';
import 'widgets/download_folder_prompt.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/shell/route_handle.dart';

import 'services/startup_service.dart';
import 'state/app_shell_controller.dart';
import 'state/library_entries.dart';
import 'utils/window_bounds.dart';
import 'widgets/library_view.dart';
import 'widgets/onboarding_wizard.dart';
import 'widgets/neumorphic/neu_title_bar.dart';
import 'services/oauth_loopback_server.dart';
import 'services/automation_service.dart';
import 'theme/material/lit_surface.dart';
import 'theme/app_theme.dart';
import 'theme/neu_theme.dart';
import 'widgets/neumorphic/neu_pulse.dart';
import 'theme/theme_notifier.dart';
import 'utils/color_utils.dart';


Future<void> main(List<String> args) async {
  // One guarded zone around everything: the binding, the startup and runApp
  // must share a zone, and an error thrown anywhere in them has to reach the
  // crash log. A release build has no console, so before this an exception
  // here simply ended startup - with the window never shown - and left nothing
  // behind to say why.
  await runZonedGuarded<Future<void>>(
    () => _startApp(args),
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

Future<void> _startApp(List<String> args) async {
  final launch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  final storage = StorageService();
  // Beside the config, so portable mode keeps it beside the exe too.
  final crashLog = CrashLog(storage.getStorageFile(CrashLog.fileName));
  CrashLog.install(crashLog);
  // Startup milestones. Each one is a line in crash.log, so a launch that
  // never shows its window still says how far it got.
  void milestone(String message) =>
      crashLog.milestone('[startup +${launch.elapsedMilliseconds}ms] $message');
  milestone('launch v${UpdateService.currentVersion}, pid $pid'
      '${args.isEmpty ? '' : ', args $args'}');

  // One read and one parse of the config for the whole startup. main() used
  // to read and decrypt it here and _loadChannels read and decrypted it all
  // again a moment later; the snapshot now goes down to the first load.
  //
  // Nothing before runApp may throw: the window is only ever shown by the
  // first frame, so an exception here is an app that never appears. A load
  // that fails outright leaves the snapshot out, and the first load reads
  // the file again itself - never an empty snapshot that the next autosave
  // would write over a config that is still on disk.
  StartupConfig? startup;
  try {
    startup = await storage.loadStartupConfig();
    milestone(startup.isFirstRun
        ? 'config: none, first run'
        : (startup.data == null
            ? 'config: unreadable, quarantined; using defaults'
            : 'config: loaded'));
  } catch (e, st) {
    crashLog.error('config', e, st);
  }
  final settings = startup?.parseSettings() ?? AppSettings();

  // The material engine's fragment program, before the first frame so the
  // first paint is already lit. Milliseconds; degrades to the Canvas engine
  // on failure rather than to a blank window. Settings' "Simple rendering"
  // and --canvas-engine skip the shader outright - the switch for a machine
  // where it renders, but slowly or wrongly, which no self-test can see.
  final canvasReason = args.contains('--canvas-engine')
      ? '--canvas-engine flag'
      : (settings.canvasEngine ? 'Simple rendering setting' : null);
  await LitSurfaceProgram.load(
      forceCanvas: canvasReason != null, forceCanvasReason: canvasReason);
  milestone('surface engine: ${LitSurfaceProgram.status}');

  // The typography gate. Off unless asked for, and it cannot be a unit test:
  // `flutter test` has no system fonts and CI is ubuntu, so an assertion about
  // Bahnschrift there would measure the fallback against itself and pass.
  if (TypeProbe.enabled) {
    await TypeProbe.run();
  }
  try {
    await localNotifier.setup(
      appName: 'Twitch Streamlink GUI',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
  } catch (e, st) {
    // Toasts are a nicety; a failure here must not stop the window appearing.
    crashLog.error('notifications', e, st);
  }

  // Autostart launches pass --start-minimized; the manual-launch preference
  // does the same thing without the flag.
  final bool startMinimized =
      args.contains('--start-minimized') || settings.startMinimized;

  // Re-writing the Run value at every launch silently heals a moved install.
  if (settings.launchAtStartup) {
    StartupService().sync(true);
  }

  await _prepareWindow(settings,
      startHidden: startMinimized, milestone: milestone, log: crashLog);

  seedStoredLook(settings);

  runApp(TwitchStreamlinkApp(startup: startup, startHidden: startMinimized));
  milestone('runApp');

  unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
    milestone('first frame rasterized');
    return _checkWindowAfterFirstFrame(
        startHidden: startMinimized, milestone: milestone);
  }));
}

/// Seeds the look from the settings main() already parsed, BEFORE the first
/// frame.
///
/// `NeuTheme.activeMaterial` defaults to rack and `themeNotifier.isDarkTheme`
/// to true, and both were only corrected later, inside `_loadChannels`'s
/// second config read. The window is shown from the first-frame callback
/// (`flutter_window.cpp`), so a user on Soft, or on the light theme, saw at
/// least one fully presented frame of the wrong look before it snapped -
/// a flash of a different material, not just a different colour.
///
/// The first load's own `setMaterial`/`setDarkTheme`/accent/progress calls
/// then no-op, because every setter early-returns when the value is
/// unchanged. They have to: the first load runs from MainScreen's initState,
/// inside the build, and a notification from there marks the app's own
/// ListenableBuilder dirty mid-build. The progress colours were left out of
/// this seeding and `updateTheme` notified unconditionally, so every launch
/// did exactly that - an assertion on each debug launch, and a second build
/// of the whole MaterialApp in the first frame of a release one.
void seedStoredLook(AppSettings settings) {
  final storedMaterial = AppMaterial.fromKey(settings.material);
  if (storedMaterial != null && MaterialSpec.isImplemented(storedMaterial)) {
    NeuTheme.activeMaterial = storedMaterial;
  }
  themeNotifier.isDarkTheme = settings.isDarkTheme;
  themeNotifier.lightAccentColor = parseHexColor(
      settings.lightAccentColorHex, NeuTheme.defaultLightAccent);
  themeNotifier.darkAccentColor =
      parseHexColor(settings.darkAccentColorHex, NeuTheme.defaultDarkAccent);
  // User-configurable hex settings; these are their defaults, as the first
  // load reads them (_loadChannels), not theme colors.
  themeNotifier.activeProgressColor = parseHexColor(
      settings.activeProgressColorHex, const Color(0xFF9146FF));
  themeNotifier.watchedProgressColor = parseHexColor(
      settings.watchedProgressColorHex, const Color(0x804CAF50));
}

/// The frame style, close interception and geometry - all before the first
/// frame, while the window is still hidden.
///
/// The runner creates the window hidden and shows it from its first-frame
/// callback. Everything that changes the frame therefore has to land before
/// that frame, or the user watches it happen: the window used to appear at
/// the runner's default spot on the primary monitor and then jump, across
/// monitors and a DPI change, to where it was saved - and that move racing
/// the first frame is when the content view was found hidden (the
/// invisible-window bug, audit C1).
///
/// Geometry no longer goes through window_manager. Its setSize and
/// setPosition convert with the window's devicePixelRatio of that instant,
/// which during startup on mixed-DPI monitors is whichever monitor the
/// window happens to be on; the runner's channel places it in physical
/// pixels instead, and shows it maximized as part of the show itself.
Future<void> _prepareWindow(
  AppSettings settings, {
  required bool startHidden,
  required void Function(String) milestone,
  required CrashLog log,
}) async {
  try {
    await windowManager.ensureInitialized();
    // No size, position or show in here (see above). The hidden title bar
    // does belong before the first frame: it changes the client area, so it
    // decides the size that frame is laid out at.
    await windowManager.waitUntilReadyToShow(const WindowOptions(
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    ));
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(kMinWindowSize);
  } catch (e, st) {
    log.error('window setup', e, st);
  }

  try {
    final monitors = await NativeWindow.monitors();
    milestone('monitors: ${monitors.join('; ')}');
    final plan = planWindowRestore(
      monitors: monitors,
      saved: settings.windowPlacement,
      legacyX: settings.windowX,
      legacyY: settings.windowY,
      legacyWidth: settings.windowWidth,
      legacyHeight: settings.windowHeight,
      maximized: settings.isWindowMaximized,
    );
    final placed = await NativeWindow.setInitialPlacement(plan.bounds,
        maximized: plan.maximized, hidden: startHidden);
    milestone('placement: $plan${startHidden ? ', starting hidden' : ''}; '
        'window now $placed');
  } catch (e, st) {
    // The window stays where the runner created it, and the runner still
    // shows it on the first frame.
    log.error('window placement', e, st);
  }
}

/// Records what the window looks like once the first frame is up, and puts
/// right what it can.
///
/// This is the evidence the invisible-window reports never had: whether the
/// frame was shown, whether the content view inside it was, where, at which
/// DPI. The runner already re-asserts the content view whenever the frame is
/// shown or moved; asking it to show again here covers a frame that never
/// appeared at all.
Future<void> _checkWindowAfterFirstFrame({
  required bool startHidden,
  required void Function(String) milestone,
}) async {
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  try {
    final state = await NativeWindow.state();
    // What the engine laid out at, beside what the frame is: a DPI change
    // the engine missed shows up here as a ratio that does not match the
    // window's DPI (content laid out at a stale size, audit M2).
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final view = views.isEmpty ? null : views.first;
    final layout = view == null
        ? ''
        : '; laid out at ${view.physicalSize.width.round()}x'
            '${view.physicalSize.height.round()} @ ${view.devicePixelRatio}';
    milestone('window after first frame: $state$layout');
    if (!startHidden && AppShellController.windowHiddenByUser) {
      milestone('hidden to the tray since; leaving it as it is');
    }
    if (shouldReshowAfterFirstFrame(state,
        startHidden: startHidden,
        hiddenByUser: AppShellController.windowHiddenByUser)) {
      milestone('window or its content is not visible; showing it again');
      await NativeWindow.show();
      milestone('window after re-show: ${await NativeWindow.state()}');
    }
  } catch (e, st) {
    CrashLog.current?.error('window check', e, st);
  }
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

  /// Everything currently downloading or playing. Kept as a ValueNotifier so
  /// the activity pill and the Library's live rows repaint on a progress tick
  /// without rebuilding the whole screen.
  final ValueNotifier<ActivitySnapshot> _activity =
      ValueNotifier(ActivitySnapshot.empty);

  /// Last whole-percent bucket and status per download, used to collapse the
  /// several-per-second progress callbacks into at most one rebuild per
  /// percent (see progressTickIsVisible).
  final Map<String, int> _progressBuckets = {};
  final Map<String, String?> _progressStatuses = {};

  // UI state variables
  final List<TwitchChannel> _channels = [];
  TwitchChannel? _selectedChannel;
  bool _isGlobalLoading = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _sidebarSearchFocus = FocusNode();
  final GlobalKey<SidebarPanelState> _sidebarKey = GlobalKey<SidebarPanelState>();
  bool _isAdding = false;
  
  AppSettings _settings = AppSettings();
  Set<String> get _previouslyLiveFavoriteUsernames => _channelsCtl.liveFavorites;
  
  Timer? _favoritesLiveCheckTimer;
  Timer? _downloadCheckTimer;
  OAuthLoopbackServer? _oauthServer;
  
  List<TwitchChannel> get _followedChannels => _channelsCtl.followed;
  bool get _isLoadingFollowed => _channelsCtl.isLoadingFollowed;
  String? _authenticatedUserLogin;
  String? _authenticatedUserAvatar;
  int _sidebarTab = 0; 
  
  // The open channel's VOD list lives in _vodBrowser (see the refresh block
  // by _selectChannel); these read it for the code that predates it.
  List<TwitchVideo> get _channelVods => _vodBrowser.vods;
  set _vodsError(String? value) => _vodBrowser.error = value;

  final TextEditingController _vodSearchController = TextEditingController();
  AnimationController? _pulseController;
  bool _sidebarCollapsed = false;
  final Set<String> _selectedGamesFilter = {};
  bool _isWebTokenExpired = false;
  bool _isMultiSelectMode = false;
  final Set<String> _selectedVodIds = {};
  bool _isBulkUpdatingVods = false;
  /// The flat view every reader already uses, derived from [_progressStore].
  ///
  /// Kept so no call site changes, and still written into channels_config.json
  /// so an older build finds positions where it expects them.
  Map<String, int> _localVodsProgress = {};

  /// The durable layer underneath it: the furthest point ever reached, a short
  /// undo trail, and the guard that stops a player which came up in the wrong
  /// place from writing over a good position.
  WatchProgressStore _progressStore = WatchProgressStore();
  Set<String> _downloadedVodIds = {};
  Map<String, String> _downloadedVodsRegistry = {};
  final Map<String, TwitchVideo> _activePlayingVideos = {};
  List<TwitchVideo> _recentWatchedVods = [];

  // ---- Persistence and downloads -------------------------------------------
  // When the three files are written (SettingsRepository) and the saved
  // download queue plus the downloaded-file scan (DownloadsController). Both
  // are created on first use rather than in initState, so a save asked for
  // from anywhere, however early, finds them ready. Wired to PlayerService
  // and the session-end channel in initState.

  late final SettingsRepository _settingsRepo = SettingsRepository(
    writeConfig: _writeConfigFile,
    writeProgress: () =>
        _storageService.saveWatchProgress(_progressStore.toJson()),
    writeRecents: () => _storageService.saveRecentWatchedVods(
        _recentWatchedVods.map((v) => v.toJson()).toList()),
    onError: (e, st) => CrashLog.current?.error('saving', e, st),
  );

  late final DownloadsController _downloads = DownloadsController(
    onQueueChanged: () => _settingsRepo.requestSave(),
    readScanInput: _downloadScanInput,
    onScanned: _applyDownloadScan,
  );

  /// The last whole percent rebuilt for each playing VOD's progress, so a
  /// watch-position tick repaints only when something on screen would change.
  final Map<String, int> _watchProgressBuckets = {};
  // ---------------------------------------------------------------------------

  /// Set when the user dismisses the save-failure banner, so a persistent
  /// disk problem does not become an undismissable wall. Reset whenever a save
  /// succeeds, so a NEW failure is reported again.
  bool _saveWarningDismissed = false;

  /// Dismissal of the reconnect banner, reset whenever the reason changes so
  /// a dismissed "expired" does not also hide a later "wrong Client ID".
  bool _authWarningDismissed = false;
  TwitchAuthFault _dismissedFault = TwitchAuthFault.none;

  /// Whether the account token was usable at the last notification, and
  /// whether the startup sequence has finished. Together they identify a
  /// RECOVERY - the moment a rejected token starts working again.
  bool _lastAuthUsable = false;
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

  /// Library screen state. Entries are CACHED - built (with file stats) only
  /// on open/refresh/mutation, never inside build(), because download-progress
  /// setState storms would otherwise stat every file per frame.
  bool _showLibraryView = false;
  List<LibraryEntry> _libraryEntries = [];


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
      localVodsProgress: _localVodsProgress,
      // This pass renders nothing, so the per-VOD game lookup is pure
      // overhead. It runs for every auto-download channel every minute.
      fetchGames: false,
    ),
    localProgress: () => _localVodsProgress,
    isVodHandled: (vodId) =>
        _downloadedVodsRegistry.containsKey(vodId) ||
        _playerService.activeDownloadTasks.containsKey(vodId) ||
        _playerService.activeDownloadProcesses.containsKey(vodId) ||
        _playerService.downloadQueue.contains(vodId),
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

    // Initialize player service archive path and listener hooks
    _playerService.downloadArchiveFilePath = _storageService.getStorageFile('yt_dlp_archive.txt').path;
    _playerService.onPlayerLog = (key, line) {
      // Not once the screen is gone: dispose stops the players, which is
      // asynchronous, and their last lines arrived after the log was
      // disposed - an error for each, like the callbacks below already
      // guard against.
      if (!mounted) return;
      _logNotifier.appendLog(key, line);
    };

    // The service mutates playingVodIds/runningChannels internally with no
    // notification of its own, so this callback is the only signal that
    // playback began - it must stay even though the console tab it used to
    // select is gone.
    _playerService.onPlayerStarted = (key, title) {
      if (!mounted) return;
      _logNotifier.beginSession(key, title);
      {
        _publishActivity();
        _updatePulse();
        setState(() {});
      }
    };

    _playerService.onPlayerStopped = (key, exitCode, userInitiated) {
      // Release the "user is watching a VOD" marker.
      //
      // This map was written when a VOD started and never cleared anywhere, so
      // the first VOD played in a session made it permanently non-empty - and
      // the automation guard that consults it then returned early on every
      // subsequent pass, silently killing BOTH priority auto-play and VOD
      // auto-download until the app was restarted.
      _activePlayingVideos.remove(key);
      // The position playback stopped at is the one to keep, so it is
      // written now rather than when the progress delay runs out.
      _watchProgressBuckets.remove(key);
      unawaited(_settingsRepo.flushProgress());
      if (!mounted) return;
      _logNotifier.endSession(key, exitCode);

      {
        _publishActivity();
        _updatePulse();
        setState(() {});
        // A player that never opened is otherwise silent: the console drawer
        // used to be the only hint. Surface it, with the log one tap away.
        //
        // userInitiated excludes deliberate stops: taskkill makes the process
        // exit non-zero, so without it every "Stop" reported a failure.
        if (shouldReportPlaybackFailure(
            exitCode: exitCode, userInitiated: userInitiated)) {
          final label = _logNotifier.session(key)?.label ?? 'playback';
          _showSnackBar('Playback failed for $label', isError: true,
              action: _viewLogAction(key));
          // Only when the window is hidden, which is the auto-play case: a
          // failure the user is watching happen does not need a tray popup
          // on top of the message they can already see.
          _shell.isHidden().then((hidden) {
            if (hidden) _notify('Playback failed', label);
          });
        }
      }
    };

    _playerService.recordWatchProgress =
        (vodId, position, progress, sessionAgeMs) {
      // One chokepoint, and it can say no. A relaunched player that came up at
      // the top of a five-hour VOD used to write its way over the stored
      // position within seconds - here and on Twitch, where max(local, remote)
      // cannot undo it. Answering false is what keeps it off Twitch: the
      // tracker pushes only the positions kept here.
      final result = _progressStore.record(vodId, position,
          nowMs: DateTime.now().millisecondsSinceEpoch,
          sessionAgeMs: sessionAgeMs);
      if (!result.accepted) {
        if (result.outcome == ProgressWriteOutcome.rejectedSuspectRegression) {
          _logNotifier.appendLog(
              vodId,
              '[System] Ignored a watch position of ${position}s: it is far behind '
              'the furthest point reached (${result.entry.best}s) and arrived in the '
              'first seconds of this session, which is what a failed resume looks '
              'like.');
        }
        return false;
      }
      if (mounted) {
        // Every tick updates the state; only a tick that changes something on
        // screen rebuilds it. This rebuilt the whole screen - the grid, the
        // carousel and all - every two seconds for as long as anything
        // played, while the cards draw progress to a whole percent.
        var visible = progressTickIsVisible(
          previousBucket: _watchProgressBuckets[vodId],
          progress: progress,
          previousStatus: null,
          status: null,
        );
        _watchProgressBuckets[vodId] = (progress * 100).floor();

        _localVodsProgress[vodId] = position;
        final idx = _channelVods.indexWhere((v) => v.id == vodId);
        if (idx != -1) {
          _channelVods[idx].watchPosition = position;
          _channelVods[idx].watchProgress = progress;
        }

        final video = _activePlayingVideos[vodId];
        if (video != null) {
          video.watchPosition = position;
          video.watchProgress = progress;

          // Moving it to the front happens once per session; after that it is
          // already there, and nothing about the order changes.
          if (_recentWatchedVods.isEmpty ||
              !identical(_recentWatchedVods.first, video)) {
            visible = true;
            _recentWatchedVods.removeWhere((v) => v.id == vodId);
            _recentWatchedVods.insert(0, video);

            if (_recentWatchedVods.length > _settings.maxRecentlyWatched) {
              _recentWatchedVods = _recentWatchedVods.take(_settings.maxRecentlyWatched).toList();
            }
          }
        }
        if (visible) setState(() {});
        // Written within the repository's progress delay rather than on every
        // tick, and at once when the player stops (onPlayerStopped).
        _settingsRepo.noteProgress(recents: video != null);
      }
      return true;
    };

    _playerService.onDownloadProgress = (vodId, progress, status) {
      if (!mounted) return;
      // Always cheap, and drives the pill plus the Library's live rows.
      _publishActivity();
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
        setState(() {});
      }
    };

    _playerService.onDownloadEnded = (vodId, exitCode) {
      if (!mounted) return;
      _logNotifier.endSession(logKeyForDownload(vodId), exitCode);
    };

    // A download that completed, failed or was cancelled leaves the saved
    // queue (DownloadsController); one queued from anywhere joins it. Ending
    // downloads to exit or update reports none of these, so the queue stays
    // saved for the next launch.
    _playerService.onDownloadQueued = _downloads.remember;

    _playerService.onDownloadCancelled = (vodId) {
      _downloads.forget(vodId);
      _progressBuckets.remove(vodId);
      _progressStatuses.remove(vodId);
      if (mounted) {
        _publishActivity();
        setState(() {});
        if (_showLibraryView) _refreshLibraryEntries();
        // Not an error - the user asked for it.
        _showSnackBar('Download cancelled.', isError: false);
      }
    };

    _playerService.onDownloadCompleted = (vodId, title, filePath) {
      _downloads.forget(vodId);
      if (mounted) {
        setState(() {
          if (filePath.isNotEmpty) {
            _downloadedVodsRegistry[vodId] = filePath;
          }
        });
        _progressBuckets.remove(vodId);
        _progressStatuses.remove(vodId);
        _publishActivity();
        _checkDownloadedVods();
        // With the queue change forget() asked for: downloads finish in
        // bursts (a backlog resumed at launch), one write for the burst.
        _settingsRepo.requestSave();
        if (_showLibraryView) _refreshLibraryEntries();
        _showSnackBar('Download completed: $title', isError: false);
        if (_settings.notifyDownloadComplete) {
          _notify('VOD Download Completed', title);
        }
      }
    };

    _playerService.onDownloadFailed = (vodId, title, exitCode) {
      _downloads.forget(vodId);
      _progressBuckets.remove(vodId);
      _progressStatuses.remove(vodId);
      if (mounted) {
        _publishActivity();
        setState(() {});
        _showSnackBar('Download failed for: $title (Exit code $exitCode)',
            isError: true, action: _viewLogAction(logKeyForDownload(vodId)));
      }
      // A failure is at least as worth knowing about as a success, and
      // downloads are exactly what runs while the app sits in the tray. No new
      // setting: it rides the toggle that already governs the outcome of a
      // download, now honestly labelled as covering both.
      if (_settings.notifyDownloadComplete) {
        _notify('VOD Download Failed', title);
      }
    };

    // Channel and VOD refresh wiring: lib/state/channels_controller.dart and
    // vod_browser_controller.dart, driven from the block by _selectChannel.
    // Before _loadChannels, whose startup pass already reports through it.
    _channelsCtl.addListener(_onRefreshStateChanged);
    _channelsCtl.onPass = _onChannelsPass;
    _vodBrowser.addListener(_onRefreshStateChanged);
    _vodBrowser.onNewVods = _onNewVods;

    storageWriteFailure.addListener(_onSaveFailureChanged);
    twitchAuth.helix.addListener(_onAuthStatusChanged);
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
        _loadFollowedChannels();
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
    // Not dismissible by clicking away: this is the only place the update is
    // offered, and a stray click outside would silently defer it for a day.
    NeuDialog.show<void>(
      context,
      dismissible: false,
      builder: (context) {
        final isDark = themeNotifier.isDarkTheme;
        return NeuDialog(
          title: 'Update available',
          subtitle: 'v${UpdateService.currentVersion} → ${info.tagName}',
          icon: Icons.system_update,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A newer build is on GitHub Releases. The app downloads it, '
                'verifies its checksum and restarts itself.',
                style: NeuType.body(isDark),
              ),
              if (info.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: NeuSpace.s16),
                Text("What's new",
                    style: NeuType.label(isDark)),
                const SizedBox(height: NeuSpace.s6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  padding: const EdgeInsets.all(NeuSpace.s12),
                  decoration:
                      NeuTheme.sunkenDecoration(isDark, radius: NeuRadius.r8),
                  child: SingleChildScrollView(
                    child: Text(
                      info.releaseNotes,
                      style: NeuType.bodySm(isDark),
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            NeuDialogAction.secondary(
                'Remind me later', () => Navigator.pop(context)),
            NeuDialogAction.primary('Update and restart', () {
              Navigator.pop(context);
              _performAppUpdate(info);
            }),
          ],
        );
      },
    ).then((_) {
      _shell.updatePromptOpen = false;
    });
  }

  void _performAppUpdate(UpdateInfo info) {
    double progress = 0.0;
    String statusText = 'Downloading update archive...';

    // The dialog lives in the Navigator's overlay, so rebuilding MainScreen
    // cannot rebuild it. Progress updates must go through the dialog's own
    // StatefulBuilder setter, which was previously captured and never called -
    // leaving the bar frozen at "0.0%" for the entire download and extraction.
    void Function(VoidCallback)? setDialogState;
    void updateDialog(VoidCallback change) {
      change();
      final setter = setDialogState;
      if (setter != null) setter(() {});
    }

    // Closed by handle on failure: see the catch below.
    final progressDialog = RouteHandle();

    // No actions and not dismissible: the binaries are being replaced
    // underneath the running process, so there is genuinely no way out until
    // it finishes or fails. dialog_conformance_test pins this.
    NeuDialog.show<void>(
      context,
      dismissible: false,
      builder: (context) {
        progressDialog.attach(context);
        return StatefulBuilder(
          builder: (context, setProgressState) {
            setDialogState = setProgressState;
            final isDark = themeNotifier.isDarkTheme;
            return NeuDialog(
              title: 'Updating',
              icon: Icons.downloading,
              width: 420,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(statusText,
                      style: NeuType.body(isDark)),
                  const SizedBox(height: NeuSpace.s12),
                  NeuProgressBar(
                    value: progress > 0 ? progress : null,
                    semanticLabel: 'Update download',
                  ),
                  const SizedBox(height: NeuSpace.s8),
                  Text('${(progress * 100).toStringAsFixed(1)}%',
                      style: NeuType.caption(isDark)),
                ],
              ),
            );
          },
        );
      },
    );

    // The steps themselves, and the guard on Exit while they run, are the
    // shell's (AppShellController.applyUpdate); this is what the user sees.
    Future.microtask(() async {
      try {
        await _shell.applyUpdate(info, report: ({status, fraction}) {
          updateDialog(() {
            if (status != null) statusText = status;
            if (fraction != null) progress = fraction;
          });
        });
      } catch (e) {
        // stopAll() may already have killed everything before the failure. The
        // app survives this path, so any session still marked running would
        // stay that way for the rest of the session - and eviction only
        // reclaims finished ones.
        _logNotifier.endAllRunning(-1);
        // THIS dialog, not the top route. Navigator.pop(context) popped
        // whatever was on top - a dialog the tray had opened over the
        // progress dialog, say - and left "Updating", which has no buttons
        // and cannot be dismissed, on screen for good.
        progressDialog.close();
        if (mounted) {
          // Matches the VOD fetch path: the user reads this, and
          // "Update failed: Exception: ..." is noise.
          _showSnackBar(
              'Update failed: ${e.toString().replaceFirst('Exception: ', '')}',
              isError: true);
        }
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
        _channels, _settings, _localVodsProgress, _downloadedVodsRegistry);
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
    _vodSearchController.dispose();
    _pulseController?.dispose();
    _playerService.stopAll();
    _searchController.dispose();
    _sidebarSearchFocus.dispose();
    _oauthServer?.close();
    _downloadCheckTimer?.cancel();
    _favoritesLiveCheckTimer?.cancel();
    // Channel and VOD refresh wiring (see initState).
    _channelsCtl
      ..removeListener(_onRefreshStateChanged)
      ..dispose();
    _vodBrowser
      ..removeListener(_onRefreshStateChanged)
      ..dispose();
    // Persistence and downloads: anything still held is written out.
    _downloads.dispose();
    _settingsRepo.dispose();
    storageWriteFailure.removeListener(_onSaveFailureChanged);
    twitchAuth.helix.removeListener(_onAuthStatusChanged);
    _activity.dispose();
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
    onTrayWatch: _launchTrayChannel,
    onTrayOpenLibrary: _openLibrary,
    // Nothing new may start while the exit runs.
    onExitCommitted: () {
      _favoritesLiveCheckTimer?.cancel();
      _downloadCheckTimer?.cancel();
    },
    onSessionEnding: _downloads.freeze,
    onSessionContinues: _downloads.unfreeze,
  );
  // ---- end shell -------------------------------------------------------------

  /// Resolves the channel by name AT CLICK TIME: menu items can outlive a
  /// poll cycle, and capturing the channel object would launch with stale
  /// title/game metadata (or a channel that just went offline).
  void _launchTrayChannel(String username) {
    final index = _channels.indexWhere((c) => c.username == username);
    if (index == -1) return;
    final channel = _channels[index];
    if (!channel.isLive) return;
    _launchChannelStream(channel);
  }

  /// What an Exit asks before it goes (see AppShellController.requestExit):
  /// whether to pause the downloads that are running, and whether to go
  /// anyway if their queue could not be saved. True to exit.
  Future<bool> _confirmExit() async {
    final hasUnfinished = _playerService.activeDownloadProcesses.isNotEmpty || _playerService.downloadQueue.isNotEmpty;
    if (!hasUnfinished) return true;
    if (!mounted) return false;
    final bool? confirmExit = await NeuDialog.show<bool>(
      context,
      dismissible: true,
      builder: (context) => NeuDialog(
        title: 'Downloads are still running',
        icon: Icons.download_for_offline_outlined,
        content: Text(
          'Exiting pauses them. They resume the next time you start the app.',
          style: NeuType.body(themeNotifier.isDarkTheme),
        ),
        actions: [
          NeuDialogAction.secondary(
              'Keep running', () => Navigator.pop(context, false)),
          NeuDialogAction.primary(
              'Exit and save queue', () => Navigator.pop(context, true)),
        ],
      ),
    );

    if (confirmExit != true) {
      return false;
    }

    await _shell.persistQueueForRestart();

    // They chose "Exit & Save Queue". If that save did not reach disk,
    // exiting now loses the queue with no trace - and the banner that would
    // normally report it goes with the window.
    if (storageWriteFailure.value != null && mounted) {
      final bool? exitAnyway = await NeuDialog.show<bool>(
        context,
        dismissible: true,
        builder: (context) => NeuDialog(
          title: 'Could not save the download queue',
          icon: Icons.error_outline,
          tone: DialogTone.destructive,
          content: Text(
            'Writing to ${storageWriteFailure.value?.path} failed, so the '
            'queued downloads will not resume after a restart.'
            '\n\nThis usually means the folder is full, read-only, or locked '
            'by another program. Go back to fix it and try again.',
            style: NeuType.body(themeNotifier.isDarkTheme),
          ),
          actions: [
            NeuDialogAction.secondary(
                'Go back', () => Navigator.pop(context, false)),
            NeuDialogAction.primary(
                'Exit anyway', () => Navigator.pop(context, true)),
          ],
        ),
      );
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
      _settingsRepo.requestSave();
      // The Library was built from the registry before this scan came back.
      if (_showLibraryView) _refreshLibraryEntries();
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

  Future<void> _ensureDownloadFolderConfigured(VoidCallback onConfigured) async {
    if (_settings.vodDownloadFolder.trim().isNotEmpty) {
      onConfigured();
      return;
    }

    // Null when the prompt was cancelled or dismissed - including while its
    // folder dialog was still open, whose late answer the prompt drops.
    final path = await DownloadFolderPrompt.show(context);
    if (!mounted) return;
    if (path == null) {
      _showSnackBar('Download cancelled: VOD Download Folder is required.', isError: true);
      return;
    }
    setState(() {
      _settings.vodDownloadFolder = path;
    });
    await _saveChannels();
    _checkDownloadedVods();
    onConfigured();
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
        final channelsJson = config['channels'];
        int skippedChannels = 0;
        if (channelsJson is List) {
          for (final item in channelsJson) {
            // Per-item parsing: a single malformed entry previously threw out to
            // the outer catch before any channel was installed, leaving the list
            // empty - and the next autosave then wrote that empty list to disk.
            final channel = TwitchChannel.tryFromJson(item);
            if (channel != null) {
              loadedChannels.add(channel);
            } else if (item != null) {
              skippedChannels++;
            }
          }
        }
        if (skippedChannels > 0) {
          print('[Config] Skipped $skippedChannels unreadable channel entries.');
        }
        final settingsJson = config['settings'];
        if (settingsJson is Map<String, dynamic>) {
          try {
          setState(() {
            _settings = AppSettings.fromJson(settingsJson);
            _sidebarCollapsed = _settings.sidebarCollapsed;
            // The Followed/Live tabs are hidden without a token; restoring a
            // persisted tab index would strand the user on an invisible tab.
            _sidebarTab = _settings.twitchOauthToken.trim().isEmpty
                ? 0
                : _settings.activeSidebarTab;
            themeNotifier.setDarkTheme(_settings.isDarkTheme);
            // Resolved, not clamped. An unknown key - a material this build
            // does not have, from a newer one that did - falls back for the
            // session and is left alone in the file, rather than being
            // rewritten to `rack` by the next window resize.
            final storedMaterial = AppMaterial.fromKey(_settings.material);
            if (storedMaterial != null &&
                MaterialSpec.isImplemented(storedMaterial)) {
              themeNotifier.setMaterial(storedMaterial);
            }

            // Restore the accent the user actually picked. Previously this read
            // `primaryColorHex`, a field no code path ever wrote, so it was
            // always the default purple and silently overwrote the saved accent
            // on every launch while the real value sat unused in the config.
            themeNotifier.setLightAccent(
              parseHexColor(_settings.lightAccentColorHex, NeuTheme.defaultLightAccent),
            );
            themeNotifier.setDarkAccent(
              parseHexColor(_settings.darkAccentColorHex, NeuTheme.defaultDarkAccent),
            );
            themeNotifier.updateTheme(
              // User-configurable hex settings; these are their defaults, not theme colors.
              activeProgress: parseHexColor(_settings.activeProgressColorHex, const Color(0xFF9146FF)),
              watchedProgress: parseHexColor(_settings.watchedProgressColorHex, const Color(0x804CAF50)),
            );
          });
          } catch (e) {
            // Keep going with default settings rather than aborting the whole
            // load - the outer catch would abandon the channel list too, and
            // the next autosave would persist the loss.
            print('[Config] Settings unreadable, using defaults: $e');
          }
        }
        final localProgressJson = config['local_vods_progress'];
        if (localProgressJson is Map) {
          // Skip unusable entries rather than letting one bad value (`v as int`
          // on a double or string) abort the entire config load.
          final progress = <String, int>{};
          localProgressJson.forEach((k, v) {
            final position = v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
            if (position != null) progress[k.toString()] = position;
          });
          _localVodsProgress = progress;
          _progressStore = WatchProgressStore.fromJson(
              progress.map((k, v) => MapEntry(k, v as dynamic)));
        }
        final downloadedVodsJson = config['downloaded_vods'];
        if (downloadedVodsJson is Map) {
          final registry = <String, String>{};
          downloadedVodsJson.forEach((k, v) {
            if (v != null) registry[k.toString()] = v.toString();
          });
          _downloadedVodsRegistry = registry;
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
      await _loadWatchHistory();

      await _refreshAllChannels(isInitialLoad: true);
      // Ask Twitch whether the token works BEFORE using it. The old gate was
      // `isNotEmpty`, which is a test of the string and not of the account, so
      // a revoked token spent every launch failing a real request and pasting
      // the raw 401 body into a snackbar.
      await _refreshHelixAuth();
      if (twitchAuth.helix.value.isUsable) {
        _loadFollowedChannels();
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
      if (!_settingsRepo.historyLoaded) await _loadWatchHistory();
      // Arms the recovery refresh. Startup already fetches everything, so
      // arming earlier would make the first successful probe refresh it all a
      // second time.
      _startupComplete = true;
      if (mounted) setState(() => _isGlobalLoading = false);
    }
  }

  /// Reads watch_progress.json and the recently-watched list into memory,
  /// then lets them be written.
  Future<void> _loadWatchHistory() async {
    try {
      // The sidecar is authoritative where it has an entry: it carries the
      // furthest point and the undo trail, which the flat compatibility copy
      // in the config cannot express.
      final sidecar = await _storageService.loadWatchProgress();
      if (sidecar.isNotEmpty) {
        final merged = <String, dynamic>{
          ..._progressStore.toJson(),
          ...sidecar,
        };
        _progressStore = WatchProgressStore.fromJson(merged);
        _localVodsProgress = _progressStore.toFlatMap();
      }

      final recents = await _storageService.loadRecentWatchedVods();
      if (mounted) {
        setState(() {
          _recentWatchedVods =
              recents.map(TwitchVideo.tryFromJson).whereType<TwitchVideo>().toList();
        });
      }
    } catch (e, st) {
      // Both readers already fall back to empty on a damaged file; this is
      // for anything else, which must not stop the channels loading after it.
      CrashLog.current?.error('loading watch history', e, st);
    } finally {
      _settingsRepo.markHistoryLoaded();
    }
  }

  /// Offers to jump to the furthest point reached, when playback starts behind it.
  ///
  /// Deferred rather than immediate: the player needs a moment to come up and
  /// register its control port before a seek can land, and the message is
  /// useless before there is something to seek.
  void _offerFurthestPosition(TwitchVideo vod) {
    if (_progressStore[vod.id]?.hasRecoverablePosition != true) return;

    Future<void>.delayed(const Duration(seconds: 6), () {
      if (!mounted) return;
      if (!_playerService.playingVodIds.contains(vod.id)) return;
      // Re-read at fire time, not before the wait. The session writes its own
      // position as soon as it has landed, so by now playback may already be
      // past the furthest point - in which case there is nothing to offer and
      // saying otherwise would just be noise.
      final entry = _progressStore[vod.id];
      if (entry == null || !entry.hasRecoverablePosition) return;
      final best = entry.best;
      final label = _formatClock(best);
      _showSnackBar(
        'You had reached $label in this VOD.',
        isError: false,
        action: SnackBarAction(
          label: 'Jump there',
          onPressed: () async {
            final ok =
                await _playerService.seekActiveVod(vod.id, best, _settings);
            if (!mounted) return;
            _showSnackBar(
                ok
                    ? 'Jumped to $label.'
                    : 'Could not reach the player to jump; seek there manually.',
                isError: !ok);
          },
        ),
      );
    });
  }

  String _formatClock(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final sec = totalSeconds % 60;
    String two(int v) => v < 10 ? '0$v' : '$v';
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  /// Re-fetches what a rejected token left stale.
  ///
  /// Reconnecting reloaded the FOLLOWED list and nothing else, so every
  /// favourite kept the error text stamped on it while the token was dead -
  /// "Helix Stream API error: status 401" sat on the selected channel until
  /// the one-minute favourites poll happened to clear it, minutes after the
  /// account was working again. The data was stale, not wrong, which is the
  /// worst kind of wrong to show someone who has just fixed the problem.
  void _onAuthStatusChanged() {
    final usable = twitchAuth.helix.value.isUsable;
    final recovered = usable && !_lastAuthUsable;
    _lastAuthUsable = usable;

    if (usable && _authWarningDismissed) {
      // A dismissal covers the rejection it was shown for. Without this, one
      // dismissal would silence every future rejection carrying the same
      // reason, for the life of the process.
      _authWarningDismissed = false;
      _dismissedFault = TwitchAuthFault.none;
    }

    if (!recovered || !_startupComplete) return;
    unawaited(_refreshAllChannels());
    unawaited(_loadFollowedChannels());
    // ...and the open channel's VOD list, which is fetched per selection and
    // would otherwise keep its 401 until the user clicked away and back.
    final open = _selectedChannel;
    if (open != null) {
      setState(() => _vodsError = null);
      unawaited(_fetchVodsForChannel(open));
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

  /// Connect Account: signs in through Twitch in the browser.
  ///
  /// The listener itself (state check, timeout, single-shot result) is
  /// OAuthLoopbackServer; this only starts it and applies what comes back.
  Future<void> _startOAuthServer() async {
    // A second Connect replaces the first sign-in rather than racing it: the
    // older one's result arrives as cancelled and is ignored below.
    final previous = _oauthServer;
    _oauthServer = null;
    await previous?.close();

    final server = OAuthLoopbackServer(
      port: _settings.localServerPort,
      clientId: _settings.twitchClientId,
    );
    try {
      await server.start();
    } catch (e) {
      _showSnackBar('Failed to start local login server: ${describeTwitchError(e)}', isError: true);
      return;
    }
    _oauthServer = server;
    _showSnackBar('OAuth server started on port ${server.boundPort}. Opening browser...', isError: false);
    await _openExternalLink(server.authorizeUrl);

    final result = await server.result;
    // Replaced by a newer sign-in, or the screen is gone.
    if (!identical(_oauthServer, server) || !mounted) return;
    _oauthServer = null;

    switch (result.outcome) {
      case OAuthLoopbackOutcome.token:
        await _acceptOAuthToken(result.accessToken!, mintedBy: server.clientId);
      case OAuthLoopbackOutcome.denied:
        _showSnackBar('Twitch did not connect the account: ${result.error}', isError: true);
      case OAuthLoopbackOutcome.timedOut:
        _showSnackBar(
            'The Twitch sign-in timed out. Click Connect Account to try again.',
            isError: false);
      case OAuthLoopbackOutcome.cancelled:
        break;
    }
  }

  Future<void> _acceptOAuthToken(String token, {required String mintedBy}) async {
    setState(() {
      _settings.twitchOauthToken = 'oauth:$token';
      // Record WHICH client minted it. Without this, editing the
      // Client ID field later produces a 401 the app would have to
      // guess at, and it would guess "expired" - sending the user
      // through a reconnect that cannot fix a mismatch. The Client ID the
      // sign-in actually used, never blank: the raw field was recorded
      // before, which is empty when the public fallback signed in, and an
      // empty mint switches the mismatch pre-check off.
      _settings.twitchTokenClientId = mintedBy;
    });
    await _saveChannels();
    twitchAuth.setHelix(statusForToken(_settings.twitchOauthToken,
        mintedClientId: _settings.twitchTokenClientId));
    _showSnackBar('Twitch account connected successfully!', isError: false);
    // No explicit reload here: the probe publishes the new status,
    // and _onAuthStatusChanged refreshes both lists off that
    // transition. Calling it here too fetched the followed list twice
    // on every reconnect.
    await _refreshHelixAuth(force: true);
  }

  /// Loads the followed list (see ChannelsController.loadFollowed: coalesced,
  /// reconciled into the existing objects, live state in one batched pass).
  ///
  /// [background] is the periodic reload, so a new follow on twitch.tv turns
  /// up without a restart. It reports nothing but a refused token: an
  /// unattended reload that hit a network blip is not worth interrupting
  /// anyone for, and the previous list stays in place.
  Future<void> _loadFollowedChannels({bool background = false}) async {
    try {
      final result = await _channelsCtl.loadFollowed();
      if (!mounted || result == null) return;
      setState(() {
        _authenticatedUserLogin = result.userLogin;
        _authenticatedUserAvatar = result.userAvatar;
        // The open channel follows its streamer to the object the poll now
        // keeps current. A reload used to replace every object and leave it
        // pointing at one nothing refreshed any more.
        final open = _selectedChannel;
        if (open != null) _selectedChannel = _channelsCtl.canonical(open);
      });
      if (!result.isComplete && !background) {
        // Not silent: a failed later page used to shorten the list without a
        // word. reconcileWith kept what it did not reach, so nothing went.
        final why = result.pageError == null
            ? ''
            : ': ${describeTwitchError(result.pageError!)}';
        _showSnackBar(
            'Showing ${_followedChannels.length} followed channels; Twitch '
            'did not return the rest$why',
            isError: true);
      }
    } catch (e) {
      if (!mounted) return;
      if (e is TwitchApiException && e.isAuthFailure) {
        // The banner does the talking, and it offers the one button that
        // actually fixes this. A snackbar cannot: it scrolls away, it has no
        // remedy on it, and it used to carry a raw JSON body.
        unawaited(_refreshHelixAuth(force: true));
      } else if (!background) {
        _showSnackBar(
            'Could not load followed channels: ${describeTwitchError(e)}',
            isError: true);
      }
    }
  }

  /// Probes the account token and publishes the verdict.
  ///
  /// [force] re-probes even when the status is already known, which is what a
  /// Helix 401 and a fresh OAuth capture both need.
  Future<void> _refreshHelixAuth({bool force = false}) async {
    final token = _settings.twitchOauthToken.trim();
    if (token.isEmpty) {
      twitchAuth.setHelix(TwitchAuthStatus.absent);
      return;
    }
    final current = twitchAuth.helix.value;
    if (!force && current.state == TwitchAuthState.valid) return;

    // A mismatch between the token's mint and the configured Client ID is
    // detectable with no request at all, which matters on an offline launch.
    final minted = _settings.twitchTokenClientId.trim();
    // The effective one, as a sign-in records it: a blank field signs in,
    // and sends every request, with the public client.
    final configured =
        OAuthLoopbackServer.effectiveClientId(_settings.twitchClientId);
    if (minted.isNotEmpty && minted != configured) {
      twitchAuth.setHelix(TwitchAuthStatus(
        state: TwitchAuthState.invalid,
        fault: TwitchAuthFault.clientIdMismatch,
        login: current.login,
        tokenClientId: minted,
        checkedAt: DateTime.now(),
      ));
      return;
    }

    twitchAuth.setHelix(statusChecking(current));
    final status =
        await _apiService.validateHelixToken(token, _settings.twitchClientId);
    twitchAuth.recordHelixProbe(status);
    if (mounted) setState(() {});
  }

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

  late final VodBrowserController _vodBrowser = VodBrowserController(
    api: _apiService,
    settings: () => _settings,
    localProgress: () => _localVodsProgress,
    clock: _services.clock,
  );

  bool get _hasAccountToken => _settings.twitchOauthToken.trim().isNotEmpty;

  /// Either controller changed something on screen. Each notifies once per
  /// refresh phase, so a poll repaints the sidebar and the welcome screen
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
    // fixing it refreshes everything anyway (_onAuthStatusChanged).
    if (!twitchAuth.helix.value.isUsable) return;
    if (_channelsCtl.isFollowedReloadDue) {
      unawaited(_loadFollowedChannels(background: true));
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
    unawaited(_announceWentLive(pass).whenComplete(() {
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

    unawaited(_vodBrowser.prefetch(_channels));
    _shell.rebuildTrayMenu();
  }

  /// The went-live toasts for one pass, one after another, over the pass's
  /// own lists. This used to await each toast inside a loop over _channels,
  /// and starring a channel during that await threw
  /// ConcurrentModificationError and skipped the rest of the pass.
  Future<void> _announceWentLive(ChannelsPass pass) async {
    final channels = <TwitchChannel>[
      if (_settings.notifyWentLive) ...pass.favoritesWentLive,
      if (_settings.notifyFollowedWentLive) ...pass.followedWentLive,
    ];
    for (final channel in channels) {
      try {
        final gameText = channel.game ?? 'Twitch';
        final titleText = channel.streamTitle ?? 'Streaming Live!';
        await _notifications.show(AppNotification(
          title: '${channel.username} is now LIVE!',
          body: 'Playing $gameText\n$titleText',
          onClick: () async {
            await _shell.showWindow();
            if (!mounted) return;
            _selectChannel(channel);

            _playerService.launchStreamlinkForLive(
              channel.username,
              channel.isLive,
              channel.streamTitle,
              channel.game,
              _settings,
            );
          },
        ));
      } catch (e) {
        print('[Favorites Notification] Error displaying desktop toast: $e');
      }
    }
  }

  /// A channel's archive gained a VOD (see VodBrowserController.onNewVods).
  /// Announced for favourites only, and not for the open channel while the
  /// window is on screen: the grid shows it arriving. Nor for a VOD the
  /// auto-download pass takes, which has a toast of its own.
  void _onNewVods(TwitchChannel channel, List<TwitchVideo> vods,
      List<TwitchVideo> firstPage) {
    if (!mounted || !_settings.notifyNewVod || vods.isEmpty) return;
    final name = channel.username.toLowerCase().trim();
    final index = _channels.indexWhere((c) => c.username == name);
    if (index == -1) return;
    if (_shell.windowVisible &&
        !_showLibraryView &&
        _selectedChannel?.username == name) {
      return;
    }
    final news =
        _automation.newVodsToAnnounce(_channels[index], vods, firstPage);
    if (news.isEmpty) return;
    unawaited(_announceNewVods(name, news));
  }

  Future<void> _announceNewVods(String name, List<TwitchVideo> vods) async {
    try {
      final more = vods.length - 1;
      await _notifications.show(AppNotification(
        title: 'New VOD from $name',
        body: more > 0 ? '${vods.first.title}\n+$more more' : vods.first.title,
        onClick: () async {
          await _shell.showWindow();
          if (!mounted) return;
          final index = _channels.indexWhere((c) => c.username == name);
          if (index != -1) _selectChannel(_channels[index]);
        },
      ));
    } catch (e) {
      print('[New VOD Notification] Error displaying desktop toast: $e');
    }
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
    setState(() {
      _showLibraryView = false;
      _selectedChannel = target;
      _selectedGamesFilter.clear();
      _selectedVodIds.clear();
    });
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
      _playerService.playingVodIds.isNotEmpty || _activePlayingVideos.isNotEmpty;

  /// One favorites automation pass (AutomationService.runPass); a call
  /// while one is still running does nothing.
  Future<void> _checkFavoritesAutomation() => _automation.runPass();

  Future<void> _addChannel(String name) async {
    final cleanName = name.toLowerCase().trim();
    // Refused before the spinner shows: nothing Twitch could say about a name
    // that cannot be a login is more useful than saying so at once.
    switch (_channelsCtl.checkAdd(cleanName)) {
      case AddCheck.empty:
      case AddCheck.pending:
        // A second Enter while the first lookup runs; it is on its way.
        return;
      case AddCheck.invalidName:
        _showSnackBar('"$cleanName" is not a valid Twitch username.', isError: true);
        return;
      case AddCheck.duplicate:
        _showSnackBar('Channel "$cleanName" is already in your list.', isError: true);
        return;
      case AddCheck.ok:
        break;
    }

    setState(() => _isAdding = true);
    final outcome = await _channelsCtl.addFavorite(cleanName);
    if (!mounted) return;
    setState(() => _isAdding = _channelsCtl.hasPendingAdds);

    final added = outcome.channel;
    if (added == null) {
      _showSnackBar(
          outcome.check == AddCheck.duplicate
              ? 'Channel "$cleanName" is already in your list.'
              : 'Failed to add channel: ${outcome.error}',
          isError: true);
      return;
    }

    _searchController.clear();
    // Opened through the one selection path, so the grid loads this channel's
    // VODs rather than going on showing the previous channel's under its
    // header.
    _selectChannel(added);

    await _saveChannels();
    if (!mounted) return;
    _showSnackBar('Channel "$cleanName" added successfully!', isError: false);
  }

  /// Records a channel that is ALREADY live at the moment it joins the list.
  ///
  /// The went-live check fires for any live channel missing from this set, so
  /// starring or adding someone mid-broadcast produced an "is now LIVE!"
  /// notification up to a minute later for a stream the user had just been
  /// looking at - and, with auto-play configured, could launch it unasked.
  void _seedLiveTracking(TwitchChannel channel) {
    if (!channel.isLive) return;
    _previouslyLiveFavoriteUsernames.add(channel.username.toLowerCase().trim());
  }

  Future<void> _toggleFavorite(TwitchChannel channel) async {
    final cleanName = channel.username.toLowerCase().trim();
    final isFavorite = _channels.any((c) => c.username == cleanName);

    if (isFavorite) {
      // Removing a favorite also discards its automation configuration, which
      // there is no way to undo. Confirm when there is something to lose - a
      // single mis-click on the star used to silently destroy it.
      final existing = _channels.firstWhere((c) => c.username == cleanName);
      if (existing.autoPlayLive || existing.autoDownloadVods) {
        final confirmed = await NeuDialog.show<bool>(
          context,
          dismissible: true,
          builder: (context) => NeuDialog(
            title: 'Remove ${channel.username} from favourites?',
            icon: Icons.star_border,
            tone: DialogTone.destructive,
            content: Text(
              'Its automation is discarded and cannot be undone:'
              '${existing.autoPlayLive ? '\n• Auto-play when live (priority #${existing.autoPlayPriority + 1})' : ''}'
              '${existing.autoDownloadVods ? '\n• Auto-download VODs (keep ${existing.maxVodKeepCount})' : ''}'
              '\n\nAlready-downloaded files are kept.',
              style: NeuType.body(themeNotifier.isDarkTheme),
            ),
            actions: [
              NeuDialogAction.secondary(
                  'Keep it', () => Navigator.pop(context, false)),
              NeuDialogAction.primary(
                  'Remove', () => Navigator.pop(context, true)),
            ],
          ),
        );
        if (confirmed != true) return;
      }

      setState(() {
        _channels.removeWhere((c) => c.username == cleanName);
        // Drop tracking state for the removed channel so it cannot resurface as
        // a stale "went live" notification or auto-play session later.
        _previouslyLiveFavoriteUsernames.remove(cleanName);
        _automation.forgetChannel(cleanName);
        if (_selectedChannel?.username == cleanName) {
          _selectedChannel = null;
        }
      });
      await _saveChannels();
      _showSnackBar('Removed "${channel.username}" from Favorites.', isError: false);
    } else {
      final newFav = TwitchChannel(username: cleanName);
      newFav.avatarUrl = channel.avatarUrl;
      newFav.isLive = channel.isLive;
      newFav.uptime = channel.uptime;
      newFav.viewerCount = channel.viewerCount;
      newFav.game = channel.game;
      newFav.streamTitle = channel.streamTitle;
      
      setState(() {
        _channels.add(newFav);
      });
      _seedLiveTracking(newFav);
      await _saveChannels();
      _showSnackBar('Added "${channel.username}" to Favorites.', isError: false);
      
      _apiService.fetchChannelStats(newFav, _settings).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _bulkUpdateSelectedVods(bool markAsWatched) async {
    // No browser token required. The write that matters is local, and refusing
    // without a token blocked the whole feature to protect a sync that Twitch
    // rejects anyway; a token, when present, is used opportunistically.
    final webToken = _settings.twitchWebOauthToken.trim();

    if (_selectedVodIds.isEmpty) {
      _showSnackBar('No VODs selected.', isError: true);
      return;
    }

    setState(() {
      _isBulkUpdatingVods = true;
    });

    int successCount = 0;

    for (var videoId in _selectedVodIds) {
      final vodIndex = _channelVods.indexWhere((v) => v.id == videoId);
      if (vodIndex == -1) continue;

      final vod = _channelVods[vodIndex];
      int targetPosition = 0;
      if (markAsWatched) {
        targetPosition = _apiService.parseDurationToSeconds(vod.duration);
      }

      setState(() {
        _localVodsProgress[videoId] = targetPosition;
        // An explicit user action, so it may move the furthest point too -
        // "mark unwatched" has to genuinely mean unwatched.
        if (targetPosition <= 0) {
          _progressStore.clear(videoId);
        } else {
          _progressStore.record(videoId, targetPosition,
              nowMs: DateTime.now().millisecondsSinceEpoch,
              sessionAgeMs: kSessionGraceSeconds * 1000 + 1);
        }
        vod.watchPosition = targetPosition;
        vod.watchProgress = markAsWatched ? 1.0 : 0.0;
      });
      successCount++;

      if (webToken.isNotEmpty) {
        try {
          _apiService.syncSingleVODProgressDirect(videoId, targetPosition, webToken).catchError((_) {});
        } catch (_) {}
      }
    }

    setState(() {
      _isBulkUpdatingVods = false;
      _isMultiSelectMode = false;
      _selectedVodIds.clear();
    });

    if (successCount > 0) {
      await _saveChannels();
      // Careful with this wording. Local progress is merged as
      // max(local, remote) on the next fetch, so marking WATCHED sticks - it
      // only ever raises the position - while marking UNWATCHED sets it to 0
      // and is silently overwritten by the remote position on the next fetch
      // whenever a browser token is present. Claiming a clean local update
      // would just replace one over-claim with another.
      final revertible = !markAsWatched && webToken.isNotEmpty;
      _showSnackBar(
        revertible
            ? 'Marked $successCount VODs unwatched here. Twitch still has a '
                'position for them, so this may come back on the next refresh.'
            : 'Marked $successCount VODs watched here. Twitch does not accept '
                'watch history from third-party apps, so this stays local.',
        isError: false,
      );
    }
  }

  Future<void> _openExternalLink(String url) async {
    try {
      if (!Platform.isWindows) {
        _showSnackBar('Unsupported platform for launching external link', isError: true);
        return;
      }

      // Launched via Explorer, NOT `cmd /c start`.
      //
      // The app now runs inside a job object with KILL_ON_JOB_CLOSE so its
      // helper processes cannot outlive it. Anything the app spawns inherits
      // that job - so a browser started through cmd became a job member and was
      // killed the moment the app closed. Explorer is already running outside
      // our job, so handing the URL to it launches the browser out of reach.
      //
      // THE TRAILING SPACE IS LOAD-BEARING. Do not "clean it up".
      //
      // explorer.exe does not parse its command line with the standard argv
      // rules - handed a bare URL containing `&` it splits it and passes a
      // fragment to the shell. The Twitch sign-in URL ends in
      // `scope=user:read:follows`, so Windows was asked to open a `user:`
      // protocol and answered with "Get an app to open this 'user' link"
      // instead of opening a browser. Every link with a query string was
      // affected; the OAuth one just happened to end in something that looks
      // like a URL scheme.
      //
      // Dart quotes an argument only when it contains a space, tab or quote,
      // and a URL contains none of those, so it arrived unquoted. Appending a
      // space forces the quoting, and a quoted URL is what explorer accepts
      // whole. Measured against a local listener: bare delivers nothing,
      // quoted delivers the full query string, and explorer trims the space.
      await Process.start('explorer.exe', ['$url '],
          mode: ProcessStartMode.detached);
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
    // Errors use the fixed danger red (white text); info follows the accent.
    //
    // Replace rather than queue: ScaffoldMessenger plays queued snackbars one
    // after another, so a burst of messages read as one that would not go
    // away. Only the newest is worth showing.
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          // w600: w500 is not a real weight in Segoe UI, so this snackbar
          // has always rendered at w400. A notification should stand out.
          style: TextStyle(
            color: isError
                ? NeuTheme.onAccent(NeuTheme.danger)
                : themeNotifier.onPrimaryColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: isError ? NeuTheme.danger : themeNotifier.primaryColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r8)),
        margin: const EdgeInsets.all(NeuSpace.s12),
        // Long enough to read and act on, short enough to get out of the way.
        duration: Duration(seconds: action != null ? 8 : 3),
        showCloseIcon: true,
        closeIconColor: isError ? Colors.white : themeNotifier.onPrimaryColor,
        action: action,
      ),
    );
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

  /// Recomputes the activity snapshot from the service's live maps.
  void _publishActivity() {
    _activity.value = buildActivitySnapshot(
      downloadTaskIds: _playerService.activeDownloadTasks.keys,
      downloadQueue: _playerService.downloadQueue,
      startedIds: _playerService.activeDownloadProcesses.keys.toSet(),
      downloadTitles: _playerService.downloadTitles,
      downloadProgress: _playerService.activeDownloadsProgress,
      downloadStatuses: _playerService.activeDownloadTasks,
      playingVodIds: _playerService.playingVodIds,
      runningChannels: _playerService.runningChannels,
      vodTitles: {
        for (final entry in _activePlayingVideos.entries)
          entry.key: entry.value.title,
      },
    );
  }

  /// Stops or cancels one activity item, confirming first where something
  /// would be lost. Routing is by kind, never by parsing the key - sending a
  /// download key to killProcess trips an assert in PlayerService.
  Future<void> _stopActivity(ActivityItem item) async {
    switch (item.kind) {
      case ActivityKind.queued:
        // Nothing has started, so nothing is lost.
        await _cancelVodDownload(
            item.id, _playerService.downloadChannelNames[item.id] ?? 'VOD');
      case ActivityKind.downloading:
        if (!await _confirmStop(isDownload: true)) return;
        await _cancelVodDownload(
            item.id, _playerService.downloadChannelNames[item.id] ?? 'VOD');
      case ActivityKind.liveStream:
        if (!await _confirmStop(isDownload: false)) return;
        _playerService.killLiveStream(item.id);
      case ActivityKind.playingVod:
        if (!await _confirmStop(isDownload: false)) return;
        _playerService.killProcess(item.id);
    }
    if (mounted) {
      _publishActivity();
      setState(() {});
    }
  }

  Future<bool> _confirmStop({required bool isDownload}) async {
    final result = await NeuDialog.show<bool>(
      context,
      dismissible: true,
      builder: (context) => NeuDialog(
        title: isDownload ? 'Cancel this download?' : 'Stop playback?',
        icon: isDownload ? Icons.downloading : Icons.stop_circle_outlined,
        tone: isDownload ? DialogTone.destructive : DialogTone.neutral,
        content: Text(
          isDownload
              ? 'The partial file is deleted. The VOD stays available to '
                  'download again.'
              : 'This closes the player window.',
          style: NeuType.body(themeNotifier.isDarkTheme),
        ),
        actions: [
          NeuDialogAction.secondary(
              'Keep running', () => Navigator.pop(context, false)),
          NeuDialogAction.primary(isDownload ? 'Cancel download' : 'Stop',
              () => Navigator.pop(context, true)),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _clearWatchProgress() async {
    setState(() {
      _localVodsProgress.clear();
      _progressStore.clearAll();
      for (final vod in _channelVods) {
        // Both fields, not just the percentage: zeroing watchProgress while
        // leaving watchPosition was an internally inconsistent state, and
        // _playVod now derives progress FROM position - so a lone position
        // would resurrect the "progress" this action exists to clear.
        vod.watchProgress = 0.0;
        vod.watchPosition = 0;
      }
    });
    await _saveChannels();

    // Best-effort push of the reset to Twitch, else the remote max-merge
    // restores the old positions on the next fetch and the clear appears
    // not to have worked. Mirrors _bulkUpdateSelectedVods.
    String webToken = _settings.twitchWebOauthToken.trim();
    if (webToken.startsWith('oauth:')) webToken = webToken.substring(6);
    if (webToken.isNotEmpty) {
      for (final vod in _channelVods) {
        try {
          await _apiService.syncSingleVODProgressDirect(vod.id, 0, webToken);
        } catch (_) {
          break; // one failure means the rest will fail the same way
        }
      }
    }
    _showSnackBar('Local watch progress history cleared!', isError: false);
  }

  /// Launches [channel]'s live stream using ITS OWN metadata. The old
  /// double-tap path received only a username and looked title/game/live up on
  /// _selectedChannel, so double-tapping a non-selected row launched with a
  /// different channel's metadata.
  void _launchChannelStream(TwitchChannel channel) {
    if (_playerService.runningChannels
        .contains(channel.username.toLowerCase().trim())) {
      return;
    }
    _playerService.launchStreamlinkForLive(
      channel.username,
      channel.isLive,
      channel.streamTitle,
      channel.game,
      _settings,
    );
  }

  UpdateInfo? _pendingUpdateInfo;

  void _showSettingsDialog() {
    SettingsDialog.show(
      context,
      settings: _settings,
      themeNotifier: themeNotifier,
      authenticatedUserLogin: _authenticatedUserLogin,
      onRevalidateHelix: () => _refreshHelixAuth(force: true),
      onConnectAccount: _startOAuthServer,
      openExternalLink: _openExternalLink,
      onClearWatchHistory: _clearWatchProgress,
      onOpenLogs: () => LogViewerDialog.show(context, logs: _logNotifier),
      apiService: _apiService,
      // Stash it; the prompt is offered AFTER the dialog closes. The old
      // post-frame callback fired while Settings was still open and stacked
      // the prompt behind the modal.
      onUpdateAvailable: (info) => _pendingUpdateInfo = info,
      onSave: (updatedSettings) async {
        final startupChanged =
            _settings.launchAtStartup != updatedSettings.launchAtStartup;
        // Which credentials this save replaces; see the reset after saving.
        final tokenChanged = _settings.twitchOauthToken.trim() !=
            updatedSettings.twitchOauthToken.trim();
        final helixChanged = tokenChanged ||
            _settings.twitchClientId.trim() !=
                updatedSettings.twitchClientId.trim();
        final browserChanged = _settings.twitchWebOauthToken.trim() !=
            updatedSettings.twitchWebOauthToken.trim();
        // Simple rendering takes effect at once when turned on: lit painters
        // repaint through Canvas the moment the engine is disabled. Turning
        // it off needs the shader loaded and self-tested, which happens at
        // launch, so that half waits for the next start.
        if (updatedSettings.canvasEngine && !_settings.canvasEngine) {
          LitSurfaceProgram.disable('Simple rendering turned on in Settings');
          _logNotifier.appendLog(_appLogKey,
              '[System] Surface engine: ${LitSurfaceProgram.status}');
        }
        setState(() {
          _settings = updatedSettings;
          _isWebTokenExpired = false;
        });
        await _saveChannels();
        if (!mounted) return;

        // The status described credentials this save just replaced: "Connected
        // as A" stayed up for the session after switching to B, and clearing
        // the token left "Connected". Start again from what is known of the
        // new pair, and probe it now rather than at the next 401. The followed
        // list may be another account's, and so may a load still out for it.
        if (helixChanged) {
          twitchAuth.setHelix(statusForToken(_settings.twitchOauthToken,
              mintedClientId: _settings.twitchTokenClientId));
          unawaited(_refreshHelixAuth(force: true));
        }
        if (browserChanged) {
          twitchAuth.setBrowser(statusForToken(_settings.twitchWebOauthToken));
        }
        if (tokenChanged) _channelsCtl.clearFollowed();

        if (startupChanged) {
          _services.startup.sync(_settings.launchAtStartup);
        }
        // The tray menu preference may have flipped.
        _shell.rebuildTrayMenu(force: true);

        if (_settings.twitchOauthToken.trim().isNotEmpty) {
          _loadFollowedChannels();
        } else {
          setState(() {
            _followedChannels.clear();
            _authenticatedUserLogin = null;
            _authenticatedUserAvatar = null;
            _sidebarTab = 0;
          });
        }
        _showSnackBar('Settings saved successfully!', isError: false);
      },
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
      authenticatedUserLogin: _authenticatedUserLogin,
      authenticatedUserAvatar: _authenticatedUserAvatar,
      pulseController: _pulseController!,
      searchController: _searchController,
      onChannelSelected: _selectChannel,
      onChannelDoubleTapped: _launchChannelStream,
      onChannelPlayPressed: _launchChannelStream,
      onAddChannel: _addChannel,
      onToggleFavorite: _toggleFavorite,
      onToggleCollapse: (collapsed) {
        setState(() {
          _sidebarCollapsed = collapsed;
          _settings.sidebarCollapsed = collapsed;
        });
        _saveChannels();
      },
      onGoToDashboard: () {
        setState(() {
          _showLibraryView = false;
          _selectedChannel = null;
        });
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
          _loadFollowedChannels();
        }
      },
      onRefresh: () async {
        if (_sidebarTab == 0) {
          await _refreshAllChannels();
        } else if (_sidebarTab == 1) {
          await _loadFollowedChannels();
        } else {
          await Future.wait([
            _refreshAllChannels(),
            _loadFollowedChannels(),
          ]);
        }
      },
      onShowSettings: _showSettingsDialog,
      onShowLibrary: _openLibrary,
    );

    final contentArea = Expanded(
      // No fill of its own. AppChassis already paints the whole window body
      // as a lit panel - grain, ramp and light - and a flat token fill here
      // was covering it across the largest region of the app, so the
      // machined ground existed only behind the sidebar and title bar while
      // every card floated on flat paper.
      child: Container(
        child: _showLibraryView
            ? _buildLibraryView()
            : _selectedChannel == null
                ? _buildHome()
                : _buildDashboard(_selectedChannel!),
      ),
    );

    return AppLayout(
      data: layout,
      child: Scaffold(
      // The window chassis, which had no host until now. `titleBarStyle` is
      // hidden and this Scaffold's own background was a flat colour, so every
      // pixel of the frame is ours to paint and nothing was painting it.
      body: AppChassis(
      child: CallbackShortcuts(
        bindings: {
          // Esc leaves the Library. Dialogs sit on their own Navigator route
          // and consume Esc before it reaches here, so this cannot steal a
          // dialog's dismiss.
          const SingleActivator(LogicalKeyboardKey.escape): _closeLibrary,
          // Focus the sidebar search from anywhere. In layouts without the
          // inline field the search popover is the affordance instead.
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
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
        },
        child: Focus(
          autofocus: true,
          child: Column(
        children: [
          NeuTitleBar(
            // The chassis ornament lands here. Asking the chassis rather than
            // recomputing the predicate keeps the clearance and the ornament
            // from ever disagreeing about what is drawn at the edges.
            edgeInset: AppChassis.edgeClearance(context),
            liveCount: _channels.where((c) => c.isLive).length,
            actions: [
              ActivityPill(
                activity: _activity,
                onStop: _stopActivity,
                compact: isNarrow,
              ),
              const SizedBox(width: NeuSpace.s12),
            ],
            isDarkTheme: themeNotifier.isDarkTheme,
            onThemeToggle: (isDark) {
              setState(() {
                themeNotifier.setDarkTheme(isDark);
                _settings.isDarkTheme = isDark;
              });
              _saveChannels();
            },
          ),
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
              if (status.needsReconnect &&
                  _authWarningDismissed &&
                  status.fault != _dismissedFault) {
                // A different problem is a different message; a dismissal
                // covers the reason it was shown for, not the topic.
                _authWarningDismissed = false;
              }
              if (!status.needsReconnect || _authWarningDismissed) {
                return const SizedBox.shrink();
              }
              return TwitchAuthBanner(
                status: status,
                // Reconnecting happens on the banner: see TwitchAuthBanner.
                onReconnect: _startOAuthServer,
                onDismiss: () => setState(() {
                  _authWarningDismissed = true;
                  _dismissedFault = status.fault;
                }),
              );
            },
          ),
          Expanded(
            child: isVertical
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sidebar,
                      contentArea,
                    ],
                  )
                : Row(
                    // Stretch, not the default centre. The content area is an
                    // Expanded Container whose child does not fill the height,
                    // so under a centred Row it sized to its child and floated
                    // in the middle of the window. That was invisible for as
                    // long as everything behind it was the same flat colour;
                    // the moment the chassis carried a fill ramp, the content
                    // area became a lighter rectangle with two hard edges
                    // across the middle of the app.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sidebar,
                      contentArea,
                    ],
                  ),
          ),
        ],
          ),
        ),
      ),
      ),
      ),
    );
  }

  Widget _buildHome() {
    return HomeView(
      channels: _channels,
      recentVods: _recentWatchedVods,
      runningDownloads: _activity.value.downloading,
      downloadedCount: _downloadedVodsRegistry.length,
      accountLogin: _authenticatedUserLogin,
      recentScroll: _recentScroll,
      fadeLeft: _recentFadeLeft,
      fadeRight: _recentFadeRight,
      onRecentScrolled: _updateRecentFades,
      onAddChannel: () => _sidebarSearchFocus.requestFocus(),
      onSelectChannel: _selectChannel,
      // Not _launchChannelStream, which compares the running set with the
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
      onPlayRecent: (video) => _playVod(video, _channelNameForVod(video.id)),
      onOpenLibrary: _openLibrary,
      onOpenSettings: _showSettingsDialog,
      onConnectAccount: _startOAuthServer,
    );
  }

  /// Opens the Library screen with a fresh scan of the download registry.
  void _openLibrary() {
    _checkDownloadedVods();
    _refreshLibraryEntries();
    setState(() {
      _showLibraryView = true;
    });
  }

  /// Leaves the Library for whatever was showing before it.
  ///
  /// _selectedChannel is deliberately left alone by _openLibrary, so simply
  /// lowering the flag lands back on that channel's dashboard - or the welcome
  /// screen if no channel was selected. The state to return to was always
  /// there; what was missing was any way to ask for it.
  void _closeLibrary() {
    if (!_showLibraryView) return;
    setState(() {
      _showLibraryView = false;
    });
  }

  /// Where [_closeLibrary] would land, for the back control's label.
  String get _libraryBackLabel => _selectedChannel?.username ?? 'Home';

  /// Rebuilds the cached Library rows (the only place file stats happen).
  void _refreshLibraryEntries() {
    final entries = buildLibraryEntries(
      registry: _downloadedVodsRegistry,
      recents: _recentWatchedVods,
      localProgress: _localVodsProgress,
      channelNames: _playerService.downloadChannelNames,
      downloadRoot: _settings.vodDownloadFolder,
      statFile: (path) {
        try {
          final file = File(path);
          if (!file.existsSync()) return null;
          final stat = file.statSync();
          return (size: stat.size, modified: stat.modified);
        } catch (_) {
          return null;
        }
      },
    );
    if (mounted) {
      setState(() {
        _libraryEntries = entries;
      });
    }
  }

  /// Channel a VOD belongs to, best-effort: the registry path's channel
  /// folder, then this session's download bookkeeping. The recents carousel
  /// previously hardcoded 'VOD', which made _playVod look for the local file
  /// under `<root>/VOD/` and re-stream VODs that were sitting on disk.
  String _channelNameForVod(String vodId) {
    final path = _downloadedVodsRegistry[vodId];
    if (path != null) {
      final parsed = channelFromDownloadPath(path, _settings.vodDownloadFolder);
      if (parsed != null && parsed.isNotEmpty) return parsed;
    }
    return _playerService.downloadChannelNames[vodId] ?? 'VOD';
  }

  /// Opens Explorer with [filePath] selected. Launched detached via
  /// explorer.exe so the shell window is not inside our kill-on-close job.
  Future<void> _revealInExplorer(String filePath) async {
    try {
      await Process.start(
        'explorer.exe',
        ['/select,${filePath.replaceAll('/', r'\')}'],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      _showSnackBar('Could not open folder: $e', isError: true);
    }
  }

  void _playLibraryEntry(LibraryEntry entry) {
    // Registry-only entries carry no Twitch metadata; a minimal synthesized
    // video is enough for _playVod's local-file path.
    final video = entry.video ??
        TwitchVideo(
          id: entry.vodId,
          title: entry.title,
          duration: '',
          thumbnailUrl: '',
          viewCount: '0',
          publishedAt: entry.modified ?? DateTime.now(),
        );
    // '' resolves to the download root itself, which is exactly where a file
    // with no channel folder lives - that is the only way channel is null for
    // a downloaded entry.
    _playVod(video, entry.channel ?? '');
  }

  Future<void> _deleteLibraryEntry(LibraryEntry entry) async {
    final bool? confirmed = await NeuDialog.show<bool>(
      context,
      // Dismissible: clicking away is the same as Cancel here, and the
      // destructive action requires a deliberate click either way.
      dismissible: true,
      builder: (context) => NeuDialog(
        title: 'Delete download?',
        icon: Icons.delete_outline,
        tone: DialogTone.destructive,
        content: Text(
          'Delete the downloaded file for "${entry.title}"? This cannot be undone.',
          style: NeuType.body(themeNotifier.isDarkTheme),
        ),
        actions: [
          NeuDialogAction.secondary('Cancel', () => Navigator.pop(context, false)),
          NeuDialogAction.primary('Delete', () => Navigator.pop(context, true)),
        ],
      ),
    );
    // != true, not == false: a dismissed dialog returns null, and null must
    // never mean "yes, delete it".
    if (confirmed != true) return;
    await _deleteDownloadedVod(entry.vodId, entry.channel ?? '');
    _refreshLibraryEntries();
  }

  Future<void> _removeLibraryEntryFromHistory(LibraryEntry entry) async {
    setState(() {
      _recentWatchedVods.removeWhere((v) => v.id == entry.vodId);
      _localVodsProgress.remove(entry.vodId);
      _progressStore.clear(entry.vodId);
    });
    // All three files, through the repository: the list was written here
    // straight through the storage service, round the gate that keeps it
    // from being written before it has been read.
    await _settingsRepo.saveNow(recents: true);
    if (!mounted) return;
    _refreshLibraryEntries();
  }

  Widget _buildLibraryView() {
    return LibraryView(
            onBack: _closeLibrary,
            backLabel: _libraryBackLabel,
            entries: _libraryEntries,
            onRefresh: () {
              _checkDownloadedVods();
              _refreshLibraryEntries();
            },
            onPlay: _playLibraryEntry,
            onOpenFolder: (entry) {
              if (entry.filePath != null) _revealInExplorer(entry.filePath!);
            },
            onDelete: _deleteLibraryEntry,
            onRemoveFromHistory: _removeLibraryEntryFromHistory,
      activity: _activity,
      onStopActivity: _stopActivity,
    );
  }

  Widget _buildDashboard(TwitchChannel channel) {
    final channelName = _selectedChannel?.username ?? 'VOD';
    return ChannelDashboard(
      channel: channel,
      settings: _settings,
      vodBrowser: _vodBrowser,
      pulseController: _pulseController!,
      isPlaying: _playerService.runningChannels.contains(channel.username),
      isMultiSelectMode: _isMultiSelectMode,
      selectedVodIds: _selectedVodIds,
      isBulkUpdating: _isBulkUpdatingVods,
      isWebTokenExpired: _isWebTokenExpired,
      selectedGamesFilter: _selectedGamesFilter,
      vodSearchController: _vodSearchController,
      displayMenu: VodDisplayMenu(
        settings: _settings,
        vods: _channelVods,
        selectedGamesFilter: _selectedGamesFilter,
        vodSearchController: _vodSearchController,
        update: setState,
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
      onEnterSelection: () => setState(() {
        _isMultiSelectMode = true;
        _selectedVodIds.clear();
      }),
      onExitSelection: () => setState(() {
        _isMultiSelectMode = false;
        _selectedVodIds.clear();
      }),
      onClearSelection: () => setState(() => _selectedVodIds.clear()),
      onSelectAllVisible: () => setState(() {
        _selectedVodIds.addAll(_filteredChannelVods().map((v) => v.id));
      }),
      onBulkMark: _bulkUpdateSelectedVods,
      onBulkDownload: _bulkDownloadSelectedVods,
      onBulkDelete: _bulkDeleteSelectedVods,
      onRefreshVods: () => _refreshSelectedVods(silent: false),
      onUpdateToken: _showSettingsDialog,
      onDismissWebTokenWarning: () => setState(() {
        _isWebTokenExpired = false;
      }),
      onGameFilterSelected: (game) {
        setState(() {
          if (_selectedGamesFilter.contains(game)) {
            _selectedGamesFilter.remove(game);
          } else {
            _selectedGamesFilter.add(game);
          }
        });
      },
      onClearGameFilter: () => setState(() => _selectedGamesFilter.clear()),
      onPlayVod: (vod) => _playVod(vod, channelName),
      onDownloadVod: (vod) => _queueVodDownload(vod, channelName),
      onDeleteDownload: (id) => _deleteDownloadedVod(id, channelName),
      onCancelDownload: (id) => _cancelVodDownload(id, channelName),
      onVodSelectedChange: (id, isSelected) {
        setState(() {
          if (isSelected) {
            _selectedVodIds.add(id);
          } else {
            _selectedVodIds.remove(id);
          }
        });
      },
      onOpenFolder: (vod) {
        final path = _downloadedVodsRegistry[vod.id];
        if (path != null) _revealInExplorer(path);
      },
      onLoadMore: () => _fetchVodsForChannel(channel, loadMore: true),
    );
  }

  void _playVod(TwitchVideo vod, String channelName) {
    // The service refuses a second launch silently, which is right for the
    // automation paths but reads as a broken button here: the card's corner
    // play control is not visibly disabled while a VOD is playing.
    if (_playerService.playingVodIds.contains(vod.id)) {
      _showSnackBar('Already playing "${vod.title}".', isError: false);
      return;
    }

    final localPos = _localVodsProgress[vod.id];
    if (localPos != null && (vod.watchPosition == null || localPos > vod.watchPosition!)) {
      vod.watchPosition = localPos;
    }
    // Recompute progress from position UNCONDITIONALLY, not only when the
    // local value raised it. A stale-high watchProgress riding on a correct
    // watchPosition survives the raise-merge, crosses the watched threshold,
    // and zeroes the resume - the "my progress mark vanished" half of the
    // pause-death bug. Position is the ground truth; the percentage is
    // derived, so derive it.
    final knownTotalSeconds = _apiService.parseDurationToSeconds(vod.duration);
    if (knownTotalSeconds > 0 && vod.watchPosition != null) {
      vod.watchProgress = vod.watchPosition! / knownTotalSeconds;
    }

    _activePlayingVideos[vod.id] = vod;
    File? file;
    final registeredPath = _downloadedVodsRegistry[vod.id];
    if (registeredPath != null) {
      file = File(registeredPath);
      if (!file.existsSync()) {
        file = null;
      }
    }
    
    file ??= _playerService.getDownloadedVodFile(
      vod.id,
      channelName,
      _settings.vodDownloadFolder,
    );

    
    // _activePlayingVideos is what _isWatchingVod reads, and only
    // onPlayerStopped clears it. If a launch fails before the service can
    // arrange that callback, auto-play and auto-download stand down for the
    // rest of the session - the exact failure already documented and fixed
    // once for the live path.
    final Future<void> launch = (file != null && file.existsSync())
        ? _playerService.playDownloadedVod(file, vod, _settings)
        : _playerService.launchStreamlinkForVod(vod, channelName, _settings);

    // If this VOD is opening behind the furthest point ever reached, say so and
    // offer the one action that fixes it. The furthest point is only a safety
    // net if the user can actually reach it; a value kept in a file that
    // nothing surfaces would be a backup in name only.
    _offerFurthestPosition(vod);

    launch.catchError((Object e) {
      _activePlayingVideos.remove(vod.id);
      if (mounted) {
        _showSnackBar('Could not start playback: ${describeTwitchError(e)}', isError: true);
      }
    });
  }

  void _queueVodDownload(TwitchVideo vod, String channelName) {
    _ensureDownloadFolderConfigured(() {
      _playerService.queueVodDownload(vod, channelName, _settings);
      setState(() {});
    });
  }

  Future<void> _cancelVodDownload(String vodId, String channelName) async {
    await _playerService.cancelVodDownload(vodId, channelName, _settings.vodDownloadFolder);
    if (mounted) setState(() {});
  }

  /// Deletes the files for [vodId], preferring the path recorded in the
  /// registry over re-deriving it from the currently selected channel.
  /// Returns how many files were actually removed.
  int _deleteVodFilesFor(String vodId, String channelName) {
    var deleted = 0;

    // The registry holds where the file really landed. Re-deriving
    // `<folder>/<selectedChannel>` orphaned files whenever the download
    // belonged to a different channel than the one currently selected.
    final registeredPath = _downloadedVodsRegistry[vodId];
    if (registeredPath != null) {
      try {
        final file = File(registeredPath);
        if (file.existsSync()) {
          file.deleteSync();
          deleted++;
        }
      } catch (_) {}
    }

    deleted += _playerService.deleteVodFiles(
      vodId,
      channelName,
      _settings.vodDownloadFolder,
    );
    return deleted;
  }

  Future<void> _deleteDownloadedVod(String vodId, String channelName) async {
    final deleted = _deleteVodFilesFor(vodId, channelName);

    _playerService.removeVodFromArchive(vodId);
    _downloadedVodsRegistry.remove(vodId);
    await _saveChannels();
    _checkDownloadedVods();

    // Report what actually happened rather than claiming success
    // unconditionally, which previously hid a failed delete while still
    // dropping the registry entry and orphaning the file.
    if (deleted > 0) {
      _showSnackBar('Deleted $deleted file(s) for VOD $vodId.', isError: false);
    } else {
      _showSnackBar('No downloaded files found for VOD $vodId.', isError: true);
    }
  }

  void _bulkDownloadSelectedVods() {
    if (_selectedVodIds.isEmpty) return;
    final selectedVods = _channelVods.where((v) => _selectedVodIds.contains(v.id)).toList();
    if (selectedVods.isEmpty) return;
    
    _ensureDownloadFolderConfigured(() {
      final channelName = _selectedChannel?.username ?? 'VOD';
      if (selectedVods.length == 1) {
        _playerService.queueVodDownload(selectedVods.first, channelName, _settings);
        setState(() {
          _isMultiSelectMode = false;
          _selectedVodIds.clear();
        });
      } else {
        _showDownloadOrderDialog(selectedVods);
        setState(() {
          _isMultiSelectMode = false;
          _selectedVodIds.clear();
        });
      }
    });
  }

  Future<void> _showDownloadOrderDialog(List<TwitchVideo> selectedVods) async {
    String? chosenOrder = await NeuDialog.show<String>(
      context,
      dismissible: true,
      builder: (context) {
        return NeuDialog(
          title: 'Download order',
          subtitle: '${selectedVods.length} VODs, one at a time',
          icon: Icons.download_for_offline,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Picking IS the action, so these rows carry it and the footer
              // only offers the way out. The old version buried the same two
              // choices in ListTiles under a paragraph asking you to choose.
              NeuChoiceTile(
                icon: Icons.arrow_downward,
                title: 'Newest first',
                subtitle: 'The latest broadcast starts downloading now',
                onTap: () => Navigator.pop(context, 'newest'),
              ),
              const SizedBox(height: NeuSpace.s8),
              NeuChoiceTile(
                icon: Icons.arrow_upward,
                title: 'Oldest first',
                subtitle: 'Work forwards from the oldest one selected',
                onTap: () => Navigator.pop(context, 'oldest'),
              ),
              // "Simultaneous Downloads" used to sit here. It called the same
              // queueVodDownload as the two branches above, which drains one
              // download at a time, and only differed in skipping the sort -
              // while announcing "Starting N parallel downloads...". Real
              // concurrency is a feature, not a relabelling.
            ],
          ),
          actions: [
            NeuDialogAction.secondary('Cancel', () => Navigator.pop(context)),
          ],
        );
      },
    );

    if (chosenOrder == null) return;

    final channelName = _selectedChannel?.username ?? 'VOD';

    final sortedVods = List<TwitchVideo>.from(selectedVods);
    if (chosenOrder == 'newest') {
      sortedVods.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    } else {
      sortedVods.sort((a, b) => a.publishedAt.compareTo(b.publishedAt));
    }
    _showSnackBar('Queueing ${sortedVods.length} downloads...', isError: false);
    for (final vod in sortedVods) {
      _playerService.queueVodDownload(vod, channelName, _settings);
    }
    setState(() {});
  }

  /// The VODs the grid is currently showing, i.e. what "All" selects.
  ///
  /// Was inline inside the Select All button; the SelectionBar needs it too,
  /// and two copies of a filter is how the old toolbar's two code paths
  /// drifted apart in the first place.
  List<TwitchVideo> _filteredChannelVods() {
    final searchQuery = _vodSearchController.text.trim().toLowerCase();
    return _channelVods.where((vod) {
      final matchesSearch = searchQuery.isEmpty ||
          vod.title.toLowerCase().contains(searchQuery) ||
          vod.games.any((game) => game.toLowerCase().contains(searchQuery));
      final matchesGameFilter = _selectedGamesFilter.isEmpty ||
          vod.games.any((game) => _selectedGamesFilter.contains(game));
      return matchesSearch && matchesGameFilter;
    }).toList();
  }

  Future<void> _bulkDeleteSelectedVods() async {
    final toDelete = <TwitchVideo>[];
    final channelName = _selectedChannel?.username ?? '';
    for (final id in _selectedVodIds) {
      // firstWhere without orElse threw a StateError whenever the selection
      // referenced a VOD no longer present in the list (after a refresh or a
      // channel switch).
      final matches = _channelVods.where((v) => v.id == id);
      if (matches.isEmpty) continue;

      final hasFile = _downloadedVodsRegistry.containsKey(id) ||
          _playerService.getDownloadedVodFile(id, channelName, _settings.vodDownloadFolder) != null;
      if (hasFile) {
        toDelete.add(matches.first);
      }
    }
    
    if (toDelete.isEmpty) {
      _showSnackBar('No fully downloaded VODs found among selection.', isError: true);
      return;
    }
    
    final confirm = await NeuDialog.show<bool>(
      context,
      dismissible: true,
      builder: (context) {
        final isDark = themeNotifier.isDarkTheme;
        return NeuDialog(
          title: 'Delete ${toDelete.length} downloaded '
              '${toDelete.length == 1 ? 'VOD' : 'VODs'}?',
          subtitle: 'The files on disk are removed. This cannot be undone.',
          icon: Icons.delete_outline,
          tone: DialogTone.destructive,
          scrollable: false,
          content: Container(
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.symmetric(vertical: NeuSpace.s8),
            decoration:
                NeuTheme.sunkenDecoration(isDark, radius: NeuRadius.r12),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: toDelete.length,
              itemBuilder: (context, index) => Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: NeuSpace.s12, vertical: NeuSpace.s4),
                child: Text(
                  toDelete[index].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeuType.bodySm(isDark),
                ),
              ),
            ),
          ),
          actions: [
            NeuDialogAction.secondary(
                'Keep them', () => Navigator.pop(context, false)),
            NeuDialogAction.primary(
                'Delete files', () => Navigator.pop(context, true)),
          ],
        );
      },
    );
    
    if (confirm != true) return;
    
    // Counts files actually deleted. This previously incremented once per
    // existing channel *directory*, so it reported a count even when nothing
    // was removed.
    int count = 0;
    for (final vod in toDelete) {
      try {
        count += _deleteVodFilesFor(vod.id, channelName);
        _playerService.removeVodFromArchive(vod.id);
        _downloadedVodsRegistry.remove(vod.id);
      } catch (_) {}
    }
    await _saveChannels();
    if (!mounted) return;

    _checkDownloadedVods();
    setState(() {
      _selectedVodIds.clear();
      _isMultiSelectMode = false;
    });
    _showSnackBar('Deleted $count downloaded VOD files.', isError: false);
  }
}
