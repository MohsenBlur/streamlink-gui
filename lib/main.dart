import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:file_picker/file_picker.dart';

import 'models/app_settings.dart';
import 'models/twitch_channel.dart';
import 'models/twitch_video.dart';
import 'services/crash_log.dart';
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
import 'state/download_registry.dart';
import 'theme/material/app_material.dart';
import 'theme/type_probe.dart';
import 'widgets/shell/edge_fade.dart';
import 'widgets/shell/app_chassis.dart';
import 'widgets/shell/engraved_rule.dart';
import 'widgets/neumorphic/neu_icon_action.dart';
import 'widgets/shell/app_layout.dart';
import 'widgets/shell/motion.dart';
import 'widgets/shell/section_header.dart';
import 'widgets/shell/selection_bar.dart';
import 'widgets/shell/empty_state.dart';
import 'widgets/neumorphic/neu_button.dart';
import 'widgets/shell/neu_dialog.dart';
import 'widgets/neumorphic/neu_progress.dart';
import 'widgets/neumorphic/neu_text_field.dart';
import 'state/channels_controller.dart';
import 'state/vod_browser_controller.dart';
import 'widgets/activity_pill.dart';
import 'widgets/log_viewer_dialog.dart';
import 'widgets/sidebar_panel.dart';
import 'widgets/dashboard_header.dart';
import 'widgets/vods_grid.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/hover_overlay_menu.dart';
import 'widgets/interactive_popover.dart';
import 'widgets/shell/route_handle.dart';

import 'services/startup_service.dart';
import 'state/library_entries.dart';
import 'utils/window_bounds.dart';
import 'widgets/library_view.dart';
import 'widgets/onboarding_wizard.dart';
import 'widgets/live_preview_popup.dart';
import 'widgets/horizontal_mouse_scrollable.dart';
import 'widgets/neumorphic/neu_checkbox.dart';
import 'widgets/neumorphic/neu_switch.dart';
import 'widgets/neumorphic/neu_title_bar.dart';
import 'state/automation_decisions.dart';
import 'theme/neu_material_themes.dart';
import 'theme/material/lit_surface.dart';
import 'theme/app_theme.dart';
import 'theme/neu_theme.dart';
import 'widgets/neumorphic/neu_avatar.dart';
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
  await LitSurfaceProgram.load(
      forceCanvas: args.contains('--canvas-engine') || settings.canvasEngine);
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

  // Seed the look from the settings already parsed above, BEFORE the first
  // frame.
  //
  // `NeuTheme.activeMaterial` defaults to rack and `themeNotifier.isDarkTheme`
  // to true, and both were only corrected later, inside `_loadChannels`'s
  // second config read. The window is shown from the first-frame callback
  // (`flutter_window.cpp`), so a user on Soft, or on the light theme, saw at
  // least one fully presented frame of the wrong look before it snapped -
  // a flash of a different material, not just a different colour.
  //
  // The later `setMaterial`/`setDarkTheme` calls then no-op, because both
  // setters early-return when the value is unchanged.
  final storedMaterial = AppMaterial.fromKey(settings.material);
  if (storedMaterial != null && MaterialSpec.isImplemented(storedMaterial)) {
    NeuTheme.activeMaterial = storedMaterial;
  }
  themeNotifier.isDarkTheme = settings.isDarkTheme;
  themeNotifier.lightAccentColor = parseHexColor(
      settings.lightAccentColorHex, NeuTheme.defaultLightAccent);
  themeNotifier.darkAccentColor =
      parseHexColor(settings.darkAccentColorHex, NeuTheme.defaultDarkAccent);

  runApp(TwitchStreamlinkApp(startup: startup, startHidden: startMinimized));
  milestone('runApp');

  unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
    milestone('first frame rasterized');
    return _checkWindowAfterFirstFrame(
        startHidden: startMinimized, milestone: milestone);
  }));
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
    if (state == null || startHidden) return;
    if (!state.visible || !state.contentVisible) {
      milestone('window or its content is not visible; showing it again');
      await NativeWindow.show();
      milestone('window after re-show: ${await NativeWindow.state()}');
    }
  } catch (e, st) {
    CrashLog.current?.error('window check', e, st);
  }
}

class TwitchStreamlinkApp extends StatefulWidget {
  const TwitchStreamlinkApp({super.key, this.startup, this.startHidden = false});

  /// The config as main() read it, for the first load.
  final StartupConfig? startup;

  /// The window starts hidden to the tray.
  final bool startHidden;

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
  });

  /// The config main() read at startup. Used by the first load only.
  final StartupConfig? startup;

  /// The window starts hidden to the tray, so it is not on screen.
  final bool startHidden;

  /// Where the shell's heartbeat is published for the whole app; see
  /// [_TwitchStreamlinkAppState._shellPulse].
  final ProxyAnimation? shellPulse;

  bool get isFirstRun => startup?.isFirstRun ?? false;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin, WindowListener {
  // Services
  final StorageService _storageService = StorageService();
  final TwitchApiService _apiService = TwitchApiService();
  final PlayerService _playerService = PlayerService();

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
  final SystemTray _systemTray = SystemTray();
  Set<String> get _previouslyLiveFavoriteUsernames => _channelsCtl.liveFavorites;
  
  Timer? _favoritesLiveCheckTimer;
  Timer? _downloadCheckTimer;
  HttpServer? _oauthServer;
  
  List<TwitchChannel> get _followedChannels => _channelsCtl.followed;
  bool get _isLoadingFollowed => _channelsCtl.isLoadingFollowed;
  String? _authenticatedUserLogin;
  String? _authenticatedUserAvatar;
  int _sidebarTab = 0; 
  
  // The open channel's VOD list lives in _vodBrowser (see the refresh block
  // by _selectChannel); these read it for the code that predates it.
  List<TwitchVideo> get _channelVods => _vodBrowser.vods;
  bool get _isLoadingVods => _vodBrowser.isLoading;
  String? get _vodsError => _vodBrowser.error;
  set _vodsError(String? value) => _vodBrowser.error = value;

  final TextEditingController _vodSearchController = TextEditingController();
  AnimationController? _pulseController;
  bool _sidebarCollapsed = false;
  String? get _vodPaginationCursor => _vodBrowser.cursor;
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
  void _watchSaveFailures() {
    storageWriteFailure.addListener(() {
      if (!mounted) return;
      if (storageWriteFailure.value == null && _saveWarningDismissed) {
        setState(() => _saveWarningDismissed = false);
      } else {
        setState(() {});
      }
    });
  }

  /// Library screen state. Entries are CACHED - built (with file stats) only
  /// on open/refresh/mutation, never inside build(), because download-progress
  /// setState storms would otherwise stat every file per frame.
  bool _showLibraryView = false;
  List<LibraryEntry> _libraryEntries = [];


  bool _isUpdatePromptOpen = false;
  bool _isUpdateInProgress = false;

  /// The runner's second-launch notification ("activate"); see initState.
  static const MethodChannel _singleInstanceChannel =
      MethodChannel('streamlink_gui/single_instance');

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
  final Map<String, String> _lastAutoPlayedStreamSession = {};

  @override
  void initState() {
    super.initState();
    _windowVisible = !widget.startHidden;
    windowManager.addListener(this);
    // A second launch hands over to this instance (windows/runner): the
    // runner has already shown or restored the window, re-shown its content
    // and taken the foreground by the time this arrives, so nothing here may
    // hide anything - it only brings Dart's bookkeeping up to date.
    _singleInstanceChannel.setMethodCallHandler((call) async {
      if (call.method == 'activate') {
        await _syncWindowVisible();
        try {
          await windowManager.focus();
        } catch (_) {}
      }
      return null;
    });
    _initSystemTray();

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
          _windowIsHidden().then((hidden) {
            if (hidden) _notify('Playback failed', label);
          });
        }
      }
    };

    _playerService.onWatchProgressUpdated =
        (vodId, position, progress, sessionAgeMs) {
      // One chokepoint, and it can say no. A relaunched player that came up at
      // the top of a five-hour VOD used to write its way over the stored
      // position within seconds - here and on Twitch, where max(local, remote)
      // cannot undo it.
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
        return;
      }
      if (mounted) {
        setState(() {
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
            
            _recentWatchedVods.removeWhere((v) => v.id == vodId);
            _recentWatchedVods.insert(0, video);
            
            if (_recentWatchedVods.length > _settings.maxRecentlyWatched) {
              _recentWatchedVods = _recentWatchedVods.take(_settings.maxRecentlyWatched).toList();
            }
          }
        });
        _saveChannels();
        if (_activePlayingVideos.containsKey(vodId)) {
          _storageService.saveRecentWatchedVods(
            _recentWatchedVods.map((v) => v.toJson()).toList()
          );
        }
      }
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

    _playerService.onDownloadCancelled = (vodId) {
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
        _saveChannels();
        if (_showLibraryView) _refreshLibraryEntries();
        _showSnackBar('Download completed: $title', isError: false);
        if (_settings.notifyDownloadComplete) {
          _notify('VOD Download Completed', title);
        }
      }
    };

    _playerService.onDownloadFailed = (vodId, title, exitCode) {
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

    _watchSaveFailures();
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
        StartupService().sync(true);
      }
      if (_settings.twitchOauthToken.trim().isNotEmpty) {
        _loadFollowedChannels();
      }
    }
  }

  Future<void> _checkForAppUpdates() async {
    try {
      final updateService = UpdateService();
      final updateInfo = await updateService.checkForUpdates();
      if (updateInfo != null && updateInfo.isUpdateAvailable && mounted) {
        _showUpdatePromptDialog(updateInfo);
      }
    } catch (_) {}
  }

  void _showUpdatePromptDialog(UpdateInfo info) {
    _isUpdatePromptOpen = true;
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
      _isUpdatePromptOpen = false;
    });
  }

  void _performAppUpdate(UpdateInfo info) {
    _isUpdateInProgress = true;
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

    Future.microtask(() async {
      final updateService = UpdateService();
      Directory? extractDir;
      var updaterStarting = false;
      try {
        final zipFile = await updateService.downloadUpdate(info.downloadUrl, (pct) {
          updateDialog(() => progress = pct);
        });

        updateDialog(() {
          statusText = 'Verifying download integrity...';
          progress = 0.0;
        });
        await updateService.verifyChecksum(zipFile, info.checksumUrl);

        updateDialog(() => statusText = 'Extracting update files...');
        extractDir = await updateService.extractAndVerifyZip(zipFile);

        updateDialog(() => statusText = 'Closing running downloads and streams...');

        // The restart ends this process from inside applyUpdateAndRestart,
        // so the window's last geometry is saved now or not at all.
        await _captureWindowState();

        // Shut down cleanly before the installation is replaced. This path
        // previously called exit(0) directly: streamlink/yt-dlp children were
        // orphaned and kept writing while the updater swapped the very
        // binaries they were running from, and any in-flight downloads were
        // lost with no resume record.
        await _persistUnfinishedDownloadsForRestart();
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
        await _stopAllBounded('update');

        updateDialog(() => statusText = 'Applying update and restarting...');
        updaterStarting = true;
        await updateService.applyUpdateAndRestart(extractDir);
      } catch (e) {
        _isUpdateInProgress = false;
        // stopAll() may already have killed everything before the failure. The
        // app survives this path, so any session still marked running would
        // stay that way for the rest of the session - and eviction only
        // reclaims finished ones.
        _logNotifier.endAllRunning(-1);
        // The extracted build is ~300 MB that only a sweep a day later would
        // reclaim. Safe to delete while no updater can be copying out of it,
        // which is every failure before applyUpdateAndRestart began; that
        // method cleans up its own failures before it starts the updater,
        // and after it, a late updater may still need the files.
        final extracted = extractDir;
        if (extracted != null && !updaterStarting) {
          unawaited(updateService.discardExtractedUpdate(extracted));
        }
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

  /// Snapshots active and queued downloads into settings so they resume after
  /// the app restarts. Shared by the tray-exit and update paths.
  Future<void> _persistUnfinishedDownloadsForRestart() async {
    final unfinished = <Map<String, dynamic>>[];
    final seen = <String>{};

    // Active downloads remain at the head of downloadQueue until they finish,
    // so de-duplicate: they used to be written into the resume list twice.
    final ids = <String>[
      ..._playerService.activeDownloadProcesses.keys,
      ..._playerService.downloadQueue,
    ];
    for (final vodId in ids) {
      if (!seen.add(vodId)) continue;
      final task = _playerService.queuedDownloadTasks[vodId];
      if (task == null) continue;
      unfinished.add({
        'vod': task.toJson(),
        // The channel the download actually belongs to, not whichever channel
        // happens to be selected in the UI right now.
        'channelName': _playerService.downloadChannelNames[vodId] ?? 'VOD',
      });
    }

    _settings.unfinishedDownloads = unfinished;
    await _saveChannels();
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
    windowManager.removeListener(this);
    _singleInstanceChannel.setMethodCallHandler(null);
    // Detached before the controller goes: the proxy outlives this screen.
    widget.shellPulse?.parent = kAlwaysCompleteAnimation;
    _recentScroll.dispose();
    _vodSearchController.dispose();
    _pulseController?.dispose();
    _playerService.stopAll();
    _searchController.dispose();
    _sidebarSearchFocus.dispose();
    _oauthServer?.close(force: true);
    _downloadCheckTimer?.cancel();
    _favoritesLiveCheckTimer?.cancel();
    _windowSaveTimer?.cancel();
    // Channel and VOD refresh wiring (see initState).
    _cameBackTimer?.cancel();
    _channelsCtl
      ..removeListener(_onRefreshStateChanged)
      ..dispose();
    _vodBrowser
      ..removeListener(_onRefreshStateChanged)
      ..dispose();
    twitchAuth.helix.removeListener(_onAuthStatusChanged);
    _activity.dispose();
    _logNotifier.dispose();
    super.dispose();
  }

  /// Signature of the last-built tray menu. system_tray 2.0.3 leaks the
  /// native HMENU on every setContextMenu, so the menu is only rebuilt when
  /// the live-favorites set actually changes - never per poll.
  String? _traySignature;

  Future<void> _initSystemTray() async {
    await _systemTray.initSystemTray(
      title: "Twitch Streamlink GUI",
      iconPath: 'assets/app_icon.ico',
      toolTip: "Twitch Streamlink GUI",
    );
    await _rebuildTrayMenu();

    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick || eventName == kSystemTrayEventDoubleClick) {
        _showWindow();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });
  }

  Future<void> _rebuildTrayMenu() async {
    final liveNames = _settings.trayLiveMenuEnabled
        ? _channels.where((c) => c.isLive).map((c) => c.username).take(5).toList()
        : <String>[];
    final signature = liveNames.join('|');
    if (signature == _traySignature) return;
    _traySignature = signature;

    try {
      final menu = Menu();
      await menu.buildFrom([
        for (final name in liveNames)
          MenuItemLabel(
            label: 'Watch $name',
            onClicked: (menuItem) => _launchTrayChannel(name),
          ),
        if (liveNames.isNotEmpty) MenuSeparator(),
        MenuItemLabel(label: 'Show App', onClicked: (menuItem) => _showWindow()),
        MenuItemLabel(label: 'Hide App', onClicked: (menuItem) => _hideWindow()),
        MenuItemLabel(
          label: 'Open Library',
          onClicked: (menuItem) async {
            await _showWindow();
            _openLibrary();
          },
        ),
        MenuSeparator(),
        MenuItemLabel(label: 'Exit', onClicked: (menuItem) => _handleAppExitRequest()),
      ]);
      await _systemTray.setContextMenu(menu);
      await _systemTray.setToolTip(
        liveNames.isEmpty
            ? 'Twitch Streamlink GUI'
            : 'Twitch Streamlink GUI - ${liveNames.length} favorite${liveNames.length == 1 ? '' : 's'} live',
      );
      await _systemTray.setImage(
        liveNames.isEmpty ? 'assets/app_icon.ico' : 'assets/app_icon_live.ico',
      );
    } catch (_) {
      // A failed tray refresh must never break polling; retry on next change.
      _traySignature = null;
    }
  }

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

  /// Set while an exit request is being answered (its dialogs are open), so a
  /// second Exit from the tray does not stack a second set on top.
  bool _exitRequestOpen = false;

  /// Set once the app has committed to quitting.
  bool _isExiting = false;

  Future<void> _handleAppExitRequest() async {
    if (_exitRequestOpen || _isExiting) return;
    _exitRequestOpen = true;
    try {
      await _showWindow();

      // The binaries are being replaced underneath the process and the
      // update restarts the app by itself; quitting now would leave neither
      // the old version running nor the new one installed. The update's own
      // failure path re-enables this.
      if (_isUpdateInProgress) {
        if (mounted) {
          _showSnackBar(
              'An update is being installed. The app restarts by itself '
              'when it is done.',
              isError: false);
        }
        return;
      }

      final hasUnfinished = _playerService.activeDownloadProcesses.isNotEmpty || _playerService.downloadQueue.isNotEmpty;
      if (hasUnfinished) {
        if (!mounted) return;
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
          return;
        }

        await _persistUnfinishedDownloadsForRestart();

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
          if (exitAnyway != true) return;
        }
      }
      // A dialog answered while an update started (from Settings, say) must
      // not quit underneath it either.
      if (_isUpdateInProgress) return;
    } finally {
      _exitRequestOpen = false;
    }

    await _shutDownAndExit();
  }

  /// Everything that has to happen before the process goes, then the exit.
  ///
  /// No Dart runs after windowManager.destroy(): the runner tears the engine
  /// down as soon as its message loop ends. Anything still pending then was
  /// lost - the debounced window save (a 300ms timer that never fired), a
  /// progress write still queued, the tray icon left behind until the mouse
  /// passed over it - and players were killed without being waited for.
  Future<void> _shutDownAndExit() async {
    if (_isExiting) return;
    _isExiting = true;
    final log = CrashLog.current;
    log?.milestone('[exit] requested');

    // Nothing new may start while this runs.
    _favoritesLiveCheckTimer?.cancel();
    _downloadCheckTimer?.cancel();

    // The window's last geometry, now rather than in 300ms.
    await _captureWindowState();

    // Players and downloads first, so whatever their stopping reports (a
    // final watch position, a download's resume state) is already in memory
    // when the saves below snapshot it.
    await _stopAllBounded('exit');

    // Each save resolves only once its file's writer has drained, earlier
    // fire-and-forget writes to the same file included.
    try {
      await _saveChannels();
      await _storageService.saveRecentWatchedVods(
          _recentWatchedVods.map((v) => v.toJson()).toList());
    } catch (e, st) {
      log?.error('exit: saving', e, st);
    }

    windowManager.removeListener(this);
    _singleInstanceChannel.setMethodCallHandler(null);
    try {
      await _systemTray.destroy();
    } catch (_) {}

    log?.milestone('[exit] saved and stopped; closing');
    await windowManager.destroy();
  }

  /// The longest quitting or updating waits for players and downloads to end.
  static const Duration _stopAllTimeout = Duration(seconds: 5);

  /// [PlayerService.stopAll], awaited but never for longer than
  /// [_stopAllTimeout].
  ///
  /// Awaited so the children are gone before the saves (exit) or the binary
  /// swap (update). Unbounded, a taskkill that never returned would strand
  /// the app: the exit guard ignores every later Exit, so the window could
  /// not be closed, and the update dialog has no way out at all. Going on is
  /// safe: the runner's kill-on-close job ends whatever is left when this
  /// process goes, and the updater ends what runs from the install folder
  /// before it swaps.
  Future<void> _stopAllBounded(String during) async {
    try {
      await _playerService.stopAll().timeout(_stopAllTimeout);
    } on TimeoutException {
      CrashLog.current?.milestone('[$during] players still stopping after '
          '${_stopAllTimeout.inSeconds}s; going on without them');
    } catch (e, st) {
      CrashLog.current?.error('$during: stopping players', e, st);
    }
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
    final shouldRun = somethingLive && _windowVisible && !reducedMotion;

    if (shouldRun && !controller.isAnimating) {
      controller.repeat(reverse: true);
    } else if (!shouldRun && controller.isAnimating) {
      controller.stop();
      // Settle at full value rather than wherever it happened to stop, so a
      // paused pulse does not leave a badge stuck at 40% opacity.
      controller.value = 1.0;
    }
  }

  /// Brings the window forward from wherever it is: the tray, minimized, or
  /// never shown yet because the app started hidden.
  ///
  /// Through the runner rather than windowManager.show(), because the
  /// runner knows how the window was restored: started hidden from a
  /// maximized session, its first appearance must be maximized, and a plain
  /// show brought it back at its normal size.
  Future<void> _showWindow() async {
    try {
      await NativeWindow.show();
    } catch (_) {
      await windowManager.show();
      await windowManager.focus();
    }
  }

  Future<void> _hideWindow() async {
    await windowManager.hide();
  }

  /// Whether the window is on screen, which gates the pulse.
  ///
  /// Written in one place only, [_syncWindowVisible], which reads it back
  /// from the window itself. It used to be set by hand on the few paths that
  /// remembered to (tray Show/Hide, minimize, restore), so closing to the
  /// tray, starting minimized, a toast's click or a second launch each left
  /// it wrong - a pulse running in the tray, or one frozen on screen.
  bool _windowVisible = true;

  /// Re-reads [_windowVisible] from the window. Every way of showing or
  /// hiding it ends in a window event ([onWindowEvent]) or, for a second
  /// launch, the runner's activate call, and both land here.
  Future<void> _syncWindowVisible() async {
    bool visible;
    try {
      visible = await windowManager.isVisible() &&
          !await windowManager.isMinimized();
    } catch (_) {
      return;
    }
    if (!mounted || visible == _windowVisible) return;
    _windowVisible = visible;
    _updatePulse();
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
        unawaited(_syncWindowVisible());
    }
    // Going to the tray is often the last thing a session does before
    // Windows shuts down around it, so the geometry is captured on the way.
    if (eventName == 'hide') _saveWindowState();
    // Coming back into view, what it shows is brought up to date.
    if (eventName == 'show' || eventName == kWindowEventRestore || eventName == kWindowEventFocus) _onWindowCameBack();
  }

  Timer? _windowSaveTimer;

  /// Debounced: a drag emits a stream of moves.
  void _saveWindowState() {
    _windowSaveTimer?.cancel();
    _windowSaveTimer = Timer(const Duration(milliseconds: 300), () async {
      _windowSaveTimer = null;
      if (await _captureWindowState()) {
        await _saveChannels();
      }
    });
  }

  /// Copies the window's current geometry into [_settings]; returns whether
  /// there was anything to copy.
  ///
  /// Physical pixels and the monitor, from the runner. The logical fields
  /// are kept up to date in the meaning older builds gave them (divided by
  /// the window's own scale), so a downgrade still finds the window.
  Future<bool> _captureWindowState() async {
    _windowSaveTimer?.cancel();
    _windowSaveTimer = null;
    try {
      final state = await NativeWindow.state();
      // Minimized, there is nothing new to say: the normal bounds are what
      // they were, and "maximized" is not readable until it is restored.
      if (state == null || state.minimized) return false;
      final s = state.scale;
      _settings.windowPlacement = SavedWindowPlacement.fromState(state);
      _settings.windowX = state.bounds.left / s;
      _settings.windowY = state.bounds.top / s;
      _settings.windowWidth = state.bounds.width / s;
      _settings.windowHeight = state.bounds.height / s;
      _settings.isWindowMaximized = state.maximized;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void onWindowResized() {
    _saveWindowState();
  }

  @override
  void onWindowMoved() {
    _saveWindowState();
  }

  @override
  void onWindowMaximize() {
    _saveWindowState();
  }

  @override
  void onWindowUnmaximize() {
    _saveWindowState();
  }

  @override
  void onWindowClose() async {
    final isPreventClose = await windowManager.isPreventClose();
    if (!isPreventClose) return;
    if (_settings.closeAction == 'exit') {
      await _handleAppExitRequest();
      return;
    }
    await _hideWindow();
    _maybeShowTrayNotice();
  }

  @override
  void onWindowMinimize() async {
    // Default is the Windows convention (taskbar); 'tray' preserves the old
    // behavior for users who want it.
    if (_settings.minimizeAction == 'tray') {
      await _hideWindow();
    }
  }

  /// One-time heads-up that closing the window left the app running.
  Future<void> _maybeShowTrayNotice() async {
    if (_settings.trayNoticeShown) return;
    _settings.trayNoticeShown = true;
    await _saveChannels();
    try {
      final notification = LocalNotification(
        title: 'Still running in the tray',
        body:
            'Twitch Streamlink GUI keeps monitoring your favorites. Right-click the tray icon and choose Exit to quit for real. You can change the close behavior in Settings.',
        silent: true,
      );
      await notification.show();
    } catch (_) {}
  }

  void _checkDownloadedVods() {
    final downloadRoot = _settings.vodDownloadFolder.trim();
    if (downloadRoot.isEmpty) {
      if (mounted) {
        setState(() {
          _downloadedVodIds.clear();
        });
      }
      return;
    }

    // If the download location is not reachable right now - an external or
    // network drive that is disconnected - every existsSync() below would
    // return false and this would prune the entire downloaded-VOD registry and
    // strip the matching yt-dlp archive entries, permanently forgetting
    // downloads that are merely offline. Leave all state untouched instead.
    try {
      if (!Directory(downloadRoot).existsSync()) return;
    } catch (_) {
      return;
    }

    final inFlight = <String>{
      ..._playerService.activeDownloadTasks.keys,
      ..._playerService.activeDownloadProcesses.keys,
      ..._playerService.downloadQueue,
    };

    // Resolve where each of the current channel's VODs would live, so files
    // that arrived without going through this app get picked up.
    final candidates = <String, String>{};
    for (final vod in _channelVods) {
      try {
        final file = _playerService.getDownloadedVodFile(
            vod.id, _selectedChannel?.username ?? '', _settings.vodDownloadFolder);
        if (file != null) candidates[vod.id] = file.path;
      } catch (_) {}
    }

    final plan = planRegistryScan(
      registry: Map<String, String>.from(_downloadedVodsRegistry),
      inFlightIds: inFlight,
      candidates: candidates,
      fileExists: _pathIsFile,
      directoryExists: _pathIsDirectory,
    );

    for (final vodId in plan.stripFromArchive) {
      _playerService.removeVodFromArchive(vodId);
    }
    _downloadedVodsRegistry.removeWhere((vodId, _) => plan.prune.contains(vodId));
    _downloadedVodsRegistry.addAll(plan.additions);

    if (plan.registryChanged) {
      _saveChannels();
    }

    if (mounted) {
      setState(() {
        // Unverified entries stay badged: their location is merely unreachable
        // right now, and flickering the badge off for an unplugged drive is a
        // worse lie than leaving it on.
        _downloadedVodIds = {...plan.present, ...plan.unverified};
      });
    }
  }

  static bool _pathIsFile(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static bool _pathIsDirectory(String path) {
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureDownloadFolderConfigured(VoidCallback onConfigured) async {
    if (_settings.vodDownloadFolder.trim().isNotEmpty) {
      onConfigured();
      return;
    }

    final bool? proceed = await NeuDialog.show<bool>(
      context,
      dismissible: true,
      builder: (context) => NeuDialog(
        title: 'Where should VODs be saved?',
        icon: Icons.folder_copy,
        content: Text(
          'No download folder is set yet. Pick one and the download starts '
          'straight away; everything you download later goes there too.',
          style: NeuType.body(themeNotifier.isDarkTheme),
        ),
        actions: [
          NeuDialogAction.secondary('Cancel', () => Navigator.pop(context, false)),
          NeuDialogAction.primary('Choose folder', () async {
            final String? path = await FilePicker.platform.getDirectoryPath();
            if (path != null && path.isNotEmpty) {
              setState(() {
                _settings.vodDownloadFolder = path;
              });
              await _saveChannels();
              _checkDownloadedVods();
              if (context.mounted) {
                Navigator.pop(context, true);
              }
            }
          }),
        ],
      ),
    );

    if (proceed == true && _settings.vodDownloadFolder.trim().isNotEmpty) {
      onConfigured();
    } else {
      _showSnackBar('Download cancelled: VOD Download Folder is required.', isError: true);
    }
  }

  void _resumeUnfinishedDownloads() {
    if (_settings.unfinishedDownloads.isEmpty) return;
    
    final list = List<dynamic>.from(_settings.unfinishedDownloads);
    
    setState(() {
      _settings.unfinishedDownloads = const [];
    });
    _saveChannels();
    
    int resumedCount = 0;
    for (final item in list) {
      try {
        if (item is Map<String, dynamic>) {
          final vod = TwitchVideo.fromJson(item['vod']);
          final channelName = item['channelName'] as String;
          _playerService.queueVodDownload(vod, channelName, _settings);
          resumedCount++;
        }
      } catch (_) {}
    }
    
    if (resumedCount > 0) {
      _showSnackBar('Resumed $resumedCount unfinished downloads.', isError: false);
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
             
            if (_settings.unfinishedDownloads.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _resumeUnfinishedDownloads();
              });
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

      await _refreshAllChannels(isInitialLoad: true);
      // Ask Twitch whether the token works BEFORE using it. The old gate was
      // `isNotEmpty`, which is a test of the string and not of the account, so
      // a revoked token spent every launch failing a real request and pasting
      // the raw 401 body into a snackbar.
      await _refreshHelixAuth();
      if (twitchAuth.helix.value.isUsable) {
        _loadFollowedChannels();
      }
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
    } catch (e) {
      _showSnackBar('Error loading saved channels: ${describeTwitchError(e)}', isError: true);
    } finally {
      // Arms the recovery refresh. Startup already fetches everything, so
      // arming earlier would make the first successful probe refresh it all a
      // second time.
      _startupComplete = true;
      setState(() => _isGlobalLoading = false);
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

  Future<void> _saveChannels() async {
    await _storageService.saveConfig(_channels, _settings, _localVodsProgress, _downloadedVodsRegistry);
    // The rich record goes to its own file; the config keeps the flat copy for
    // compatibility. A config rewrite can no longer take the history with it.
    await _storageService.saveWatchProgress(_progressStore.toJson());
  }

  Future<void> _startOAuthServer() async {
    if (_oauthServer != null) {
      try {
        await _oauthServer!.close(force: true);
      } catch (_) {}
    }

    final port = _settings.localServerPort;
    try {
      _oauthServer = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _showSnackBar('OAuth server started on port $port. Opening browser...', isError: false);

      final clientId = _settings.twitchClientId.trim().isNotEmpty
          ? _settings.twitchClientId.trim()
          : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

      final authUrl = 'https://id.twitch.tv/oauth2/authorize'
          '?client_id=$clientId'
          '&redirect_uri=http://localhost:$port'
          '&response_type=token'
          '&scope=user:read:follows';

      await _openExternalLink(authUrl);

      _oauthServer!.listen((HttpRequest request) async {
        final response = request.response;
        response.headers.contentType = ContentType.html;

        if (request.uri.path == '/') {
          response.write('''
<!DOCTYPE html>
<html>
<head>
  <title>Twitch Streamlink GUI Login</title>
  <style>
    body {
      background-color: #0c0f17;
      color: #ffffff;
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100vh;
      margin: 0;
    }
    .card {
      background-color: #161b26;
      border: 1px solid #1e2433;
      border-radius: 12px;
      padding: 30px;
      box-shadow: 0 8px 30px rgba(0,0,0,0.3);
      text-align: center;
      max-width: 400px;
    }
    h2 { color: #9146ff; margin-top: 0; }
    .spinner {
      border: 4px solid rgba(255,255,255,0.1);
      width: 36px;
      height: 36px;
      border-radius: 50%;
      border-left-color: #9146ff;
      animation: spin 1s linear infinite;
      margin: 20px auto;
    }
    @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
  </style>
</head>
<body>
  <div class="card">
    <h2>Twitch Authorization</h2>
    <div id="status">Connecting with Streamlink Twitch GUI...</div>
    <div id="loader" class="spinner"></div>
  </div>
  <script>
    const hash = window.location.hash.substring(1);
    const params = new URLSearchParams(hash);
    const token = params.get('access_token');
    if (token) {
      fetch('/token?access_token=' + token)
        .then(() => {
          document.getElementById('status').innerText = 'Authentication successful! You can close this tab now.';
          document.getElementById('loader').style.display = 'none';
        })
        .catch(err => {
          document.getElementById('status').innerText = 'Error saving token to application.';
          document.getElementById('loader').style.display = 'none';
        });
    } else {
      document.getElementById('status').innerText = 'No access token found in URL fragment.';
      document.getElementById('loader').style.display = 'none';
    }
  </script>
</body>
</html>
          ''');
          await response.close();
        } else if (request.uri.path == '/token') {
          final token = request.uri.queryParameters['access_token'];
          if (token != null && token.isNotEmpty) {
            setState(() {
              _settings.twitchOauthToken = 'oauth:$token';
              // Record WHICH client minted it. Without this, editing the
              // Client ID field later produces a 401 the app would have to
              // guess at, and it would guess "expired" - sending the user
              // through a reconnect that cannot fix a mismatch.
              _settings.twitchTokenClientId = _settings.twitchClientId.trim();
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
          response.write('OK');
          await response.close();

          await _oauthServer!.close(force: true);
          _oauthServer = null;
        } else {
          response.statusCode = HttpStatus.notFound;
          response.write('Not found');
          await response.close();
        }
      });
    } catch (e) {
      _showSnackBar('Failed to start local login server: ${describeTwitchError(e)}', isError: true);
    }
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
    final configured = _settings.twitchClientId.trim();
    if (minted.isNotEmpty && configured.isNotEmpty && minted != configured) {
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
  );

  late final VodBrowserController _vodBrowser = VodBrowserController(
    api: _apiService,
    settings: () => _settings,
    localProgress: () => _localVodsProgress,
  );

  /// Debounces the window's show, restore and focus events.
  Timer? _cameBackTimer;

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
    // The open channel's VODs, every few minutes while they can be seen.
    if (_windowVisible) {
      unawaited(_refreshSelectedVods(
          maxAge: VodBrowserController.visibleRefreshInterval));
    }
  }

  /// The window came back into view: shown from the tray, restored, or
  /// focused. What it shows is fetched again if it is old - the channels
  /// when the last pass is over 30s old, the open VOD list when it is over a
  /// minute old. Nothing did this, so a grid left in the tray overnight came
  /// back showing last night. Debounced: one restore fires several of these,
  /// and alt-tabbing fires them constantly.
  void _onWindowCameBack() {
    _cameBackTimer?.cancel();
    _cameBackTimer = Timer(const Duration(milliseconds: 300), () {
      _cameBackTimer = null;
      if (!mounted || !_startupComplete) return;
      unawaited(_channelsCtl.refreshIfOlderThan(const Duration(seconds: 30)));
      if (twitchAuth.helix.value.isUsable) {
        unawaited(
            _refreshSelectedVods(maxAge: VodBrowserController.staleAfter));
      }
    });
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
    _rebuildTrayMenu();
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
        final notification = LocalNotification(
          title: '${channel.username} is now LIVE!',
          body: 'Playing $gameText\n$titleText',
          silent: false,
        );
        notification.onClick = () async {
          await _showWindow();
          if (!mounted) return;
          _selectChannel(channel);

          _playerService.launchStreamlinkForLive(
            channel.username,
            channel.isLive,
            channel.streamTitle,
            channel.game,
            _settings,
          );
        };
        await notification.show();
      } catch (e) {
        print('[Favorites Notification] Error displaying desktop toast: $e');
      }
    }
  }

  /// A channel's archive gained a VOD (see VodBrowserController.onNewVods).
  /// Announced for favourites only, and not for the open channel while the
  /// window is on screen: the grid shows it arriving.
  void _onNewVods(TwitchChannel channel, List<TwitchVideo> vods) {
    if (!mounted || !_settings.notifyNewVod || vods.isEmpty) return;
    final name = channel.username.toLowerCase().trim();
    if (!_channels.any((c) => c.username == name)) return;
    if (_windowVisible &&
        !_showLibraryView &&
        _selectedChannel?.username == name) {
      return;
    }
    unawaited(_announceNewVods(name, vods));
  }

  Future<void> _announceNewVods(String name, List<TwitchVideo> vods) async {
    try {
      final more = vods.length - 1;
      final notification = LocalNotification(
        title: 'New VOD from $name',
        body: more > 0 ? '${vods.first.title}\n+$more more' : vods.first.title,
        silent: false,
      );
      notification.onClick = () async {
        await _showWindow();
        if (!mounted) return;
        final index = _channels.indexWhere((c) => c.username == name);
        if (index != -1) _selectChannel(_channels[index]);
      };
      await notification.show();
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
    await _saveChannels();
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

  bool _automationPassRunning = false;

  Future<void> _checkFavoritesAutomation() async {
    // Re-entrancy guard: the 60s timer can fire again while a pass is still
    // awaiting VOD lists, which produced overlapping passes that each queued
    // the same downloads.
    if (_automationPassRunning) return;
    _automationPassRunning = true;
    try {
      await _runAutoPlayPass();
      await _runAutoDownloadPass();
    } finally {
      _automationPassRunning = false;
    }
  }

  Future<void> _runAutoPlayPass() async {
    // Forget sessions for channels that are no longer live, so the next
    // broadcast is treated as new.
    final liveNames =
        _channels.where((c) => c.isLive).map((c) => c.username.toLowerCase().trim()).toSet();
    _lastAutoPlayedStreamSession.removeWhere((name, _) => !liveNames.contains(name));

    final decision = decideAutoPlay(
      channels: _channels,
      runningChannels: _playerService.runningChannels
          .map((c) => c.toLowerCase().trim())
          .toSet(),
      playedSessions: _lastAutoPlayedStreamSession,
      isWatchingVod: _isWatchingVod,
      isUpdateActive: _isUpdatePromptOpen || _isUpdateInProgress,
      preemptLowerPriority: _settings.autoPlayPreemptLowerPriority,
    );

    if (decision.sessionChannel != null && decision.sessionKeyToRecord != null) {
      _lastAutoPlayedStreamSession[decision.sessionChannel!] = decision.sessionKeyToRecord!;
    }

    // Applied before the early return: the highest-priority stream may already
    // be running, and lower-priority ones still need stopping in that case.
    for (final lower in decision.channelsToPreempt) {
      print('[Auto-Play] Preempting lower priority stream @$lower');
      _playerService.killLiveStream(lower);
    }

    if (!decision.shouldLaunch) {
      if (decision.reason != AutoPlaySkipReason.none) {
        print('[Auto-Play] No action: ${decision.reason.name}');
      }
      return;
    }

    final target = decision.channelToPlay!;
    final cleanName = target.username.toLowerCase().trim();

    _lastAutoPlayedStreamSession[cleanName] = decision.sessionKey!;
    print('[Auto-Play] Launching @${target.username} (session ${decision.sessionKey})');

    _playerService.launchStreamlinkForLive(
      target.username,
      target.isLive,
      target.streamTitle,
      target.game,
      _settings,
    );

    if (_settings.notifyAutoPlay) {
      try {
        await LocalNotification(
          title: 'Auto-Playing Live Stream',
          body: '${target.username} is now live\nPlaying ${target.game ?? "Twitch"}',
          silent: false,
        ).show();
      } catch (e) {
        print('[Auto-Play Notification Error]: $e');
      }
    }
  }

  Future<void> _runAutoDownloadPass() async {
    final channels = _channels.where((c) => c.autoDownloadVods).toList();
    if (channels.isEmpty) return;

    // Auto-download writes to disk, so a configured folder is required. This
    // used to be skipped entirely, and startVodDownload then threw on every
    // single queued item.
    if (_settings.vodDownloadFolder.trim().isEmpty) {
      print('[Auto-Download] Skipped: no VOD download folder configured.');
      return;
    }

    for (final channel in channels) {
      try {
        final fetchedAt = DateTime.now();
        final result = await _apiService.fetchVodsForChannel(
          channel: channel,
          settings: _settings,
          localVodsProgress: _localVodsProgress,
          // This pass renders nothing, so the per-VOD game lookup is pure
          // overhead. It runs for every auto-download channel every minute.
          fetchGames: false,
        );
        // What this pass already paid for reaches the cache and, for the open
        // channel, the grid. It used to be thrown away every minute.
        if (_vodBrowser.ingest(channel, result,
            fetchedAt: fetchedAt, detailed: false)) {
          _checkDownloadedVods();
        }
        if (result.vods.isEmpty) continue;

        final selected = selectVodsToAutoDownload(
          channel: channel,
          vods: result.vods,
          localProgress: _localVodsProgress,
          settings: _settings,
          isAlreadyHandled: (vodId) =>
              _downloadedVodsRegistry.containsKey(vodId) ||
              _playerService.activeDownloadTasks.containsKey(vodId) ||
              _playerService.activeDownloadProcesses.containsKey(vodId) ||
              _playerService.downloadQueue.contains(vodId),
        );

        for (final vod in selected) {
          print('[Auto-Download] Queueing ${vod.id} for @${channel.username}');
          _playerService.queueVodDownload(
            vod,
            channel.username,
            _settings,
            // Tri-state: only override when the channel opts in. Passing false
            // unconditionally made the per-channel default beat the global
            // "Fast VOD Downloads" setting, so every automatic download ran the
            // slow post-processing path the Downloads tab promised to skip.
            overrideDisablePostProcessing: channel.autoDownloadFastDownload ? true : null,
          );

          if (_settings.notifyAutoDownloadStart) {
            try {
              await LocalNotification(
                title: 'Auto-Downloading VOD',
                body: 'Started auto-downloading VOD for @${channel.username}:\n${vod.title}',
                silent: false,
              ).show();
            } catch (e) {
              print('[Auto-Download Notification Error]: $e');
            }
          }
        }
      } catch (e) {
        print('[Auto-Download Error] Failed for @${channel.username}: $e');
      }
    }
  }

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
        _lastAutoPlayedStreamSession.remove(cleanName);
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

  /// Whether the window is somewhere the user can actually read a SnackBar.
  ///
  /// The app's normal state is minimised to the tray, where an in-app message
  /// is shown to nobody - and auto-play and auto-download run precisely then.
  Future<bool> _windowIsHidden() async {
    try {
      if (!await windowManager.isVisible()) return true;
      return await windowManager.isMinimized();
    } catch (_) {
      // Unknown: prefer the OS notification over silence.
      return true;
    }
  }

  /// Raises an OS notification, ignoring a platform that refuses.
  Future<void> _notify(String title, String body, {bool silent = false}) async {
    try {
      await LocalNotification(title: title, body: body, silent: silent).show();
    } catch (_) {}
  }

  void _showSnackBar(String message,
      {required bool isError, SnackBarAction? action}) {
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
          StartupService().sync(_settings.launchAtStartup);
        }
        // The tray menu preference may have flipped; the signature gate makes
        // this a no-op otherwise.
        _traySignature = null;
        _rebuildTrayMenu();

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
      if (info != null && mounted && !_isUpdatePromptOpen && !_isUpdateInProgress) {
        _showUpdatePromptDialog(info);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        _saveChannels();
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
                ? _buildWelcomeScreen(theme)
                : _buildDashboard(theme, _selectedChannel!),
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
              return _buildSaveFailureBanner(failure);
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
              return _buildTwitchAuthBanner(status);
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

  Widget _buildWelcomeScreen(ThemeData theme) {
    final liveFavorites = _channels.where((c) => c.isLive).toList();
    final runningDownloads = _activity.value.downloading;

    return SingleChildScrollView(
            padding: const EdgeInsets.all(NeuSpace.s32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title Header
                Row(
                  children: [
                    Icon(Icons.home_outlined, size: 26, color: themeNotifier.accentInk),
                    const SizedBox(width: NeuSpace.s12),
                    Text(
                      'Home',
                      style: NeuType.display(themeNotifier.isDarkTheme),
                    ),
                  ],
                ),
                const SizedBox(height: NeuSpace.s6),
                Text(
                  'Pick a channel from the sidebar, or jump back into something below.',
                  style: NeuType.body(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                ),
                const SizedBox(height: NeuSpace.s24),

          // Order matters here. This screen used to lead with the
          // downloader and put live channels third, which is the priority
          // order of a download manager rather than of a Twitch client.
          // What is live is the most perishable thing on the page, so it
          // goes first; downloads are long-running and can wait.
          // Live Channels Section
          SectionHeader(
            title: 'Live now',
            count: liveFavorites.isEmpty ? null : liveFavorites.length,
          ),
          const SizedBox(height: NeuSpace.s12),
          if (liveFavorites.isEmpty)
            Container(
              width: double.infinity,
              decoration: NeuTheme.sunkenDecoration(
                  themeNotifier.isDarkTheme,
                  radius: NeuRadius.r12),
              child: _channels.isEmpty
                  // Two different situations that shared one sentence. With no
                  // channels at all the answer is an action, not information.
                  ? EmptyState(
                      icon: Icons.person_add_alt,
                      title: 'No channels yet',
                      message: 'Add a streamer to see when they go live and to '
                          'browse their past broadcasts.',
                      compact: true,
                      action: NeuButton(
                        onPressed: () =>
                            _sidebarSearchFocus.requestFocus(),
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                        borderRadius: BorderRadius.circular(NeuRadius.r8),
                        child: const Text('Add a channel',
                            style: NeuType.bodySmMetrics),
                      ),
                    )
                  : EmptyState(
                      icon: Icons.bedtime_outlined,
                      title: 'Nobody is live',
                      message: 'None of your favorite channels are streaming '
                          'right now.',
                      compact: true,
                    ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              // A shrink-wrapped, never-scrolling grid's clip does no work -
              // except amputating the boundary tiles' cast shadows exactly at
              // the grid's edge. Clip.none lets them land in the page's own
              // scroll padding, which is sitting right there.
              clipBehavior: Clip.none,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                mainAxisExtent: 130,
              ),
              itemCount: liveFavorites.length,
              itemBuilder: (context, index) {
                final channel = liveFavorites[index];
                final itemCard = GestureDetector(
                  onTap: () => _selectChannel(channel),
                  onDoubleTap: () {
                    if (_playerService.runningChannels.contains(channel.username)) return;
                    _playerService.launchStreamlinkForLive(
                      channel.username,
                      channel.isLive,
                      channel.streamTitle,
                      channel.game,
                      _settings,
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(NeuSpace.s12),
                    decoration: NeuTheme.raisedDecoration(
                      themeNotifier.isDarkTheme,
                      radius: NeuRadius.r12,
                      border: Border.all(color: theme.primaryColor.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            NeuAvatar(
                              url: channel.avatarUrl,
                              radius: 18,
                              isDark: themeNotifier.isDarkTheme,
                              // This one sits on a coloured card, so it keeps
                              // its transparent ground and brighter icon.
                              backgroundColor: Colors.transparent,
                              iconColor: NeuTheme.text(themeNotifier.isDarkTheme),
                            ),
                            const SizedBox(width: NeuSpace.s8),
                            Expanded(
                              child: Text(
                                channel.username,
                                style: NeuType.headingSm(themeNotifier.isDarkTheme),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: NeuSpace.s8),
                        Expanded(
                          child: Text(
                            channel.streamTitle ?? 'No Stream Title',
                            style: NeuType.caption(themeNotifier.isDarkTheme),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: NeuSpace.s4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Expanded, not a bare Text. `overflow: ellipsis`
                            // can only engage when the Text is given a bounded
                            // width; in an unconstrained Row it reports its
                            // full intrinsic width instead and the ROW
                            // overflows. These tiles are maxCrossAxisExtent
                            // 220 and the window minimum is 380 wide, so a
                            // long game name overflowed in the normal case,
                            // not an exotic one.
                            Expanded(
                              child: Text(
                                channel.game ?? 'Unknown Game',
                                style: NeuType.plate(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: NeuSpace.s8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.remove_red_eye, size: 10, color: NeuTheme.liveText(themeNotifier.isDarkTheme)),
                                const SizedBox(width: NeuSpace.s4),
                                Text(
                                  channel.viewerCount != null ? '${channel.viewerCount}' : '0',
                                  style: NeuType.caption(themeNotifier.isDarkTheme),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );

                return HoverOverlayMenu(
                  trigger: itemCard,
                  menu: LivePreviewPopup(channel: channel),
                );
              },
            ),
          const SizedBox(height: NeuSpace.s32),

          // Recently Watched VODs (Conditional)
          if (_recentWatchedVods.isNotEmpty) ...[
            SectionHeader(title: 'Continue watching'),
            const SizedBox(height: NeuSpace.s12),
            SizedBox(
              height: 135 + NeuShadowRoom.above + NeuShadowRoom.below,
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) {
                  _updateRecentFades();
                  return false;
                },
                child: EdgeFade(
                  left: _recentFadeLeft,
                  right: _recentFadeRight,
                  child: HorizontalMouseScrollable(
                controller: _recentScroll,
                // Shadow clearance comes from the scroller itself now -
                // NeuShadowRoom.strip, one definition for every strip.
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(_recentWatchedVods.length, (index) {
                    final video = _recentWatchedVods[index];
                    final w = 240;
                    final h = 135;
                    final thumbUrl = video.thumbnailUrl.isNotEmpty
                        ? video.thumbnailUrl.replaceAll('%{width}', w.toString()).replaceAll('%{height}', h.toString())
                        : null;

                    bool isHovered = false;

                    final progressPct = ((video.watchProgress ?? 0.0) * 100).toInt();

                    return StatefulBuilder(
                      builder: (context, setHoverState) {
                        return MouseRegion(
                          onEnter: (_) => setHoverState(() => isHovered = true),
                          onExit: (_) => setHoverState(() => isHovered = false),
                          cursor: SystemMouseCursors.click,
                          child: Tooltip(
                            message: '${video.title}\nResume at $progressPct% (${video.duration})',
                            child: GestureDetector(
                              onTap: () => _playVod(video, _channelNameForVod(video.id)),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                child: Container(
                                  width: w.toDouble(),
                                  height: h.toDouble(),
                                  margin: const EdgeInsets.only(right: NeuSpace.s12),
                                  // A caller border REPLACES the material's
                                  // edge, so a transparent width-0 border at
                                  // rest deleted the bevel and zeroed the
                                  // decoration padding - and the hover flip
                                  // to 1.5px shifted the card's contents.
                                  decoration: NeuTheme.raisedDecoration(
                                    themeNotifier.isDarkTheme,
                                    radius: NeuRadius.r12,
                                    border: isHovered
                                        ? Border.all(
                                            color: theme.primaryColor,
                                            width: 1.5)
                                        : null,
                                  ),
                                  child: ClipRRect(
                                    // Concentric: inner = outer - inset, and
                                    // the inset is the material's 1px edge.
                                    borderRadius: BorderRadius.circular(NeuRadius.inner(NeuRadius.r12, 1)),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Stack(
                                            children: [
                                              Positioned.fill(
                                                child: thumbUrl != null
                                                    ? Image.network(
                                                        thumbUrl,
                                                        fit: BoxFit.cover,
                                                        // A missing-artwork
                                                        // slot is a recessed
                                                        // screen; the raised
                                                        // token put the
                                                        // lightest ground
                                                        // where the darkest
                                                        // belongs. Matches
                                                        // the Library's
                                                        // fallback.
                                                        errorBuilder: (context, error, stackTrace) => Container(
                                                          color: NeuTheme.wellSurface(themeNotifier.isDarkTheme),
                                                          child: Icon(Icons.movie, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 36),
                                                        ),
                                                      )
                                                    : Container(
                                                        color: NeuTheme.wellSurface(themeNotifier.isDarkTheme),
                                                        child: Icon(Icons.movie, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 36),
                                                      ),
                                              ),
                                              if (isHovered)
                                                Positioned.fill(
                                                  child: Container(
                                                    // Intentional: scrim over video artwork, theme-independent.
                                                    color: Colors.black45,
                                                    child: Center(
                                                      child: Container(
                                                        padding: const EdgeInsets.all(NeuSpace.s8),
                                                        decoration: BoxDecoration(
                                                          color: theme.primaryColor,
                                                          shape: BoxShape.circle,
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: theme.primaryColor.withValues(alpha: 0.5),
                                                              blurRadius: 10,
                                                            )
                                                          ],
                                                        ),
                                                        child: Icon(Icons.play_arrow, color: themeNotifier.onPrimaryColor, size: 24),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              Positioned(
                                                bottom: 4,
                                                right: 6,
                                                // Intentional: white-on-black pill over video artwork, theme-independent.
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s4, vertical: NeuSpace.s2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.75),
                                                    borderRadius: BorderRadius.circular(NeuRadius.r4),
                                                  ),
                                                  child: Text(
                                                    video.duration,
                                                    style: NeuType.plate(themeNotifier.isDarkTheme, color: Colors.white),
                                                  ),
                                                ),
                                              ),
                                              if (video.watchProgress != null && video.watchProgress! > 0.0)
                                                Positioned(
                                                  bottom: 0,
                                                  left: 0,
                                                  right: 0,
                                                  child: Container(
                                                    height: 3,
                                                    // Intentional: track scrim over video artwork.
                                                    color: Colors.black45,
                                                    child: Align(
                                                      alignment: Alignment.centerLeft,
                                                      child: FractionallySizedBox(
                                                        widthFactor: (video.watchProgress ?? 0.0).clamp(0.0, 1.0),
                                                        child: Container(
                                                          color: theme.primaryColor,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          // No fill: the card's own lit
                                          // surface shows behind the title.
                                          // With the thumbnail above and a
                                          // flat strip below, zero pixels of
                                          // the card's material were visible
                                          // - a picture of a card, not a
                                          // machined part.
                                          padding: const EdgeInsets.all(NeuSpace.s8),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                video.title,
                                                style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: NeuSpace.s2),
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                children: [
                                                  Text(
                                                    video.publishedAt.toLocal().toString().substring(0, 10),
                                                    style: NeuType.caption(themeNotifier.isDarkTheme),
                                                  ),
                                                  if (progressPct > 0)
                                                    Text(
                                                      '$progressPct%',
                                                      style: NeuType.plate(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                                                    ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  }),
                ),
              ),
                ),
              ),
            ),
            const SizedBox(height: NeuSpace.s24),
          ],

          // Active Downloads card (Conditional)
          if (runningDownloads.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(NeuSpace.s16),
              // Through the engine, not around it: this was the only card on
              // Home with a hand-rolled BoxDecoration - accent gradient wash,
              // outline, glow - so it had no bevel, no grain and no cast
              // shadow agreeing with the light, and read as a web promo
              // banner taped onto the rack. The accent identity survives as
              // a tinted base plus ring; the material does the rest.
              decoration: NeuTheme.raised(
                themeNotifier.isDarkTheme,
                radius: NeuRadius.r12,
                base: Color.alphaBlend(
                    theme.primaryColor.withValues(alpha: 0.12),
                    themeNotifier.surfaceColor),
                border: Border.all(
                    color: theme.primaryColor.withValues(alpha: 0.3),
                    width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.downloading, color: themeNotifier.accentInk, size: 20),
                          const SizedBox(width: NeuSpace.s8),
                          Text(
                            'Active Downloads Running',
                            style: NeuType.headingSm(themeNotifier.isDarkTheme),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: _openLibrary,
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('Open Library', style: NeuType.labelMetrics),
                      ),
                    ],
                  ),
                  const SizedBox(height: NeuSpace.s12),
                  ...runningDownloads.take(2).map((item) {
                    final progress = item.progress ?? 0.0;
                    final taskText = item.status ?? 'Downloading...';
                    final title = item.label;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: NeuSpace.s8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: NeuType.bodySm(themeNotifier.isDarkTheme),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: NeuSpace.s4),
                                NeuProgressBar(
                                  value: progress,
                                  size: NeuProgressSize.sm,
                                  semanticLabel: 'Download progress',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: NeuSpace.s16),
                          Text(
                            taskText.length > 25 ? '${taskText.substring(0, 22)}...' : taskText,
                            style: NeuType.caption(themeNotifier.isDarkTheme),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
            const SizedBox(height: NeuSpace.s24),
          ],

          // Quick Action Cards
          SectionHeader(title: 'Quick actions'),
          const SizedBox(height: NeuSpace.s12),
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // Same reasoning as the Live-now grid: the clip only ever cuts
            // the bottom row's shadow - the last thing on the Home page.
            clipBehavior: Clip.none,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              mainAxisExtent: 90,
            ),
            children: [
              _buildQuickActionCard(
                context: context,
                theme: theme,
                icon: Icons.settings,
                title: 'Open Settings',
                subtitle: 'Configure Players & Themes',
                onTap: _showSettingsDialog,
              ),
              _buildQuickActionCard(
                context: context,
                theme: theme,
                icon: Icons.video_library,
                title: 'Library',
                subtitle:
                    '${_downloadedVodsRegistry.length} downloaded VOD${_downloadedVodsRegistry.length == 1 ? '' : 's'} & history',
                onTap: _openLibrary,
              ),
              _buildQuickActionCard(
                context: context,
                theme: theme,
                icon: Icons.account_circle,
                title: 'Twitch Account',
                subtitle: _authenticatedUserLogin != null ? 'Logged in as $_authenticatedUserLogin' : 'Connect Account',
                onTap: () {
                  if (_authenticatedUserLogin == null) {
                    _startOAuthServer();
                  } else {
                    _showSettingsDialog();
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Warns that changes are not reaching disk.
  ///
  /// A banner rather than a message: this is a CONDITION, not an event. It
  /// clears itself the moment a save succeeds (which happens within seconds
  /// during normal use), and a snackbar would be missed entirely while the app
  /// sits minimised in the tray, which is its normal state.
  Widget _buildSaveFailureBanner(StorageWriteFailure failure) {
    final isDark = themeNotifier.isDarkTheme;
    // The translucent wash lets the panel grain through; the engraved cut at
    // its bottom is what makes it read as a milled warning band of the
    // chassis rather than a highlighter stroke across the plate.
    return Column(mainAxisSize: MainAxisSize.min, children: [
    Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s8),
      color: NeuTheme.danger.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              size: 16, color: NeuTheme.dangerText(isDark)),
          const SizedBox(width: NeuSpace.s8),
          Expanded(
            child: Text(
              'Your settings could not be saved to disk. Recent changes may be '
              'lost when the app closes.',
              style: NeuType.label(isDark, color: NeuTheme.dangerText(isDark)),
            ),
          ),
          TextButton(
            // Same fix as the reconnect banner: the accent ink vanished into
            // the danger wash.
            onPressed: () => _showSaveFailureDetail(failure),
            style: TextButton.styleFrom(
              foregroundColor: NeuTheme.dangerText(isDark),
            ),
            child: Text('Details',
                style: NeuType.captionStrong(isDark,
                    color: NeuTheme.dangerText(isDark))),
          ),
          // NeuIconAction, whose whole reason to exist is ending exactly
          // this: a dismiss target collapsed to its 14px glyph.
          NeuIconAction(
            icon: Icons.close,
            tooltip: 'Dismiss',
            size: NeuActionSize.sm,
            style: NeuActionStyle.flat,
            onPressed: () => setState(() => _saveWarningDismissed = true),
          ),
        ],
      ),
    ),
    EngravedRule(),
    ]);
  }

  /// The account token was rejected, and this is where it gets fixed.
  ///
  /// Persistent rather than a snackbar, and carrying the remedy rather than
  /// describing it: the failure this replaces greeted the user on every
  /// launch with a raw `{"error":"Unauthorized"...}` blob that scrolled away
  /// before it could be acted on, while Settings kept showing a green tick.
  Widget _buildTwitchAuthBanner(TwitchAuthStatus status) {
    final isDark = themeNotifier.isDarkTheme;
    final detail = connectionDetail(status);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: NeuSpace.s16, vertical: NeuSpace.s8),
        color: NeuTheme.danger.withValues(alpha: 0.12),
        child: Row(
          children: [
            Icon(Icons.link_off, size: 16, color: NeuTheme.dangerText(isDark)),
            const SizedBox(width: NeuSpace.s8),
            Expanded(
              child: Text(
                detail ??
                    'Your Twitch account token was rejected. Followed channels '
                        'and VOD lists are unavailable until you reconnect.',
                style: NeuType.label(isDark, color: NeuTheme.dangerText(isDark)),
              ),
            ),
            TextButton(
              // Reconnecting happens HERE. Sending the user to Settings to
              // find the button is the extra step that makes a warning feel
              // like a scolding.
              onPressed: _startOAuthServer,
              style: TextButton.styleFrom(
                foregroundColor: NeuTheme.dangerText(isDark),
              ),
              child: Text('Reconnect',
                  style: NeuType.captionStrong(isDark,
                      color: NeuTheme.dangerText(isDark))),
            ),
            NeuIconAction(
              icon: Icons.close,
              tooltip: 'Dismiss',
              size: NeuActionSize.sm,
              style: NeuActionStyle.flat,
              onPressed: () => setState(() {
                _authWarningDismissed = true;
                _dismissedFault = status.fault;
              }),
            ),
          ],
        ),
      ),
      EngravedRule(),
    ]);
  }

  void _showSaveFailureDetail(StorageWriteFailure failure) {
    NeuDialog.show<void>(
      context,
      // Read-only detail: clicking away is a fine way to leave it.
      dismissible: true,
      builder: (context) => NeuDialog(
        title: 'Could not save settings',
        icon: Icons.error_outline,
        tone: DialogTone.destructive,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Writing to this file keeps failing. Common causes are a full '
              'disk, antivirus or backup software holding the file open, or '
              'the folder no longer being writable.',
              style: NeuType.body(themeNotifier.isDarkTheme),
            ),
            const SizedBox(height: NeuSpace.s12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(NeuSpace.s8),
              decoration: NeuTheme.sunkenDecoration(
                  themeNotifier.isDarkTheme,
                  radius: NeuRadius.r8),
              child: SelectableText(
                '${failure.path}\n\n${failure.error}',
                style: NeuType.mono(themeNotifier.isDarkTheme),
              ),
            ),
          ],
        ),
        actions: [
          NeuDialogAction.secondary('Close', () => Navigator.pop(context)),
        ],
      ),
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
    await _storageService.saveRecentWatchedVods(
      _recentWatchedVods.map((v) => v.toJson()).toList(),
    );
    await _saveChannels();
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

  Widget _buildQuickActionCard({
    required BuildContext context,
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    bool isHovered = false;
    return StatefulBuilder(
      builder: (context, setHoverState) {
        return MouseRegion(
          onEnter: (_) => setHoverState(() => isHovered = true),
          onExit: (_) => setHoverState(() => isHovered = false),
          cursor: SystemMouseCursors.click,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(NeuRadius.r12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              transform: Matrix4.translationValues(0, isHovered ? -2 : 0, 0),
              padding: const EdgeInsets.all(NeuSpace.s12),
              decoration: NeuTheme.raisedDecoration(
                themeNotifier.isDarkTheme,
                radius: NeuRadius.r12,
                // Border only when it exists - see the strip cards.
                // The card hover grammar, same as the VOD cards: -2px lift
                // with a 0.6-alpha ring. Full alpha here made near-identical
                // cards light up at two different strengths in one window.
                border: isHovered
                    ? Border.all(
                        color: theme.primaryColor.withValues(alpha: 0.6),
                        width: 1.5)
                    : null,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(NeuSpace.s8),
                    // A pocket cut into the card, not a sticker on it - the
                    // dashboard header does this same job with sunken chips,
                    // and the two screens should speak one language.
                    decoration: NeuTheme.sunken(
                      themeNotifier.isDarkTheme,
                      radius: NeuRadius.r8,
                      depth: NeuElevation.d1,
                      base: Color.alphaBlend(
                          theme.primaryColor.withValues(alpha: 0.12),
                          NeuTheme.wellSurface(themeNotifier.isDarkTheme)),
                    ),
                    child: Icon(icon, size: 20, color: themeNotifier.accentInk),
                  ),
                  const SizedBox(width: NeuSpace.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: NeuType.headingSm(themeNotifier.isDarkTheme),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: NeuSpace.s2),
                        Text(
                          subtitle,
                          style: NeuType.caption(themeNotifier.isDarkTheme),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDashboard(ThemeData theme, TwitchChannel channel) {
    // maybeOf, not of. This method is CALLED from build() with the State's own
    // context, which sits ABOVE the AppLayout that build() returns - so
    // AppLayout.of asserted "No AppLayout ancestor" and took the entire
    // channel dashboard down. maybeOf measures the media query instead, which
    // yields the same values.
    final layout = AppLayout.maybeOf(context);
    // isSmall is gone: the VOD toolbar no longer has a wide-only variant to
    // switch to, because the inline duplicate of the display controls was
    // removed in favour of the single popover.
    final isCompact = layout.isRail;
    // CustomScrollView so the VOD grid renders as a real SliverGrid and
    // off-screen cards are culled; the old SingleChildScrollView +
    // shrinkWrap GridView materialized every card at once.
    return CustomScrollView(
            slivers: [
              SliverPadding(
                // s16 minimum: the viewport clips at its bounds, and a d3
                // card's cast shadow reaches ~15px - s12 cut its tail on
                // every bottom-row card in compact windows.
                padding: EdgeInsets.all(isCompact ? NeuSpace.s16 : NeuSpace.s24),
                sliver: SliverMainAxisGroup(slivers: [
                // Real-time Stats Card Widget
                SliverToBoxAdapter(child: DashboardHeader(
                  channel: channel,
                  pulseController: _pulseController!,
                  isPlaying: _playerService.runningChannels.contains(channel.username),
                  onPlay: () {
                    _playerService.launchStreamlinkForLive(
                      channel.username,
                      channel.isLive,
                      channel.streamTitle,
                      channel.game,
                      _settings
                    );
                  },
                  // The whole channel: its details (follower count
                  // included, which the batched poll leaves out) and its
                  // VOD list, merged in place.
                  onRefresh: () {
                    unawaited(_refreshChannelDetails(channel));
                    unawaited(_refreshSelectedVods(silent: false));
                  },
                  openExternalLink: _openExternalLink,
                )),

                // VOD section (if OAuth token present)
                if (_settings.twitchOauthToken.trim().isNotEmpty) ...[
                  SliverToBoxAdapter(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  SizedBox(height: isCompact ? 12 : 32),
                  // In selection mode the SelectionBar REPLACES this row
                  // rather than growing out of it. Appending the bulk actions
                  // to the toolbar is what made the toolbar overflow: four
                  // labelled buttons, a count, a progress ring and two icon
                  // buttons, with no compact branch anywhere.
                  if (_isMultiSelectMode)
                    SelectionBar(
                      selectedCount: _selectedVodIds.length,
                      busy: _isBulkUpdatingVods,
                      busyLabel: 'Syncing with Twitch...',
                      onExit: () => setState(() {
                        _isMultiSelectMode = false;
                        _selectedVodIds.clear();
                      }),
                      onClear: () => setState(() => _selectedVodIds.clear()),
                      onSelectAllVisible: () => setState(() {
                        _selectedVodIds
                            .addAll(_filteredChannelVods().map((v) => v.id));
                      }),
                      actions: [
                        SelectionAction(
                          label: 'Watched',
                          icon: Icons.check_circle_outline,
                          tone: SelectionTone.accent,
                          onPressed: _selectedVodIds.isEmpty
                              ? null
                              : () => _bulkUpdateSelectedVods(true),
                        ),
                        SelectionAction(
                          label: 'Unwatched',
                          icon: Icons.unpublished_outlined,
                          onPressed: _selectedVodIds.isEmpty
                              ? null
                              : () => _bulkUpdateSelectedVods(false),
                        ),
                        SelectionAction(
                          label: 'Download',
                          icon: Icons.download,
                          tone: SelectionTone.positive,
                          onPressed: _selectedVodIds.isEmpty
                              ? null
                              : _bulkDownloadSelectedVods,
                        ),
                        SelectionAction(
                          label: 'Delete files',
                          icon: Icons.delete_outline,
                          tone: SelectionTone.destructive,
                          onPressed: _selectedVodIds.isEmpty
                              ? null
                              : _bulkDeleteSelectedVods,
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        // A labelled button, not a bare pencil. The pencil had
                        // a tooltip and nothing else, so the only way to learn
                        // the grid had a selection mode was to hover a 40px
                        // icon and wait.
                        NeuButton(
                          onPressed: () => setState(() {
                            _isMultiSelectMode = true;
                            _selectedVodIds.clear();
                          }),
                          padding: const EdgeInsets.symmetric(
                              horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                          borderRadius: BorderRadius.circular(NeuRadius.r8),
                          tooltip: 'Pick several VODs to download or mark',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.checklist,
                                  size: 15,
                                  color: NeuTheme.text(
                                      themeNotifier.isDarkTheme)),
                              const SizedBox(width: NeuSpace.s6),
                              Text('Select',
                                  style: NeuType.captionStrong(
                                      themeNotifier.isDarkTheme,
                                      color: NeuTheme.text(
                                          themeNotifier.isDarkTheme))),
                            ],
                          ),
                        ),
                        // The note a failed refresh leaves gives way (with
                        // an ellipsis) before any control does.
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: _buildStaleVodNote(),
                          ),
                        ),
                        const SizedBox(width: NeuSpace.s8),
                        if (_isLoadingVods || _vodBrowser.isRefreshing) ...[
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: NeuProgressRing(
                                size: NeuProgressRingSize.sm,
                                semanticLabel: 'Loading'),
                          ),
                          const SizedBox(width: NeuSpace.s12),
                        ],
                        // The list refreshes by itself (a broadcast starting
                        // or ending, every few minutes while on screen, on
                        // coming back from the tray); this is for not
                        // waiting. Merged in, so loaded pages and the
                        // selection stay.
                        NeuIconAction(
                          icon: Icons.refresh,
                          tooltip: 'Check for new VODs',
                          onPressed: _isLoadingVods || _vodBrowser.isRefreshing
                              ? null
                              : () => _refreshSelectedVods(silent: false),
                        ),
                        const SizedBox(width: NeuSpace.s8),
                        // One control path, not two. These settings used to be
                        // rendered inline when the window was wide and in a
                        // popover when it was narrow, and the two copies had
                        // already drifted ('Font: ' versus 'Font Size: ', a
                        // 110px slider versus an Expanded one).
                        InteractivePopover(
                          popover: _buildVodsSettingMenu(theme),
                          child: _VodDisplayButton(theme: theme),
                        ),
                      ],
                    ),
                  const SizedBox(height: NeuSpace.s16),
                  if (_isWebTokenExpired) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: NeuSpace.s16),
                      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s12),
                      // Intentional: translucent warning tint, readable over both themes.
                      decoration: BoxDecoration(
                        color: NeuTheme.warning.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(NeuRadius.r8),
                        border: Border.all(color: NeuTheme.warning.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: NeuTheme.warningText(themeNotifier.isDarkTheme), size: 20),
                          const SizedBox(width: NeuSpace.s12),
                          Expanded(
                            child: Text(
                              'Your Twitch Browser OAuth Token has expired. VOD watch progress tracking is currently paused.',
                              style: NeuType.headingSm(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                            ),
                          ),
                          const SizedBox(width: NeuSpace.s12),
                          TextButton(
                            style: TextButton.styleFrom(
                              backgroundColor: NeuTheme.warning.withValues(alpha: 0.2),
                              foregroundColor: NeuTheme.warningText(themeNotifier.isDarkTheme),
                              padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                            ),
                            onPressed: _showSettingsDialog,
                            child: const Text('Update Token', style: NeuType.labelMetrics),
                          ),
                          const SizedBox(width: NeuSpace.s8),
                          NeuIconAction(
                            icon: Icons.close,
                            tooltip: 'Dismiss',
                            size: NeuActionSize.sm,
                            style: NeuActionStyle.flat,
                            onPressed: () {
                              setState(() {
                                _isWebTokenExpired = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                  ])),

                  // Modular Vods Grid Component
                  VodsGrid(
                    vods: _channelVods,
                    isLoading: _isLoadingVods,
                    vodsError: _vodsError,
                    vodScale: _settings.vodCardScale,
                    vodTitleFontSize: _settings.vodTitleFontSize,
                    showGamesOnThumbnails: _settings.showGamesOnThumbnails,
                    selectedGamesFilter: _selectedGamesFilter,
                    vodSearchController: _vodSearchController,
                    theme: theme,
                    isMultiSelectMode: _isMultiSelectMode,
                    selectedVodIds: _selectedVodIds,
                    isPlaying: (id) => _playerService.playingVodIds.contains(id),
                    isDownloaded: (id) => _downloadedVodIds.contains(id),
                    getDownloadStatus: (id) => _playerService.activeDownloadTasks[id],
                    getDownloadProgress: (id) => _playerService.activeDownloadsProgress[id],
                    pulseController: _pulseController,
                    watchedThreshold: _settings.watchedThreshold,
                    activeProgressColor: themeNotifier.activeProgressColor,
                    watchedProgressColor: themeNotifier.watchedProgressColor,
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
                    onPlay: (vod) => _playVod(vod, _selectedChannel?.username ?? 'VOD'),
                    onDownload: (vod) => _queueVodDownload(vod, _selectedChannel?.username ?? 'VOD'),
                    onDeleteDownload: (id) => _deleteDownloadedVod(id, _selectedChannel?.username ?? 'VOD'),
                    onCancelDownload: (id) => _cancelVodDownload(id, _selectedChannel?.username ?? 'VOD'),
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
                  ),
                  
                  if (_vodPaginationCursor != null && _vodPaginationCursor!.isNotEmpty && _channelVods.isNotEmpty) ...[
                    SliverToBoxAdapter(child: Column(children: [
                    const SizedBox(height: NeuSpace.s24),
                    Center(
                      child: Container(
                        width: 180,
                        height: 40,
                        // Through the engine: a flat outlined token-fill pill
                        // under a grid of machined VOD cards was the web
                        // outline-button idiom, and it is what the page ends
                        // on.
                        decoration: NeuTheme.raised(themeNotifier.isDarkTheme,
                            radius: NeuRadius.r8),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            foregroundColor: NeuTheme.text(themeNotifier.isDarkTheme),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(NeuRadius.r8),
                            ),
                            elevation: 0,
                          ),
                          onPressed: _isLoadingVods
                              ? null
                              : () => _fetchVodsForChannel(channel, loadMore: true),
                          child: _isLoadingVods
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: NeuProgressRing(size: NeuProgressRingSize.sm, color: NeuTheme.text(themeNotifier.isDarkTheme), semanticLabel: 'Loading'),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.expand_more, size: 18),
                                    SizedBox(width: NeuSpace.s6),
                                    Text('Load More VODs', style: NeuType.labelMetrics),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    ])),
                  ],
                ],
                ]),
              ),
            ],
    );
  }

  /// "Couldn't refresh" over a list that is not current, with when it is
  /// from. A failed fetch over a cached list used to say nothing at all, so a
  /// list from hours ago passed for a current one.
  Widget _buildStaleVodNote() {
    final stale = _vodBrowser.stale;
    if (stale == null) return const SizedBox.shrink();
    final isDark = themeNotifier.isDarkTheme;
    final since = stale.since;
    String two(int v) => v < 10 ? '0$v' : '$v';
    final clock = '${two(since.hour)}:${two(since.minute)}';
    return Tooltip(
      message: stale.reason,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 14, color: NeuTheme.warningText(isDark)),
          const SizedBox(width: NeuSpace.s6),
          Flexible(
            child: Text(
              "Couldn't refresh - showing the list from $clock",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NeuType.caption(isDark, color: NeuTheme.warningText(isDark)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVodsSettingMenu(ThemeData theme) {
    return Container(
      width: 320,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      padding: const EdgeInsets.all(NeuSpace.s16),
      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r12),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatefulBuilder(
              builder: (context, setMenuState) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.sports_esports, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                        const SizedBox(width: NeuSpace.s6),
                        Text('Show All Games on Thumbnails', style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme))),
                      ],
                    ),
                    NeuSwitch(
                      value: _settings.showGamesOnThumbnails,
                      onChanged: (val) {
                        setState(() {
                          _settings.showGamesOnThumbnails = val;
                        });
                        _saveChannels();
                        setMenuState(() {});
                      },
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: NeuSpace.s12),
            Text('Filter Broadcasts:', style: NeuType.captionStrong(themeNotifier.isDarkTheme)),
            const SizedBox(height: NeuSpace.s6),
            NeuTextField(
              controller: _vodSearchController,
              hintText: 'Filter VODs...',
              prefixIcon: Icons.search,
              size: NeuFieldSize.md,
              onChanged: (val) => setState(() {}),
              onClear: () => setState(() {}),
            ),
            const SizedBox(height: NeuSpace.s12),
            StatefulBuilder(
              builder: (context, setMenuState) {
                final uniqueGames = _channelVods.expand((vod) => vod.games).toSet().toList()..sort();
                if (uniqueGames.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Filter by Games:', style: NeuType.captionStrong(themeNotifier.isDarkTheme)),
                        if (_selectedGamesFilter.isNotEmpty)
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedGamesFilter.clear();
                                });
                                setMenuState(() {});
                              },
                              child: Text(
                                'Clear All',
                                style: NeuType.plate(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: NeuSpace.s8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r6),
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: NeuSpace.s4),
                        children: uniqueGames.map((game) {
                          final isChecked = _selectedGamesFilter.contains(game);
                          return InkWell(
                            onTap: () {
                              setState(() {
                                if (isChecked) {
                                  _selectedGamesFilter.remove(game);
                                } else {
                                  _selectedGamesFilter.add(game);
                                }
                              });
                              setMenuState(() {});
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s6),
                              child: Row(
                                children: [
                                  NeuCheckbox(
                                    value: isChecked,
                                    activeColor: theme.primaryColor,
                                    size: 16,
                                    onChanged: (val) {
                                      setState(() {
                                        if (isChecked) {
                                          _selectedGamesFilter.remove(game);
                                        } else {
                                          _selectedGamesFilter.add(game);
                                        }
                                      });
                                      setMenuState(() {});
                                    },
                                  ),
                                  const SizedBox(width: NeuSpace.s8),
                                  Expanded(
                                    child: Text(
                                      game,
                                      style: NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: NeuSpace.s16),
            Row(
              children: [
                Icon(Icons.photo_size_select_large, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                const SizedBox(width: NeuSpace.s6),
                Text('Card Size: ', style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
                Expanded(
                  child: SliderTheme(
                    data: neuSliderTheme(context),
                    child: Slider(
                      value: _settings.vodCardScale,
                      min: 200.0,
                      max: 600.0,
                      onChanged: (val) {
                        setState(() {
                          _settings.vodCardScale = val;
                        });
                      },
                      onChangeEnd: (_) => _saveChannels(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NeuSpace.s8),
            Row(
              children: [
                Icon(Icons.format_size, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                const SizedBox(width: NeuSpace.s6),
                Text('Font Size: ', style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
                Expanded(
                  child: SliderTheme(
                    data: neuSliderTheme(context),
                    child: Slider(
                      value: _settings.vodTitleFontSize,
                      min: AppSettings.minVodTitleFontSize,
                      max: AppSettings.maxVodTitleFontSize,
                      onChanged: (val) {
                        setState(() {
                          _settings.vodTitleFontSize = val;
                        });
                      },
                      onChangeEnd: (_) => _saveChannels(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
    setState(() {});
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
    
    _checkDownloadedVods();
    setState(() {
      _selectedVodIds.clear();
      _isMultiSelectMode = false;
    });
    _showSnackBar('Deleted $count downloaded VOD files.', isError: false);
  }
}

/// The trigger for the VOD display settings.
///
/// Was a hover-morphing chip that only revealed its accent styling when the
/// pointer was over it, and appeared ONLY when the window was narrow - so at
/// wide widths the controls it opens had no button at all, and at narrow
/// widths there was no static hint that a menu existed. It is now a plain
/// labelled button, present at every width.
class _VodDisplayButton extends StatelessWidget {
  const _VodDisplayButton({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    // A plain raised chip, NOT a NeuButton. With onPressed: null the button
    // painted the full disabled treatment - dimmed ink, flat depth, basic
    // cursor, excluded from Tab order - so the only entry point to the
    // grid's display settings LOOKED dead while working by accident of the
    // gesture arena. InteractivePopover owns the tap, cursor and focus.
    return Tooltip(
      message: 'Card size, title size, filters and game badges',
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
      decoration: NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tune, size: 15, color: NeuTheme.text(isDark)),
          const SizedBox(width: NeuSpace.s6),
          Text('Display',
              style: NeuType.bodySm(isDark)),
          const SizedBox(width: NeuSpace.s2),
          Icon(Icons.arrow_drop_down, size: 16, color: NeuTheme.subtext(isDark)),
        ],
      ),
      ),
    );
  }
}
