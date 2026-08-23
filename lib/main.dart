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
import 'services/storage_service.dart';
import 'services/twitch_api_service.dart';
import 'services/player_service.dart';
import 'services/update_service.dart';
import 'services/log_store.dart';
import 'state/activity_state.dart';
import 'state/download_registry.dart';
import 'widgets/shell/app_layout.dart';
import 'widgets/shell/motion.dart';
import 'widgets/shell/neu_dialog.dart';
import 'widgets/neumorphic/neu_progress.dart';
import 'widgets/neumorphic/neu_text_field.dart';
import 'state/vod_cache.dart';
import 'widgets/activity_pill.dart';
import 'widgets/log_viewer_dialog.dart';
import 'widgets/sidebar_panel.dart';
import 'widgets/dashboard_header.dart';
import 'widgets/vods_grid.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/hover_overlay_menu.dart';
import 'widgets/interactive_popover.dart';
import 'package:screen_retriever/screen_retriever.dart';

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
import 'theme/neu_theme.dart';
import 'widgets/neumorphic/neu_avatar.dart';
import 'theme/theme_notifier.dart';
import 'utils/color_utils.dart';


void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await localNotifier.setup(
    appName: 'Twitch Streamlink GUI',
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );

  await windowManager.ensureInitialized();

  final storage = StorageService();
  // Existence is checked BEFORE loading: loadConfig() quarantines an unreadable
  // file and returns null, which is indistinguishable from a first run - so a
  // user whose config got corrupted was shown the onboarding wizard.
  final bool isFirstRun = !storage.configExists();
  final config = await storage.loadConfig();
  AppSettings settings = AppSettings();
  if (config != null && config['settings'] is Map<String, dynamic>) {
    // Runs before the first frame, so an unparseable config here would stop
    // the app from starting at all rather than falling back to defaults.
    try {
      settings = AppSettings.fromJson(config['settings']);
    } catch (e) {
      print('[Config] Settings unreadable, using defaults: $e');
    }
  }

  // Autostart launches pass --start-minimized; the manual-launch preference
  // does the same thing without the flag.
  final bool startMinimized =
      args.contains('--start-minimized') || settings.startMinimized;

  // Re-writing the Run value at every launch silently heals a moved install.
  if (settings.launchAtStartup) {
    StartupService().sync(true);
  }

  // Saved geometry may reference a monitor that no longer exists (undocked
  // laptop) or carry hand-edited garbage; restore only bounds that are
  // actually reachable. The native runner applies the same guard to its
  // pre-Flutter registry positioning.
  Rect? restoredBounds;
  try {
    final displays = await screenRetriever.getAllDisplays();
    final displayRects = <Rect>[
      for (final d in displays)
        displayRect(
          size: d.size,
          visiblePosition: d.visiblePosition,
          visibleSize: d.visibleSize,
        ),
    ];
    if (displayRects.isNotEmpty) {
      restoredBounds = sanitizeWindowBounds(
        x: settings.windowX,
        y: settings.windowY,
        width: settings.windowWidth,
        height: settings.windowHeight,
        displays: displayRects,
      );
    }
  } catch (_) {
    // Fall back to the raw saved values below.
  }

  final bool shouldCenter = restoredBounds == null &&
      (settings.windowX == null || settings.windowY == null);

  WindowOptions windowOptions = WindowOptions(
    size: restoredBounds?.size ?? Size(settings.windowWidth, settings.windowHeight),
    center: shouldCenter,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    // MOVE ONLY - never resize here.
    //
    // waitUntilReadyToShow has already applied WindowOptions.size, and both
    // that call and anything in this callback convert logical -> physical
    // using window.devicePixelRatio, which this early in startup may not yet
    // reflect the display's real ratio. A second sizing call (this used to be
    // setBounds, which sets size AND position) can therefore land on a
    // different ratio than the first and leave the native window at a
    // physical size the engine never laid out for: content squeezed into part
    // of the frame, unpainted regions beside it, and the sidebar dropped
    // because the reported width fell under the narrow breakpoint. Racy by
    // nature, so it cleared on the next launch.
    final restoredPosition = restoredBounds?.topLeft ??
        (settings.windowX != null && settings.windowY != null
            ? Offset(settings.windowX!, settings.windowY!)
            : null);
    if (restoredPosition != null) {
      await windowManager.setPosition(restoredPosition);
    }
    if (settings.isWindowMaximized && !startMinimized) {
      await windowManager.maximize();
    }
    if (!startMinimized) {
      // When starting minimized the native runner also suppressed its
      // first-frame Show(), so not calling show() here means no flash at all.
      await windowManager.show();
      await windowManager.focus();
    }
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(380, 500));
  });

  runApp(TwitchStreamlinkApp(isFirstRun: isFirstRun));
}

class TwitchStreamlinkApp extends StatelessWidget {
  const TwitchStreamlinkApp({super.key, this.isFirstRun = false});

  final bool isFirstRun;

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
          theme: ThemeData(
            brightness: Brightness.light,
            fontFamily: 'Segoe UI',
            scaffoldBackgroundColor: themeNotifier.backgroundColor,
            primaryColor: themeNotifier.primaryColor,
            cardColor: themeNotifier.surfaceColor,
            colorScheme: ColorScheme.light(
              primary: themeNotifier.primaryColor,
              secondary: NeuTheme.live,
              surface: themeNotifier.surfaceColor,
              error: NeuTheme.danger,
            ),
            textTheme: const TextTheme(
              titleLarge: TextStyle(fontWeight: FontWeight.bold, color: NeuTheme.lightText),
              bodyLarge: TextStyle(color: NeuTheme.lightText),
              bodyMedium: TextStyle(color: NeuTheme.lightSubtext),
            ),
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'Segoe UI',
            scaffoldBackgroundColor: themeNotifier.backgroundColor,
            primaryColor: themeNotifier.primaryColor,
            cardColor: themeNotifier.surfaceColor,
            colorScheme: ColorScheme.dark(
              primary: themeNotifier.primaryColor,
              secondary: NeuTheme.live,
              surface: themeNotifier.surfaceColor,
              error: NeuTheme.danger,
            ),
            textTheme: const TextTheme(
              titleLarge: TextStyle(fontWeight: FontWeight.bold, color: NeuTheme.darkText),
              bodyLarge: TextStyle(color: NeuTheme.darkText),
              bodyMedium: TextStyle(color: NeuTheme.darkSubtext),
            ),
          ),
          home: MainScreen(isFirstRun: isFirstRun),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key, this.isFirstRun = false});

  final bool isFirstRun;

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
  final Set<String> _previouslyLiveFavoriteUsernames = {};
  
  Timer? _favoritesLiveCheckTimer;
  Timer? _downloadCheckTimer;
  HttpServer? _oauthServer;
  
  List<TwitchChannel> _followedChannels = [];
  bool _isLoadingFollowed = false;
  String? _authenticatedUserLogin;
  String? _authenticatedUserAvatar;
  int _sidebarTab = 0; 
  
  List<TwitchVideo> _channelVods = [];
  bool _isLoadingVods = false;
  String? _vodsError;

  final TextEditingController _vodSearchController = TextEditingController();
  AnimationController? _pulseController;
  bool _sidebarCollapsed = false;
  String? _vodPaginationCursor;
  final Set<String> _selectedGamesFilter = {};
  bool _isWebTokenExpired = false;
  bool _isMultiSelectMode = false;
  final Set<String> _selectedVodIds = {};
  bool _isBulkUpdatingVods = false;
  Map<String, int> _localVodsProgress = {};
  Set<String> _downloadedVodIds = {};
  Map<String, String> _downloadedVodsRegistry = {};
  final Map<String, TwitchVideo> _activePlayingVideos = {};
  List<TwitchVideo> _recentWatchedVods = [];

  /// Set when the user dismisses the save-failure banner, so a persistent
  /// disk problem does not become an undismissable wall. Reset whenever a save
  /// succeeds, so a NEW failure is reported again.
  bool _saveWarningDismissed = false;

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
  final Map<String, String> _lastAutoPlayedStreamSession = {};

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initSystemTray();
    
    // Created stopped. It used to `..repeat(reverse: true)` here and was
    // only ever touched again by dispose(), so it drove a 60fps rebuild for
    // the entire life of the process - including while the app sat in the
    // tray, which is its normal resting state, with nothing live to pulse.
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

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

    _playerService.onWatchProgressUpdated = (vodId, position, progress) {
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

    _watchSaveFailures();
    _loadChannels();
    
    _downloadCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkDownloadedVods();
    });
    
    _favoritesLiveCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _refreshAllChannels();
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
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: themeNotifier.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.system_update, color: themeNotifier.accentInk),
              const SizedBox(width: 10),
              Text('Update Available (${info.tagName})', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A new version of Twitch Streamlink GUI is available on GitHub Releases.\n\n'
                  'Current Version: v${UpdateService.currentVersion}\n'
                  'Latest Version: ${info.tagName}',
                  style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
                ),
                if (info.releaseNotes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Release Notes:', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    padding: const EdgeInsets.all(10),
                    decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 8),
                    child: SingleChildScrollView(
                      child: Text(
                        info.releaseNotes,
                        style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Remind Me Later', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.primaryColor),
              onPressed: () {
                Navigator.pop(context);
                _performAppUpdate(info);
              },
              icon: Icon(Icons.download, size: 16, color: themeNotifier.onPrimaryColor),
              label: Text('Update Now & Restart', style: TextStyle(color: themeNotifier.onPrimaryColor, fontWeight: FontWeight.bold)),
            ),
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

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setProgressState) {
            setDialogState = setProgressState;
            return AlertDialog(
              backgroundColor: themeNotifier.surfaceColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: [
                  Icon(Icons.downloading, color: themeNotifier.accentInk),
                  const SizedBox(width: 10),
                  Text('Updating Application', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
                ],
              ),
              content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(statusText, style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                    const SizedBox(height: 12),
                    NeuProgressBar(
                      value: progress > 0 ? progress : null,
                      semanticLabel: 'Update download',
                    ),
                    const SizedBox(height: 8),
                    Text('${(progress * 100).toStringAsFixed(1)}%', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    Future.microtask(() async {
      try {
        final updateService = UpdateService();
        final zipFile = await updateService.downloadUpdate(info.downloadUrl, (pct) {
          updateDialog(() => progress = pct);
        });

        updateDialog(() {
          statusText = 'Verifying download integrity...';
          progress = 0.0;
        });
        await updateService.verifyChecksum(zipFile, info.checksumUrl);

        updateDialog(() => statusText = 'Extracting update files...');
        final extractDir = await updateService.extractAndVerifyZip(zipFile);

        updateDialog(() => statusText = 'Closing running downloads and streams...');

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
        _playerService.stopAll();

        updateDialog(() => statusText = 'Applying update and restarting...');
        await updateService.applyUpdateAndRestart(extractDir);
      } catch (e) {
        _isUpdateInProgress = false;
        // stopAll() may already have killed everything before the failure. The
        // app survives this path, so any session still marked running would
        // stay that way for the rest of the session - and eviction only
        // reclaims finished ones.
        _logNotifier.endAllRunning(-1);
        if (mounted) {
          Navigator.pop(context);
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

  @override
  void dispose() {
    windowManager.removeListener(this);
    _vodSearchController.dispose();
    _pulseController?.dispose();
    _playerService.stopAll();
    _searchController.dispose();
    _sidebarSearchFocus.dispose();
    _oauthServer?.close(force: true);
    _downloadCheckTimer?.cancel();
    _favoritesLiveCheckTimer?.cancel();
    _windowSaveTimer?.cancel();
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
        windowManager.show();
        windowManager.focus();
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
            await windowManager.show();
            await windowManager.focus();
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

  Future<void> _handleAppExitRequest() async {
    await windowManager.show();
    await windowManager.focus();

    final hasUnfinished = _playerService.activeDownloadProcesses.isNotEmpty || _playerService.downloadQueue.isNotEmpty;
    if (hasUnfinished) {
      if (!mounted) return;
      final bool? confirmExit = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Exit Twitch Streamlink GUI?', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
            content: Text(
              'There are VOD downloads currently in progress or queued. '
              'If you exit, they will be paused and resumed the next time you start the app.\n\n'
              'Do you want to exit now?',
              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
              ),
              ElevatedButton(
                // White on the fixed danger red, theme-independent.
                style: ElevatedButton.styleFrom(backgroundColor: NeuTheme.danger, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Exit & Save Queue'),
              ),
            ],
          );
        },
      );

      if (confirmExit != true) {
        return;
      }

      await _persistUnfinishedDownloadsForRestart();

      // They chose "Exit & Save Queue". If that save did not reach disk,
      // exiting now loses the queue with no trace - and the banner that would
      // normally report it goes with the window.
      if (storageWriteFailure.value != null && mounted) {
        final bool? exitAnyway = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Could not save the download queue',
                style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
            content: Text(
              'Writing to ${storageWriteFailure.value?.path} failed, so the '
              'queued downloads will not resume after a restart.'
              '\n\nThis usually means the folder is full, read-only, or locked '
              'by another program. Cancel to fix it and try again.',
              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel',
                    style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: NeuTheme.danger, foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Exit Anyway'),
              ),
            ],
          ),
        );
        if (exitAnyway != true) return;
      }
    }

    _playerService.stopAll();
    await windowManager.destroy();
  }

  /// Runs the shared pulse only when something is actually pulsing and the
  /// user can see it.
  ///
  /// Deliberately ONE controller rather than one per consumer: every pulse in
  /// the app means the same thing ("this is live"), and independent
  /// controllers would drift out of phase, so a sidebar of live channels would
  /// shimmer instead of breathe.
  void _updatePulse() {
    final controller = _pulseController;
    if (controller == null) return;

    final somethingLive = _channels.any((c) => c.isLive) ||
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

  Future<void> _showWindow() async {
    await windowManager.show();
    _windowVisible = true;
    _updatePulse();
  }

  Future<void> _hideWindow() async {
    await windowManager.hide();
    _windowVisible = false;
    _updatePulse();
  }

  /// Whether the window is on screen. Starts true; the tray/minimise paths
  /// below keep it honest.
  bool _windowVisible = true;

  Timer? _windowSaveTimer;

  Future<void> _saveWindowState() async {
    _windowSaveTimer?.cancel();
    _windowSaveTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final isMaximized = await windowManager.isMaximized();
        if (!isMaximized) {
          final bounds = await windowManager.getBounds();
          _settings.windowWidth = bounds.width;
          _settings.windowHeight = bounds.height;
          _settings.windowX = bounds.left;
          _settings.windowY = bounds.top;
        }
        _settings.isWindowMaximized = isMaximized;
        await _saveChannels();
      } catch (_) {}
    });
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
    await windowManager.hide();
    _maybeShowTrayNotice();
  }

  @override
  void onWindowRestore() {
    _windowVisible = true;
    _updatePulse();
  }

  @override
  void onWindowMinimize() async {
    _windowVisible = false;
    _updatePulse();
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

    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.folder_copy, color: NeuTheme.warningText(themeNotifier.isDarkTheme)),
              const SizedBox(width: 10),
              Text('Configure Download Folder', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
            ],
          ),
          backgroundColor: themeNotifier.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Text(
            'A VOD download folder has not been configured yet.\n\nWould you like to select a folder now to proceed with your download?',
            style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.primaryColor),
              onPressed: () async {
                // Cross-platform picker (resolving Issue 2)
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
              },
              child: Text('Browse & Set Folder', style: TextStyle(color: themeNotifier.onPrimaryColor, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
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

  Future<void> _loadChannels() async {
    setState(() => _isGlobalLoading = true);
    try {
      final config = await _storageService.loadConfig();
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
      if (_settings.twitchOauthToken.trim().isNotEmpty) {
        _loadFollowedChannels();
      }
      final recents = await _storageService.loadRecentWatchedVods();
      if (mounted) {
        setState(() {
          _recentWatchedVods =
              recents.map(TwitchVideo.tryFromJson).whereType<TwitchVideo>().toList();
        });
      }
    } catch (e) {
      _showSnackBar('Error loading saved channels: $e', isError: true);
    } finally {
      setState(() => _isGlobalLoading = false);
    }
  }

  Future<void> _saveChannels() async {
    await _storageService.saveConfig(_channels, _settings, _localVodsProgress, _downloadedVodsRegistry);
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
            });
            await _saveChannels();
            _showSnackBar('Twitch account connected successfully!', isError: false);
            _loadFollowedChannels();
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
      _showSnackBar('Failed to start local login server: $e', isError: true);
    }
  }

  Future<void> _loadFollowedChannels() async {
    setState(() {
      _isLoadingFollowed = true;
    });

    try {
      final result = await _apiService.fetchFollowedChannels(_settings);
      setState(() {
        _authenticatedUserLogin = result.userLogin;
        _authenticatedUserAvatar = result.userAvatar;
        _followedChannels = result.channels;
      });

      for (var ch in _followedChannels) {
        _apiService.fetchChannelStats(ch, _settings).then((_) {
          if (mounted) setState(() {});
        });
      }
    } catch (e) {
      _showSnackBar('Error loading followed channels: $e', isError: true);
    } finally {
      setState(() {
        _isLoadingFollowed = false;
      });
    }
  }

  final VodCache _vodCache = VodCache();

  /// Identifies the newest VOD request, so a slower earlier one cannot win.
  ///
  /// Selecting channel A then B fires two fetches; whichever the network
  /// returns last used to be the one displayed, under B's header either way.
  int _vodRequestId = 0;

  /// Selects a channel and loads its VODs.
  ///
  /// The one path for this. It used to be open-coded in three places - the
  /// sidebar, the welcome screen's live cards and the "went live" notification
  /// - and each had forgotten something different: the game filter left over
  /// from the previous channel, the stale error, the async fetch started from
  /// inside setState.
  void _selectChannel(TwitchChannel channel) {
    setState(() {
      _showLibraryView = false;
      _selectedChannel = channel;
      _channelVods = [];
      _selectedGamesFilter.clear();
      _selectedVodIds.clear();
      _vodsError = null;
    });
    if (_settings.twitchOauthToken.trim().isNotEmpty) {
      _fetchVodsForChannel(channel);
    }
  }

  Future<void> _fetchVodsForChannel(TwitchChannel channel, {bool loadMore = false}) async {
    final cached = _vodCache.read(channel.username);
    final int requestId = ++_vodRequestId;
    setState(() {
      _isLoadingVods = cached == null || loadMore;
      _vodsError = null;
      if (!loadMore) {
        // A copy. _channelVods is mutated in place elsewhere (notably cleared
        // on channel switch), and handing out the cache's own list meant that
        // clear() emptied the cache entry too - so every channel visited once
        // was permanently cached as "no past broadcasts".
        _channelVods = List<TwitchVideo>.from(cached ?? const []);
        _vodPaginationCursor = null;
      }
    });

    try {
      final result = await _apiService.fetchVodsForChannel(
        channel: channel,
        settings: _settings,
        localVodsProgress: _localVodsProgress,
        afterCursor: loadMore ? _vodPaginationCursor : null,
      );

      if (!mounted || requestId != _vodRequestId) return;

      setState(() {
        _vodPaginationCursor = result.nextCursor;
        _isWebTokenExpired = result.isWebTokenExpired;
        if (loadMore) {
          _channelVods.addAll(result.vods);
        } else {
          _channelVods = List<TwitchVideo>.from(result.vods);
        }
        _vodCache.store(channel.username, _channelVods);
      });
      _checkDownloadedVods();
      await _saveChannels();
    } catch (e) {
      if (!mounted || requestId != _vodRequestId) return;
      if (_channelVods.isEmpty) {
        setState(() {
          _vodsError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      // Only the newest request may clear the spinner: a superseded one
      // finishing later would otherwise report the live fetch as done.
      if (mounted && requestId == _vodRequestId) {
        setState(() {
          _isLoadingVods = false;
        });
      }
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
        final result = await _apiService.fetchVodsForChannel(
          channel: channel,
          settings: _settings,
          localVodsProgress: _localVodsProgress,
          // This pass renders nothing, so the per-VOD game lookup is pure
          // overhead. It runs for every auto-download channel every minute.
          fetchGames: false,
        );
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

  void _prefetchVodsInBackground(List<TwitchChannel> channels) async {
    if (_settings.twitchOauthToken.trim().isEmpty) return;
    for (final channel in channels.take(10)) {
      if (!_vodCache.has(channel.username)) {
        try {
          final result = await _apiService.fetchVodsForChannel(
            channel: channel,
            settings: _settings,
            localVodsProgress: _localVodsProgress,
          );
          _vodCache.store(channel.username, result.vods);
        } catch (_) {}
      }
    }
  }

  Future<void> _refreshAllChannels({bool isInitialLoad = false}) async {
    final prevLiveMap = { for (var c in _channels) c.username: c.isLive };
    final prevFollowedLiveMap = { for (var c in _followedChannels) c.username: c.isLive };

    final futures = _channels.map((c) => _apiService.fetchChannelStats(c, _settings));
    await Future.wait(futures);

    for (final channel in _channels) {
      final cleanName = channel.username.toLowerCase().trim();
      final wasLive = prevLiveMap[channel.username] ?? false;
      if (channel.isLive) {
        if (!wasLive && !isInitialLoad) {
          channel.wentLiveTime = DateTime.now();
        }
        if (!_previouslyLiveFavoriteUsernames.contains(cleanName)) {
          _previouslyLiveFavoriteUsernames.add(cleanName);
          if (!isInitialLoad && _settings.notifyWentLive) {
            try {
              final gameText = channel.game ?? 'Twitch';
              final titleText = channel.streamTitle ?? 'Streaming Live!';
              final notification = LocalNotification(
                title: '${channel.username} is now LIVE!',
                body: 'Playing $gameText\n$titleText',
                silent: false,
              );
              notification.onClick = () async {
                await windowManager.show();
                await windowManager.focus();
                
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
      } else {
        _previouslyLiveFavoriteUsernames.remove(cleanName);
      }
    }

    _checkFavoritesAutomation();
    // Liveness just changed, so the pulse may need to start or stop.
    _updatePulse();

    if (_selectedChannel != null) {
      final index = _channels.indexWhere((c) => c.username == _selectedChannel!.username);
      if (index != -1) {
        setState(() {
          _selectedChannel = _channels[index];
        });
      }
    }

    if (_settings.twitchOauthToken.trim().isNotEmpty && _followedChannels.isNotEmpty) {
      final followedFutures = _followedChannels.map((c) => _apiService.fetchChannelStats(c, _settings));
      await Future.wait(followedFutures);

      for (final channel in _followedChannels) {
        final wasLive = prevFollowedLiveMap[channel.username] ?? false;
        if (channel.isLive && !wasLive && !isInitialLoad) {
          channel.wentLiveTime = DateTime.now();
        }
      }

      if (_selectedChannel != null) {
        final index = _followedChannels.indexWhere((c) => c.username == _selectedChannel!.username);
        if (index != -1) {
          setState(() {
            _selectedChannel = _followedChannels[index];
          });
        }
      }
    }

    _prefetchVodsInBackground(_channels);
    _rebuildTrayMenu();
  }

  Future<void> _addChannel(String name) async {
    final cleanName = name.toLowerCase().trim();
    if (cleanName.isEmpty) return;

    if (_channels.any((c) => c.username == cleanName)) {
      _showSnackBar('Channel "$cleanName" is already in your list.', isError: true);
      return;
    }

    setState(() => _isAdding = true);

    final newChannel = TwitchChannel(username: cleanName);
    await _apiService.fetchChannelStats(newChannel, _settings);

    if (newChannel.errorMessage != null) {
      _showSnackBar('Failed to add channel: ${newChannel.errorMessage}', isError: true);
      setState(() => _isAdding = false);
      return;
    }

    setState(() {
      _channels.add(newChannel);
      _selectedChannel = newChannel;
      _searchController.clear();
      _isAdding = false;
    });
    _seedLiveTracking(newChannel);

    await _saveChannels();
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
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Remove "${channel.username}"?',
                style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
            content: Text(
              'This channel has automation configured'
              '${existing.autoPlayLive ? '\n• Auto-play when live (priority #${existing.autoPlayPriority + 1})' : ''}'
              '${existing.autoDownloadVods ? '\n• Auto-download VODs (keep ${existing.maxVodKeepCount})' : ''}'
              '\n\nRemoving it from Favorites discards that configuration. Downloaded files are kept.',
              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel',
                    style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: NeuTheme.danger),
                onPressed: () => Navigator.pop(context, true),
                // White on the fixed danger red, theme-independent.
                child: const Text('Remove',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
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
      // This also drops the `&` -> `^&` shell escaping the cmd form needed.
      await Process.start('explorer.exe', [url], mode: ProcessStartMode.detached);
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
          style: TextStyle(
            color: isError ? Colors.white : themeNotifier.onPrimaryColor,
            fontWeight: FontWeight.w500,
          ),
        ),
        backgroundColor: isError ? NeuTheme.danger : themeNotifier.primaryColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(12),
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
      textColor: Colors.white,
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
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isDownload ? 'Cancel Download?' : 'Stop Process?',
            style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
        backgroundColor: themeNotifier.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Text(
          isDownload
              ? 'This download is still in progress. Cancelling will delete the partial file.'
              : 'This will close the player and stop playback.',
          style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Keep Running',
                style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
          ),
          ElevatedButton(
            // White on the fixed danger red, theme-independent.
            style: ElevatedButton.styleFrom(
                backgroundColor: NeuTheme.danger, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: Text(isDownload ? 'Cancel Download' : 'Stop'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _clearWatchProgress() async {
    setState(() {
      _localVodsProgress.clear();
      for (final vod in _channelVods) {
        vod.watchProgress = 0.0;
      }
    });
    await _saveChannels();
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
        setState(() {
          _settings = updatedSettings;
          _isWebTokenExpired = false;
        });
        await _saveChannels();

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
      child: Container(
        color: themeNotifier.backgroundColor,
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
      body: CallbackShortcuts(
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
            liveCount: _channels.where((c) => c.isLive).length,
            actions: [
              ActivityPill(
                activity: _activity,
                onStop: _stopActivity,
                compact: isNarrow,
              ),
              const SizedBox(width: 12),
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
          Expanded(
            child: isVertical
                ? Column(
                    children: [
                      sidebar,
                      contentArea,
                    ],
                  )
                : Row(
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
    );
  }

  Widget _buildWelcomeScreen(ThemeData theme) {
    final liveFavorites = _channels.where((c) => c.isLive).toList();
    final runningDownloads = _activity.value.downloading;

    return SingleChildScrollView(
            padding: const EdgeInsets.all(28.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title Header
                Row(
                  children: [
                    Icon(Icons.dashboard_outlined, size: 28, color: themeNotifier.accentInk),
                    const SizedBox(width: 10),
                    Text(
                      'Dashboard Hub',
                      style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 24),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Welcome back! Select a channel or choose a quick action below.',
                  style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 13),
                ),
                const SizedBox(height: 24),

          // Active Downloads card (Conditional)
          if (runningDownloads.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.primaryColor.withValues(alpha: 0.15),
                    themeNotifier.surfaceColor,
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.primaryColor.withValues(alpha: 0.3), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: theme.primaryColor.withValues(alpha: 0.05),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
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
                          const SizedBox(width: 8),
                          Text(
                            'Active Downloads Running',
                            style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 14),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: _openLibrary,
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('Open Library', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...runningDownloads.take(2).map((item) {
                    final progress = item.progress ?? 0.0;
                    final taskText = item.status ?? 'Downloading...';
                    final title = item.label;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                NeuProgressBar(
                                  value: progress,
                                  size: NeuProgressSize.sm,
                                  semanticLabel: 'Download progress',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            taskText.length > 25 ? '${taskText.substring(0, 22)}...' : taskText,
                            style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Recently Watched VODs (Conditional)
          if (_recentWatchedVods.isNotEmpty) ...[
            Text(
              'Recently Watched Past Broadcasts',
              style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 155,
              child: HorizontalMouseScrollable(
                child: Row(
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
                                  margin: const EdgeInsets.only(right: 12),
                                  decoration: NeuTheme.raisedDecoration(
                                    themeNotifier.isDarkTheme,
                                    radius: 12,
                                    border: Border.all(
                                      color: isHovered ? theme.primaryColor : Colors.transparent,
                                      width: isHovered ? 1.5 : 0.0,
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(11),
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
                                                        errorBuilder: (context, error, stackTrace) => Container(
                                                          color: NeuTheme.surface(themeNotifier.isDarkTheme),
                                                          child: Icon(Icons.movie, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 36),
                                                        ),
                                                      )
                                                    : Container(
                                                        color: NeuTheme.surface(themeNotifier.isDarkTheme),
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
                                                        padding: const EdgeInsets.all(8),
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
                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.75),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: Text(
                                                    video.duration,
                                                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
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
                                          color: NeuTheme.surface(themeNotifier.isDarkTheme),
                                          padding: const EdgeInsets.all(8),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                video.title,
                                                style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 11),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                children: [
                                                  Text(
                                                    video.publishedAt.toLocal().toString().substring(0, 10),
                                                    style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 9),
                                                  ),
                                                  if (progressPct > 0)
                                                    Text(
                                                      '$progressPct%',
                                                      style: TextStyle(fontSize: 9, color: themeNotifier.accentInk, fontWeight: FontWeight.bold),
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
            const SizedBox(height: 24),
          ],

          // Live Channels Section
          Text(
            'Live Favorite Channels',
            style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16),
          ),
          const SizedBox(height: 12),
          if (liveFavorites.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.portable_wifi_off, size: 36, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                  const SizedBox(height: 10),
                  Text(
                    _channels.isEmpty
                        ? 'Add your first channel: open the sidebar search (Ctrl+F), type a name, press Enter.'
                        : 'No favorite channels are currently live.',
                    style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
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
                    padding: const EdgeInsets.all(12),
                    decoration: NeuTheme.raisedDecoration(
                      themeNotifier.isDarkTheme,
                      radius: 12,
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
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                channel.username,
                                style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: Text(
                            channel.streamTitle ?? 'No Stream Title',
                            style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 4),
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
                                style: TextStyle(fontSize: 10, color: themeNotifier.accentInk, fontWeight: FontWeight.bold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.remove_red_eye, size: 10, color: NeuTheme.liveText(themeNotifier.isDarkTheme)),
                                const SizedBox(width: 4),
                                Text(
                                  channel.viewerCount != null ? '${channel.viewerCount}' : '0',
                                  style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 10, fontWeight: FontWeight.bold),
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
          const SizedBox(height: 32),

          // Quick Action Cards
          Text(
            'Quick Action Control Room',
            style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16),
          ),
          const SizedBox(height: 12),
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: NeuTheme.danger.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              size: 16, color: NeuTheme.dangerText(isDark)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Your settings could not be saved to disk. Recent changes may be '
              'lost when the app closes.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: NeuTheme.dangerText(isDark),
              ),
            ),
          ),
          TextButton(
            onPressed: () => _showSaveFailureDetail(failure),
            child: const Text('Details', style: TextStyle(fontSize: 11)),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 14, color: NeuTheme.subtext(isDark)),
            tooltip: 'Dismiss',
            onPressed: () => setState(() => _saveWarningDismissed = true),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
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
              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: NeuTheme.sunkenDecoration(
                  themeNotifier.isDarkTheme,
                  radius: 8),
              child: SelectableText(
                '${failure.path}\n\n${failure.error}',
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
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
    _playVod(video, entry.channel);
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
          style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
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
    await _deleteDownloadedVod(entry.vodId, entry.channel);
    _refreshLibraryEntries();
  }

  Future<void> _removeLibraryEntryFromHistory(LibraryEntry entry) async {
    setState(() {
      _recentWatchedVods.removeWhere((v) => v.id == entry.vodId);
      _localVodsProgress.remove(entry.vodId);
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
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              transform: Matrix4.translationValues(0, isHovered ? -2 : 0, 0),
              padding: const EdgeInsets.all(12),
              decoration: NeuTheme.raisedDecoration(
                themeNotifier.isDarkTheme,
                radius: 12,
                border: Border.all(
                  color: isHovered ? theme.primaryColor : Colors.transparent,
                  width: isHovered ? 1.5 : 0.0,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 20, color: themeNotifier.accentInk),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 10),
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
    final layout = AppLayout.of(context);
    final isSmall = !layout.hasWideControls;
    final isCompact = layout.isRail;
    // CustomScrollView so the VOD grid renders as a real SliverGrid and
    // off-screen cards are culled; the old SingleChildScrollView +
    // shrinkWrap GridView materialized every card at once.
    return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.all(isCompact ? 12 : 24),
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
                  onRefresh: () => _apiService.fetchChannelStats(channel, _settings).then((_) {
                    if (mounted) setState(() {});
                  }),
                  openExternalLink: _openExternalLink,
                )),

                // VOD section (if OAuth token present)
                if (_settings.twitchOauthToken.trim().isNotEmpty) ...[
                  SliverToBoxAdapter(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  SizedBox(height: isCompact ? 12 : 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Expanded + Wrap, not a bare Row. In multi-select this
                      // cluster carries four labelled buttons, a count and two
                      // icon buttons with no compact branch anywhere, so below
                      // roughly 1100px it simply overflowed. Wrapping to a
                      // second line is the honest minimum; the toolbar is
                      // rebuilt properly as a SelectionBar in a later phase.
                      Expanded(
                        child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          IconButton(
                            icon: Icon(
                              _isMultiSelectMode ? Icons.edit_off : Icons.edit,
                              color: _isMultiSelectMode ? themeNotifier.accentInk : NeuTheme.text(themeNotifier.isDarkTheme),
                              size: 18,
                            ),
                            tooltip: _isMultiSelectMode ? 'Cancel Multi-Select' : 'Toggle Multi-Select Mode',
                            onPressed: () {
                              setState(() {
                                _isMultiSelectMode = !_isMultiSelectMode;
                                _selectedVodIds.clear();
                              });
                            },
                          ),
                          if (_isMultiSelectMode) ...[
                                                        Text(
                              '${_selectedVodIds.length} selected',
                              style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 12),
                            ),
                            if (_isBulkUpdatingVods) ...[
                                                            NeuProgressRing(
                                size: NeuProgressRingSize.xs,
                                color: NeuTheme.text(themeNotifier.isDarkTheme),
                                semanticLabel: 'Syncing',
                              ),
                                                            Text('Syncing with Twitch...', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                            ] else ...[
                                                            TextButton.icon(
                                icon: const Icon(Icons.check_circle_outline, size: 16),
                                label: const Text('Mark Watched', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: theme.primaryColor.withValues(alpha: 0.2),
                                  foregroundColor: themeNotifier.accentInk,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: () => _bulkUpdateSelectedVods(true),
                              ),
                                                            TextButton.icon(
                                icon: const Icon(Icons.unpublished_outlined, size: 16),
                                label: const Text('Mark Unwatched', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: NeuTheme.border(themeNotifier.isDarkTheme),
                                  foregroundColor: NeuTheme.text(themeNotifier.isDarkTheme),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: () => _bulkUpdateSelectedVods(false),
                              ),
                                                            TextButton.icon(
                                icon: const Icon(Icons.download, size: 16),
                                label: const Text('Download', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: NeuTheme.live.withValues(alpha: 0.15),
                                  foregroundColor: NeuTheme.liveText(themeNotifier.isDarkTheme),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: _selectedVodIds.isEmpty ? null : _bulkDownloadSelectedVods,
                              ),
                                                            TextButton.icon(
                                icon: const Icon(Icons.delete_outline, size: 16),
                                label: const Text('Delete Download', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: NeuTheme.danger.withValues(alpha: 0.15),
                                  foregroundColor: NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: _selectedVodIds.isEmpty ? null : _bulkDeleteSelectedVods,
                              ),
                                                            IconButton(
                                icon: Icon(Icons.select_all, size: 18, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                                tooltip: 'Select All Visible',
                                onPressed: () {
                                  final searchQuery = _vodSearchController.text.trim().toLowerCase();
                                  final filteredVods = _channelVods.where((vod) {
                                    final matchesSearch = searchQuery.isEmpty ||
                                        vod.title.toLowerCase().contains(searchQuery) ||
                                        vod.games.any((game) => game.toLowerCase().contains(searchQuery));
                                    final matchesGameFilter = _selectedGamesFilter.isEmpty ||
                                        vod.games.any((game) => _selectedGamesFilter.contains(game));
                                    return matchesSearch && matchesGameFilter;
                                  }).toList();
                                  setState(() {
                                    _selectedVodIds.addAll(filteredVods.map((v) => v.id));
                                  });
                                },
                              ),
                              IconButton(
                                icon: Icon(Icons.deselect, size: 18, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                                tooltip: 'Deselect All',
                                onPressed: () {
                                  setState(() {
                                    _selectedVodIds.clear();
                                  });
                                },
                              ),
                            ],
                          ],
                        ],
                      ),
                      ),
                      if (!_isMultiSelectMode)
                        isSmall
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  InteractivePopover(
                                    popover: _buildVodsSettingMenu(theme),
                                    child: _VodSettingsHoverButton(theme: theme),
                                  ),
                                ],
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Tooltip(
                                    message: 'Show all played games on thumbnails at a glance',
                                    decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 6),
                                    textStyle: TextStyle(color: NeuTheme.text(themeNotifier.isDarkTheme), fontSize: 10, fontWeight: FontWeight.bold),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.sports_esports, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                        const SizedBox(width: 4),
                                        Text('Show All Games', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                                        const SizedBox(width: 8),
                                        NeuSwitch(
                                          value: _settings.showGamesOnThumbnails,
                                          onChanged: (val) {
                                            setState(() {
                                              _settings.showGamesOnThumbnails = val;
                                            });
                                            _saveChannels();
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 160,
                                    child: NeuTextField(
                                      controller: _vodSearchController,
                                      hintText: 'Filter VODs...',
                                      prefixIcon: Icons.search,
                                      size: NeuFieldSize.sm,
                                      onChanged: (val) => setState(() {}),
                                      onClear: () => setState(() {}),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Icon(Icons.photo_size_select_large, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                  const SizedBox(width: 6),
                                  Text('Card Size: ', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                  SizedBox(
                                    width: 110,
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
                                  const SizedBox(width: 14),
                                  Icon(Icons.format_size, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                  const SizedBox(width: 6),
                                  Text('Font: ', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                  SizedBox(
                                    width: 90,
                                    child: SliderTheme(
                                      data: neuSliderTheme(context),
                                      child: Slider(
                                        value: _settings.vodTitleFontSize,
                                        min: 11.0,
                                        max: 20.0,
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
                      if (_isLoadingVods) ...[
                        const SizedBox(width: 12),
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: NeuProgressRing(size: NeuProgressRingSize.sm, semanticLabel: 'Loading'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_isWebTokenExpired) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      // Intentional: translucent warning tint, readable over both themes.
                      decoration: BoxDecoration(
                        color: NeuTheme.warning.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: NeuTheme.warning.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: NeuTheme.warningText(themeNotifier.isDarkTheme), size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Your Twitch Browser OAuth Token has expired. VOD watch progress tracking is currently paused.',
                              style: TextStyle(color: NeuTheme.text(themeNotifier.isDarkTheme), fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 12),
                          TextButton(
                            style: TextButton.styleFrom(
                              backgroundColor: NeuTheme.warning.withValues(alpha: 0.2),
                              foregroundColor: NeuTheme.warningText(themeNotifier.isDarkTheme),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            onPressed: _showSettingsDialog,
                            child: const Text('Update Token', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: Icon(Icons.close, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 16),
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
                    const SizedBox(height: 24),
                    Center(
                      child: SizedBox(
                        width: 180,
                        height: 40,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                            foregroundColor: NeuTheme.text(themeNotifier.isDarkTheme),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme)),
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
                                    SizedBox(width: 6),
                                    Text('Load More VODs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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

  Widget _buildVodsSettingMenu(ThemeData theme) {
    return Container(
      width: 320,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      padding: const EdgeInsets.all(16),
      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 12),
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
                        const SizedBox(width: 6),
                        Text('Show All Games on Thumbnails', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 11)),
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
            const SizedBox(height: 12),
            Text('Filter Broadcasts:', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            NeuTextField(
              controller: _vodSearchController,
              hintText: 'Filter VODs...',
              prefixIcon: Icons.search,
              size: NeuFieldSize.md,
              onChanged: (val) => setState(() {}),
              onClear: () => setState(() {}),
            ),
            const SizedBox(height: 12),
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
                        Text('Filter by Games:', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11, fontWeight: FontWeight.bold)),
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
                                style: TextStyle(fontSize: 10, color: themeNotifier.accentInk, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 6),
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
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
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      game,
                                      style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 11),
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
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.photo_size_select_large, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                const SizedBox(width: 6),
                Text('Card Size: ', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 12)),
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
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.format_size, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                const SizedBox(width: 6),
                Text('Font Size: ', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                Expanded(
                  child: SliderTheme(
                    data: neuSliderTheme(context),
                    child: Slider(
                      value: _settings.vodTitleFontSize,
                      min: 11.0,
                      max: 20.0,
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
      final totalSeconds = _apiService.parseDurationToSeconds(vod.duration);
      if (totalSeconds > 0) {
        vod.watchProgress = localPos / totalSeconds;
      }
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

    launch.catchError((Object e) {
      _activePlayingVideos.remove(vod.id);
      if (mounted) {
        _showSnackBar('Could not start playback: $e', isError: true);
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
    String? chosenOrder = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.download_for_offline, color: NeuTheme.liveText(themeNotifier.isDarkTheme)),
              const SizedBox(width: 10),
              const Text('Download Queue Order'),
            ],
          ),
          backgroundColor: themeNotifier.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('You have selected ${selectedVods.length} VODs to download.'),
              const SizedBox(height: 12),
              Text('Please select how the download order should be processed:', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.arrow_downward, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                title: Text('Newest First', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                subtitle: Text('Downloads the latest broadcasts sequentially', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                onTap: () => Navigator.pop(context, 'newest'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.arrow_upward, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                title: Text('Oldest First', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                subtitle: Text('Downloads the oldest broadcasts sequentially', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
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
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
            ),
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
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Delete ${toDelete.length} VOD Downloads?'),
          backgroundColor: themeNotifier.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Are you sure you want to delete the downloaded files on disk for the following videos? This cannot be undone.',
                  style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 8),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: toDelete.length,
                    itemBuilder: (context, index) {
                      return ListTile(
                        dense: true,
                        title: Text(
                          toDelete[index].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: NeuTheme.danger),
              onPressed: () => Navigator.pop(context, true),
              // White on the fixed danger red, theme-independent.
              child: const Text('Delete Files', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
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

class _VodSettingsHoverButton extends StatefulWidget {
  final ThemeData theme;
  const _VodSettingsHoverButton({Key? key, required this.theme}) : super(key: key);

  @override
  State<_VodSettingsHoverButton> createState() => _VodSettingsHoverButtonState();
}

class _VodSettingsHoverButtonState extends State<_VodSettingsHoverButton> {
  bool isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: isHovered
            ? NeuTheme.raisedDecoration(
                themeNotifier.isDarkTheme,
                radius: 6,
                border: Border.all(color: themeNotifier.accentInk, width: 1.5),
              )
            : NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tune,
              color: isHovered ? themeNotifier.accentInk : NeuTheme.text(themeNotifier.isDarkTheme),
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              'VOD Settings',
              style: TextStyle(
                color: isHovered ? themeNotifier.accentInk : NeuTheme.text(themeNotifier.isDarkTheme),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
