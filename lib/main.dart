import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
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
import 'widgets/console_panel.dart';
import 'widgets/sidebar_panel.dart';
import 'widgets/dashboard_header.dart';
import 'widgets/vods_grid.dart';
import 'widgets/settings_dialog.dart';
import 'widgets/hover_overlay_menu.dart';
import 'widgets/interactive_popover.dart';
import 'utils/color_utils.dart';
import 'utils/process_monitor.dart';

class AppThemeNotifier extends ChangeNotifier implements ThemeUpdateListener {
  Color primaryColor = const Color(0xFF9146FF);
  Color backgroundColor = const Color(0xFF0C0F17);
  Color surfaceColor = const Color(0xFF161B26);
  Color activeProgressColor = const Color(0xFF9146FF);
  Color watchedProgressColor = const Color(0x804CAF50); // transparent green

  @override
  void updateTheme({
    Color? primary,
    Color? background,
    Color? surface,
    Color? activeProgress,
    Color? watchedProgress,
  }) {
    if (primary != null) primaryColor = primary;
    if (background != null) backgroundColor = background;
    if (surface != null) surfaceColor = surface;
    if (activeProgress != null) activeProgressColor = activeProgress;
    if (watchedProgress != null) watchedProgressColor = watchedProgress;
    notifyListeners();
  }
}

final AppThemeNotifier themeNotifier = AppThemeNotifier();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await localNotifier.setup(
    appName: 'Twitch Streamlink GUI',
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );

  await windowManager.ensureInitialized();

  final config = await StorageService().loadConfig();
  AppSettings settings = AppSettings();
  if (config != null && config['settings'] is Map<String, dynamic>) {
    settings = AppSettings.fromJson(config['settings']);
  }

  final bool shouldCenter = settings.windowX == null || settings.windowY == null;

  WindowOptions windowOptions = WindowOptions(
    size: Size(settings.windowWidth, settings.windowHeight),
    center: shouldCenter,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (!shouldCenter) {
      await windowManager.setPosition(Offset(settings.windowX!, settings.windowY!));
    }
    if (settings.isWindowMaximized) {
      await windowManager.maximize();
    }
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(380, 500));
  });

  runApp(const TwitchStreamlinkApp());
}

class TwitchStreamlinkApp extends StatelessWidget {
  const TwitchStreamlinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeNotifier,
      builder: (context, _) {
        return MaterialApp(
          title: 'Twitch Streamlink GUI',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'Segoe UI',
            scaffoldBackgroundColor: themeNotifier.backgroundColor,
            primaryColor: themeNotifier.primaryColor,
            colorScheme: ColorScheme.dark(
              primary: themeNotifier.primaryColor,
              secondary: const Color(0xFF00F2FE), // Cyan Accent
              surface: themeNotifier.surfaceColor,
              background: themeNotifier.backgroundColor,
              error: const Color(0xFFFF4D4D),
            ),
            cardTheme: CardThemeData(
              color: themeNotifier.surfaceColor,
              elevation: 4,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
            textTheme: const TextTheme(
              titleLarge: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              bodyLarge: TextStyle(color: Color(0xFFE2E8F0)),
              bodyMedium: TextStyle(color: Color(0xFF94A3B8)),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFF1F2937),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                borderSide: BorderSide(color: themeNotifier.primaryColor, width: 1.5),
              ),
              hintStyle: const TextStyle(color: Colors.white38),
            ),
            scrollbarTheme: ScrollbarThemeData(
              thumbColor: MaterialStateProperty.resolveWith((states) {
                if (states.contains(MaterialState.hovered)) {
                  return themeNotifier.primaryColor.withOpacity(0.5);
                }
                return themeNotifier.primaryColor.withOpacity(0.2);
              }),
              trackColor: MaterialStateProperty.all(Colors.transparent),
              thickness: MaterialStateProperty.all(6.0),
              radius: const Radius.circular(8.0),
              thumbVisibility: MaterialStateProperty.all(false),
              interactive: true,
            ),
          ),
          home: const MainScreen(),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin, WindowListener {
  // Services
  final StorageService _storageService = StorageService();
  final TwitchApiService _apiService = TwitchApiService();
  final PlayerService _playerService = PlayerService();

  // Logging and Console State
  final LogNotifier _logNotifier = LogNotifier();

  // UI state variables
  final List<TwitchChannel> _channels = [];
  TwitchChannel? _selectedChannel;
  bool _isGlobalLoading = false;
  final TextEditingController _searchController = TextEditingController();
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
  double _vodScale = 350.0;
  double _vodTitleFontSize = 14.0;

  final TextEditingController _vodSearchController = TextEditingController();
  AnimationController? _pulseController;
  bool _sidebarCollapsed = false;
  String? _vodPaginationCursor;
  bool _showGamesOnThumbnails = true;
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

  bool _consoleCollapsed = true;
  String? _selectedConsoleTabKey = '__downloads_manager__';

  @override
  void initState() {
    super.initState();
    startProcessMonitor();
    windowManager.addListener(this);
    _initSystemTray();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    // Initialize player service archive path and listener hooks
    _playerService.downloadArchiveFilePath = _storageService.getStorageFile('yt_dlp_archive.txt').path;
    _playerService.onPlayerLog = (key, line) {
      _logNotifier.appendLog(key, line);
    };

    _playerService.onPlayerStarted = (key, title) {
      if (mounted) {
        setState(() {
          _selectedConsoleTabKey = key;
          _consoleCollapsed = false;
        });
      }
    };

    _playerService.onPlayerStopped = (key, exitCode) {
      if (mounted) {
        setState(() {});
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
      if (mounted) {
        setState(() {});
      }
    };

    _playerService.onDownloadCancelled = (vodId) {
      if (mounted) {
        setState(() {});
        _showSnackBar('Download cancelled.', isError: true);
      }
    };

    _playerService.onDownloadCompleted = (vodId, title, filePath) {
      if (mounted) {
        setState(() {
          if (filePath.isNotEmpty) {
            _downloadedVodsRegistry[vodId] = filePath;
          }
        });
        _checkDownloadedVods();
        _saveChannels();
        _showSnackBar('Download completed: $title', isError: false);
      }
    };

    _playerService.onDownloadFailed = (vodId, title, exitCode) {
      if (mounted) {
        setState(() {});
        _showSnackBar('Download failed for: $title (Exit code $exitCode)', isError: true);
      }
    };

    _loadChannels();
    
    _downloadCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkDownloadedVods();
    });
    
    _favoritesLiveCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _refreshAllChannels();
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _vodSearchController.dispose();
    _pulseController?.dispose();
    _playerService.stopAll();
    _searchController.dispose();
    _oauthServer?.close(force: true);
    _downloadCheckTimer?.cancel();
    _favoritesLiveCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _initSystemTray() async {
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Show App', onClicked: (menuItem) => windowManager.show()),
      MenuItemLabel(label: 'Hide App', onClicked: (menuItem) => windowManager.hide()),
      MenuSeparator(),
      MenuItemLabel(label: 'Exit', onClicked: (menuItem) => _handleAppExitRequest()),
    ]);

    await _systemTray.initSystemTray(
      title: "Twitch Streamlink GUI",
      iconPath: 'assets/app_icon.ico',
      toolTip: "Twitch Streamlink GUI",
    );
    await _systemTray.setContextMenu(menu);

    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick || eventName == kSystemTrayEventDoubleClick) {
        windowManager.show();
        windowManager.focus();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });
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
            title: const Text('Exit Twitch Streamlink GUI?'),
            content: const Text(
              'There are VOD downloads currently in progress or queued. '
              'If you exit, they will be paused and resumed the next time you start the app.\n\n'
              'Do you want to exit now?'
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
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

      final unfinishedList = <Map<String, dynamic>>[];
      
      for (final vodId in _playerService.activeDownloadProcesses.keys) {
        final task = _playerService.queuedDownloadTasks[vodId];
        if (task != null) {
          unfinishedList.add({
            'vod': task.toJson(),
            'channelName': _selectedChannel?.username ?? 'VOD',
          });
        }
      }
      
      for (final vodId in _playerService.downloadQueue) {
        final task = _playerService.queuedDownloadTasks[vodId];
        if (task != null) {
          unfinishedList.add({
            'vod': task.toJson(),
            'channelName': _selectedChannel?.username ?? 'VOD',
          });
        }
      }

      setState(() {
        _settings.unfinishedDownloads = unfinishedList;
      });
      await _saveChannels();
    }

    _playerService.stopAll();
    await windowManager.destroy();
  }

  Future<void> _saveWindowState() async {
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
    if (isPreventClose) {
      await windowManager.hide();
    }
  }

  @override
  void onWindowMinimize() async {
    await windowManager.hide();
  }

  void _checkDownloadedVods() {
    if (_settings.vodDownloadFolder.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _downloadedVodIds.clear();
        });
      }
      return;
    }
    
    final newDownloaded = <String>{};
    bool registryChanged = false;

    // 1. Validate all files in the registry
    _downloadedVodsRegistry.forEach((vodId, filePath) {
      if (_playerService.activeDownloadTasks.containsKey(vodId) ||
          _playerService.activeDownloadProcesses.containsKey(vodId) ||
          _playerService.downloadQueue.contains(vodId)) {
        return;
      }

      if (File(filePath).existsSync()) {
        newDownloaded.add(vodId);
      } else {
        registryChanged = true;
        _playerService.removeVodFromArchive(vodId);
      }
    });

    if (registryChanged) {
      _downloadedVodsRegistry.removeWhere((vodId, filePath) => !File(filePath).existsSync());
    }
    
    // 2. Scan the current channel's VODs and pick up newly found downloads
    for (final vod in _channelVods) {
      if (newDownloaded.contains(vod.id)) continue;
      
      if (_playerService.activeDownloadTasks.containsKey(vod.id) ||
          _playerService.activeDownloadProcesses.containsKey(vod.id) ||
          _playerService.downloadQueue.contains(vod.id)) {
        continue;
      }
      
      final file = _playerService.getDownloadedVodFile(
        vod.id,
        _selectedChannel?.username ?? '',
        _settings.vodDownloadFolder
      );
      if (file != null && file.existsSync()) {
        newDownloaded.add(vod.id);
        _downloadedVodsRegistry[vod.id] = file.path;
        registryChanged = true;
      }
    }

    if (registryChanged) {
      _saveChannels();
    }
    
    if (mounted) {
      setState(() {
        _downloadedVodIds = newDownloaded;
      });
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
          title: const Row(
            children: [
              Icon(Icons.folder_copy, color: Colors.orangeAccent),
              SizedBox(width: 10),
              Text('Configure Download Folder'),
            ],
          ),
          backgroundColor: themeNotifier.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: const Text(
            'A VOD download folder has not been configured yet.\n\nWould you like to select a folder now to proceed with your download?',
            style: TextStyle(height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white30)),
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
              child: const Text('Browse & Set Folder', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
      List<String> usernames = [];

      if (config != null) {
        final channelsJson = config['channels'];
        if (channelsJson is List) {
          usernames = channelsJson.map((item) => item.toString()).toList();
        }
        final settingsJson = config['settings'];
        if (settingsJson is Map<String, dynamic>) {
          setState(() {
            _settings = AppSettings.fromJson(settingsJson);
            _sidebarCollapsed = _settings.sidebarCollapsed;
            _sidebarTab = _settings.activeSidebarTab;
            _showGamesOnThumbnails = _settings.showGamesOnThumbnails;
             
            if (_settings.unfinishedDownloads.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _resumeUnfinishedDownloads();
              });
            }
            
            themeNotifier.updateTheme(
              primary: parseHexColor(_settings.primaryColorHex, const Color(0xFF9146FF)),
              background: parseHexColor(_settings.backgroundColorHex, const Color(0xFF0C0F17)),
              surface: parseHexColor(_settings.surfaceColorHex, const Color(0xFF161B26)),
              activeProgress: parseHexColor(_settings.activeProgressColorHex, const Color(0xFF9146FF)),
              watchedProgress: parseHexColor(_settings.watchedProgressColorHex, const Color(0x804CAF50)),
            );
          });
        }
        final localProgressJson = config['local_vods_progress'];
        if (localProgressJson is Map) {
          _localVodsProgress = localProgressJson.map((k, v) => MapEntry(k.toString(), v as int));
        }
        final downloadedVodsJson = config['downloaded_vods'];
        if (downloadedVodsJson is Map) {
          _downloadedVodsRegistry = downloadedVodsJson.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      }

      _channels.clear();
      if (usernames.isNotEmpty) {
        for (var str in usernames) {
          final channel = TwitchChannel(username: str.toLowerCase().trim());
          _channels.add(channel);
        }
      } else {
        final defaults = ['limmy'];
        for (var name in defaults) {
          _channels.add(TwitchChannel(username: name));
        }
        await _saveChannels();
      }

      await _refreshAllChannels(isInitialLoad: true);
      if (_settings.twitchOauthToken.trim().isNotEmpty) {
        _loadFollowedChannels();
      }
      final recents = await _storageService.loadRecentWatchedVods();
      if (mounted) {
        setState(() {
          _recentWatchedVods = recents.map((json) => TwitchVideo.fromJson(json)).toList();
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

  Future<void> _fetchVodsForChannel(TwitchChannel channel, {bool loadMore = false}) async {
    setState(() {
      _isLoadingVods = true;
      _vodsError = null;
      if (!loadMore) {
        _channelVods = [];
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

      setState(() {
        _vodPaginationCursor = result.nextCursor;
        _isWebTokenExpired = result.isWebTokenExpired;
        if (loadMore) {
          _channelVods.addAll(result.vods);
        } else {
          _channelVods = result.vods;
        }
      });
      _checkDownloadedVods();
      await _saveChannels();
    } catch (e) {
      setState(() {
        _vodsError = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      setState(() {
        _isLoadingVods = false;
      });
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
          if (!isInitialLoad) {
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
                
                setState(() {
                  _selectedChannel = channel;
                });
                _fetchVodsForChannel(channel);

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

    await _saveChannels();
    _showSnackBar('Channel "$cleanName" added successfully!', isError: false);
  }

  Future<void> _toggleFavorite(TwitchChannel channel) async {
    final cleanName = channel.username.toLowerCase().trim();
    final isFavorite = _channels.any((c) => c.username == cleanName);
    
    if (isFavorite) {
      setState(() {
        _channels.removeWhere((c) => c.username == cleanName);
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
      await _saveChannels();
      _showSnackBar('Added "${channel.username}" to Favorites.', isError: false);
      
      _apiService.fetchChannelStats(newFav, _settings).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _bulkUpdateSelectedVods(bool markAsWatched) async {
    final webToken = _settings.twitchWebOauthToken.trim();
    if (webToken.isEmpty) {
      _showSnackBar('Twitch Browser Token is required in Settings to sync watch progress.', isError: true);
      return;
    }

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

      try {
        _apiService.syncSingleVODProgressDirect(videoId, targetPosition, webToken).catchError((_) {});
      } catch (_) {}
    }

    setState(() {
      _isBulkUpdatingVods = false;
      _isMultiSelectMode = false;
      _selectedVodIds.clear();
    });

    if (successCount > 0) {
      await _saveChannels();
      _showSnackBar(
        'Successfully updated $successCount VODs locally! Note: Twitch blocks third-party watch history syncing on their website.',
        isError: false,
      );
    }
  }

  Future<void> _openExternalLink(String url) async {
    try {
      if (Platform.isWindows) {
        final escapedUrl = url.replaceAll('&', '^&');
        await Process.run('cmd', ['/c', 'start', '""', escapedUrl], runInShell: false);
      } else {
        _showSnackBar('Unsupported platform for launching external link', isError: true);
      }
    } catch (e) {
      _showSnackBar('Failed to open link: $e', isError: true);
    }
  }

  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        ),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF9146FF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(12),
      ),
    );
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

  void _showSettingsDialog() {
    SettingsDialog.show(
      context,
      settings: _settings,
      themeNotifier: themeNotifier,
      authenticatedUserLogin: _authenticatedUserLogin,
      onConnectAccount: _startOAuthServer,
      openExternalLink: _openExternalLink,
      onClearWatchHistory: _clearWatchProgress,
      onSave: (updatedSettings) async {
        setState(() {
          _settings = updatedSettings;
          _isWebTokenExpired = false;
        });
        await _saveChannels();

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
    );
  }

  Widget _buildLivePreviewPopup(TwitchChannel channel) {
    final cleanName = channel.username.toLowerCase().trim();
    final cacheBuster = DateTime.now().millisecondsSinceEpoch ~/ 10000;
    final thumbUrl = 'https://static-cdn.jtvnw.net/previews-ttv/live_user_$cleanName-320x180.jpg?t=$cacheBuster';
    
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: const Color(0xFF161B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E2433)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 15,
            spreadRadius: 2,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                thumbUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: const Color(0xFF1F2937),
                    child: const Center(
                      child: Icon(Icons.live_tv, color: Colors.white24, size: 36),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        channel.username,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (channel.viewerCount != null && channel.viewerCount != '0') ...[
                      const Icon(Icons.remove_red_eye, color: Colors.white54, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        channel.viewerCount!,
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  channel.streamTitle ?? 'Streaming Live!',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
                if (channel.game != null && channel.game != 'Offline') ...[
                  const SizedBox(height: 6),
                  Text(
                    channel.game!,
                    style: const TextStyle(
                      color: Color(0xFF9146FF),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final isVertical = mediaQuery.size.height > mediaQuery.size.width;
    final isNarrow = mediaQuery.size.width < 700;
    final effectiveSidebarCollapsed = (isNarrow || isVertical) ? true : _sidebarCollapsed;
    
    final sidebar = SidebarPanel(
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
      onChannelSelected: (channel) {
        setState(() {
          _selectedChannel = channel;
          _channelVods.clear();
          _selectedGamesFilter.clear();
          _vodsError = null;
        });
        if (_settings.twitchOauthToken.trim().isNotEmpty) {
          _fetchVodsForChannel(channel);
        }
      },
      onChannelDoubleTapped: (username) {
        if (_playerService.runningChannels.contains(username)) return;
        _playerService.launchStreamlinkForLive(
          username,
          _selectedChannel?.isLive ?? false,
          _selectedChannel?.streamTitle,
          _selectedChannel?.game,
          _settings
        );
      },
      onAddChannel: _addChannel,
      onToggleFavorite: _toggleFavorite,
      onToggleCollapse: (collapsed) {
        setState(() {
          _sidebarCollapsed = collapsed;
          _settings.sidebarCollapsed = collapsed;
        });
        _saveChannels();
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
      buildLivePreviewPopup: _buildLivePreviewPopup,
    );

    final contentArea = Expanded(
      child: Container(
        color: const Color(0xFF0C0F17),
        child: _selectedChannel == null
            ? _buildWelcomeScreen(theme)
            : _buildDashboard(theme, _selectedChannel!),
      ),
    );

    return Scaffold(
      body: isVertical
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
    );
  }

  Widget _buildWelcomeScreen(ThemeData theme) {
    final liveFavorites = _channels.where((c) => c.isLive).toList();
    final activeDownloads = _playerService.activeDownloadTasks;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title Header
          Row(
            children: [
              Icon(Icons.dashboard_outlined, size: 28, color: theme.primaryColor),
              const SizedBox(width: 10),
              const Text(
                'Dashboard Hub',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Welcome back! Select a channel or choose a quick action below.',
            style: TextStyle(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 24),

          // Active Downloads card (Conditional)
          if (activeDownloads.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.primaryColor.withOpacity(0.15),
                    const Color(0xFF161B26),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.primaryColor.withOpacity(0.3), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: theme.primaryColor.withOpacity(0.05),
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
                          Icon(Icons.downloading, color: theme.primaryColor, size: 20),
                          const SizedBox(width: 8),
                          const Text(
                            'Active Downloads Running',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _selectedConsoleTabKey = '__downloads_manager__';
                            _consoleCollapsed = false;
                          });
                        },
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: const Text('Open Downloads Manager', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ...activeDownloads.keys.take(2).map((vodId) {
                    final progress = _playerService.activeDownloadsProgress[vodId] ?? 0.0;
                    final taskText = activeDownloads[vodId] ?? 'Downloading...';
                    final title = _playerService.downloadTitles[vodId] ?? 'VOD $vodId';
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
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                LinearProgressIndicator(
                                  value: progress,
                                  backgroundColor: Colors.white10,
                                  valueColor: AlwaysStoppedAnimation<Color>(theme.primaryColor),
                                  minHeight: 3,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            taskText.length > 25 ? '${taskText.substring(0, 22)}...' : taskText,
                            style: const TextStyle(fontSize: 11, color: Colors.white54, fontFamily: 'Consolas'),
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
            const Text(
              'Recently Watched Past Broadcasts',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 155,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _recentWatchedVods.length,
                itemBuilder: (context, index) {
                  final video = _recentWatchedVods[index];
                  final w = 240;
                  final h = 135;
                  final thumbUrl = video.thumbnailUrl.isNotEmpty
                      ? video.thumbnailUrl.replaceAll('%{width}', w.toString()).replaceAll('%{height}', h.toString())
                      : null;
                  
                  return GestureDetector(
                    onTap: () => _playVod(video, 'VOD'),
                    child: Container(
                      width: 200,
                      margin: const EdgeInsets.only(right: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B26),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
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
                                              color: const Color(0xFF1F2937),
                                              child: const Icon(Icons.movie, color: Colors.white24, size: 36),
                                            ),
                                          )
                                        : Container(
                                            color: const Color(0xFF1F2937),
                                            child: const Icon(Icons.movie, color: Colors.white24, size: 36),
                                          ),
                                  ),
                                  Positioned(
                                    bottom: 4,
                                    right: 6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.75),
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
                                        color: Colors.black45,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: FractionallySizedBox(
                                            widthFactor: video.watchProgress!.clamp(0.0, 1.0),
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
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    video.title,
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    video.publishedAt.toLocal().toString().substring(0, 10),
                                    style: const TextStyle(fontSize: 9, color: Colors.white38),
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
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Live Channels Section
          const Text(
            'Live Favorite Channels',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          if (liveFavorites.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF161B26),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.portable_wifi_off, size: 36, color: Colors.white30),
                  SizedBox(height: 10),
                  Text(
                    'No favorite channels are currently live.',
                    style: TextStyle(fontSize: 13, color: Colors.white30),
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
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedChannel = channel;
                      _fetchVodsForChannel(channel);
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161B26),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.primaryColor.withOpacity(0.2)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        )
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(
                              radius: 18,
                              backgroundImage: channel.avatarUrl != null && channel.avatarUrl!.isNotEmpty
                                  ? NetworkImage(channel.avatarUrl!)
                                  : null,
                              backgroundColor: Colors.transparent,
                              child: channel.avatarUrl == null || channel.avatarUrl!.isEmpty
                                  ? const Icon(Icons.person, size: 18)
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                channel.username,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
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
                            style: const TextStyle(fontSize: 11, color: Colors.white54),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              channel.game ?? 'Unknown Game',
                              style: TextStyle(fontSize: 10, color: theme.primaryColor, fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Row(
                              children: [
                                const Icon(Icons.remove_red_eye, size: 10, color: Colors.redAccent),
                                const SizedBox(width: 4),
                                Text(
                                  channel.viewerCount != null ? '${channel.viewerCount}' : '0',
                                  style: const TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 32),

          // Quick Action Cards
          const Text(
            'Quick Action Control Room',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70),
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
              _buildQuickActionCard(
                context: context,
                theme: theme,
                icon: Icons.terminal,
                title: 'Toggle Console Logs',
                subtitle: 'View live process output',
                onTap: () {
                  setState(() {
                    _consoleCollapsed = !_consoleCollapsed;
                  });
                },
              ),
            ],
          ),
        ],
      ),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF161B26),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 20, color: theme.primaryColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboard(ThemeData theme, TwitchChannel channel) {
    final isSmall = MediaQuery.of(context).size.width < 1180;
    final isCompact = MediaQuery.of(context).size.width < 700 || MediaQuery.of(context).size.height > MediaQuery.of(context).size.width;
    return Column(
      children: [
        // Main Dashboard Body
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(isCompact ? 12 : 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Real-time Stats Card Widget
                DashboardHeader(
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
                ),
                
                // VOD section (if OAuth token present)
                if (_settings.twitchOauthToken.trim().isNotEmpty) ...[
                  SizedBox(height: isCompact ? 12 : 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              _isMultiSelectMode ? Icons.edit_off : Icons.edit,
                              color: _isMultiSelectMode ? theme.primaryColor : Colors.white70,
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
                            const SizedBox(width: 8),
                            Text(
                              '${_selectedVodIds.length} selected',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70),
                            ),
                            if (_isBulkUpdatingVods) ...[
                              const SizedBox(width: 12),
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                              ),
                              const SizedBox(width: 8),
                              const Text('Syncing with Twitch...', style: TextStyle(fontSize: 11, color: Colors.white60)),
                            ] else ...[
                              const SizedBox(width: 12),
                              TextButton.icon(
                                icon: const Icon(Icons.check_circle_outline, size: 16),
                                label: const Text('Mark Watched', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: theme.primaryColor.withOpacity(0.2),
                                  foregroundColor: theme.primaryColor,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: () => _bulkUpdateSelectedVods(true),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                icon: const Icon(Icons.unpublished_outlined, size: 16),
                                label: const Text('Mark Unwatched', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: Colors.white10,
                                  foregroundColor: Colors.white70,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: () => _bulkUpdateSelectedVods(false),
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                icon: const Icon(Icons.download, size: 16),
                                label: const Text('Download', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: Colors.green.withOpacity(0.2),
                                  foregroundColor: Colors.greenAccent,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: _selectedVodIds.isEmpty ? null : _bulkDownloadSelectedVods,
                              ),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                icon: const Icon(Icons.delete_outline, size: 16),
                                label: const Text('Delete Download', style: TextStyle(fontSize: 11)),
                                style: TextButton.styleFrom(
                                  backgroundColor: Colors.red.withOpacity(0.2),
                                  foregroundColor: Colors.redAccent,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                ),
                                onPressed: _selectedVodIds.isEmpty ? null : _bulkDeleteSelectedVods,
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.select_all, size: 18, color: Colors.white70),
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
                                icon: const Icon(Icons.deselect, size: 18, color: Colors.white70),
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
                      if (!_isMultiSelectMode)
                        isSmall
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  InteractivePopover(
                                    popover: _buildVodsSettingMenu(theme),
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1E2433),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: Colors.white10),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.tune, color: Colors.white70, size: 16),
                                            SizedBox(width: 4),
                                            Text('VOD Settings', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Tooltip(
                                    message: 'Show all played games on thumbnails at a glance',
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF161B26),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFF1E2433)),
                                    ),
                                    textStyle: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.sports_esports, size: 14, color: Colors.white38),
                                        const SizedBox(width: 4),
                                        const Text('Show All Games', style: TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.bold)),
                                        Transform.scale(
                                          scale: 0.7,
                                          child: Switch(
                                            value: _showGamesOnThumbnails,
                                            activeColor: theme.primaryColor,
                                            onChanged: (val) {
                                              setState(() {
                                                _showGamesOnThumbnails = val;
                                                _settings.showGamesOnThumbnails = val;
                                              });
                                              _saveChannels();
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 130,
                                    height: 28,
                                    child: TextField(
                                      controller: _vodSearchController,
                                      style: const TextStyle(fontSize: 11, color: Colors.white),
                                      decoration: InputDecoration(
                                        hintText: 'Filter VODs...',
                                        hintStyle: const TextStyle(fontSize: 11, color: Colors.white38),
                                        prefixIcon: const Icon(Icons.search, size: 12, color: Colors.white38),
                                        contentPadding: EdgeInsets.zero,
                                        filled: true,
                                        fillColor: const Color(0xFF1E2433),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(6),
                                          borderSide: BorderSide.none,
                                        ),
                                      ),
                                      onChanged: (val) {
                                        setState(() {});
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  const Icon(Icons.photo_size_select_large, size: 14, color: Colors.white38),
                                  const SizedBox(width: 6),
                                  const Text('Card Size: ', style: TextStyle(fontSize: 12, color: Colors.white38)),
                                  SizedBox(
                                    width: 110,
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 2,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                        activeTrackColor: theme.primaryColor,
                                        inactiveTrackColor: Colors.white10,
                                        thumbColor: theme.primaryColor,
                                        overlayColor: theme.primaryColor.withOpacity(0.12),
                                      ),
                                      child: Slider(
                                        value: _vodScale,
                                        min: 200.0,
                                        max: 600.0,
                                        onChanged: (val) {
                                          setState(() {
                                            _vodScale = val;
                                          });
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  const Icon(Icons.format_size, size: 14, color: Colors.white38),
                                  const SizedBox(width: 6),
                                  const Text('Font: ', style: TextStyle(fontSize: 12, color: Colors.white38)),
                                  SizedBox(
                                    width: 90,
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 2,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                        activeTrackColor: theme.primaryColor,
                                        inactiveTrackColor: Colors.white10,
                                        thumbColor: theme.primaryColor,
                                        overlayColor: theme.primaryColor.withOpacity(0.12),
                                      ),
                                      child: Slider(
                                        value: _vodTitleFontSize,
                                        min: 11.0,
                                        max: 20.0,
                                        onChanged: (val) {
                                          setState(() {
                                            _vodTitleFontSize = val;
                                          });
                                        },
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_isWebTokenExpired) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orangeAccent.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 20),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Your Twitch Browser OAuth Token has expired. VOD watch progress tracking is currently paused.',
                              style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 12),
                          TextButton(
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.orangeAccent.withOpacity(0.2),
                              foregroundColor: Colors.orangeAccent,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            ),
                            onPressed: _showSettingsDialog,
                            child: const Text('Update Token', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white60, size: 16),
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
                  
                  // Modular Vods Grid Component
                  VodsGrid(
                    vods: _channelVods,
                    isLoading: _isLoadingVods,
                    vodsError: _vodsError,
                    vodScale: _vodScale,
                    vodTitleFontSize: _vodTitleFontSize,
                    showGamesOnThumbnails: _showGamesOnThumbnails,
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
                    onScaleChanged: (val) => setState(() => _vodScale = val),
                    onFontSizeChanged: (val) => setState(() => _vodTitleFontSize = val),
                    onShowGamesChanged: (val) => setState(() => _showGamesOnThumbnails = val),
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
                    onToggleMultiSelect: () => setState(() {
                      _isMultiSelectMode = !_isMultiSelectMode;
                      _selectedVodIds.clear();
                    }),
                    onSelectAllVisible: () {
                      final searchQuery = _vodSearchController.text.trim().toLowerCase();
                      final visible = _channelVods.where((vod) {
                        final matchesSearch = searchQuery.isEmpty ||
                            vod.title.toLowerCase().contains(searchQuery) ||
                            vod.games.any((game) => game.toLowerCase().contains(searchQuery));
                        final matchesGameFilter = _selectedGamesFilter.isEmpty ||
                            vod.games.any((game) => _selectedGamesFilter.contains(game));
                        return matchesSearch && matchesGameFilter;
                      });
                      setState(() {
                        _selectedVodIds.addAll(visible.map((v) => v.id));
                      });
                    },
                    onDeselectAll: () => setState(() => _selectedVodIds.clear()),
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
                    onBulkDownload: _bulkDownloadSelectedVods,
                    onBulkDelete: _bulkDeleteSelectedVods,
                  ),
                  
                  if (_vodPaginationCursor != null && _vodPaginationCursor!.isNotEmpty && _channelVods.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Center(
                      child: SizedBox(
                        width: 180,
                        height: 40,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1E2433),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            elevation: 0,
                          ),
                          onPressed: _isLoadingVods
                              ? null
                              : () => _fetchVodsForChannel(channel, loadMore: true),
                          child: _isLoadingVods
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
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
                  ],
                ],
              ],
            ),
          ),
        ),

        // Modular Terminal Logs Console Panel
        ConsolePanel(
          logNotifier: _logNotifier,
          playerTabTitles: _playerService.playerTabTitles,
          playingVodIds: _playerService.playingVodIds,
          runningChannels: _playerService.runningChannels,
          selectedConsoleTabKey: _selectedConsoleTabKey,
          consoleCollapsed: _consoleCollapsed,
          activeDownloadsProgress: _playerService.activeDownloadsProgress,
          activeDownloadTasks: _playerService.activeDownloadTasks,
          downloadQueue: _playerService.downloadQueue,
          queuedDownloadTasks: _playerService.queuedDownloadTasks,
          downloadTitles: _playerService.downloadTitles,
          onCancelDownload: (vodId) {
            final channel = _playerService.downloadChannelNames[vodId] ?? 'VOD';
            _cancelVodDownload(vodId, channel);
          },
          onTabSelected: (key) {
            setState(() {
              _selectedConsoleTabKey = key;
              _consoleCollapsed = false;
            });
          },
          onToggleCollapse: () {
            setState(() {
              _consoleCollapsed = !_consoleCollapsed;
            });
          },
          onKillProcess: (key) {
            _playerService.killProcess(key);
          },
          onCloseTab: (key) {
            setState(() {
              _logNotifier.removeKey(key);
              _playerService.playerTabTitles.remove(key);
              if (_selectedConsoleTabKey == key) {
                _selectedConsoleTabKey = _playerService.playerTabTitles.keys.isNotEmpty 
                    ? _playerService.playerTabTitles.keys.first 
                    : '__downloads_manager__';
              }
            });
          },
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
      decoration: BoxDecoration(
        color: const Color(0xFF161B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E2433)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 10,
          )
        ],
      ),
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
                    const Row(
                      children: [
                        Icon(Icons.sports_esports, size: 14, color: Colors.white54),
                        SizedBox(width: 6),
                        Text('Show All Games on Thumbnails', style: TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: _showGamesOnThumbnails,
                        activeColor: theme.primaryColor,
                        onChanged: (val) {
                          setState(() {
                            _showGamesOnThumbnails = val;
                            _settings.showGamesOnThumbnails = val;
                          });
                          _saveChannels();
                          setMenuState(() {});
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            const Text('Filter Broadcasts:', style: TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            SizedBox(
              height: 36,
              child: TextField(
                controller: _vodSearchController,
                style: const TextStyle(fontSize: 12, color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Filter VODs...',
                  hintStyle: const TextStyle(fontSize: 11, color: Colors.white38),
                  prefixIcon: const Icon(Icons.search, size: 14, color: Colors.white38),
                  contentPadding: EdgeInsets.zero,
                  filled: true,
                  fillColor: const Color(0xFF1E2433),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (val) {
                  setState(() {});
                },
              ),
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
                        const Text('Filter by Games:', style: TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.bold)),
                        if (_selectedGamesFilter.isNotEmpty)
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedGamesFilter.clear();
                              });
                              setMenuState(() {});
                            },
                            child: Text(
                              'Clear All',
                              style: TextStyle(fontSize: 10, color: theme.primaryColor, fontWeight: FontWeight.bold),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E2433),
                        borderRadius: BorderRadius.circular(6),
                      ),
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
                                  SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: Checkbox(
                                      value: isChecked,
                                      activeColor: theme.primaryColor,
                                      checkColor: Colors.white,
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
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      game,
                                      style: const TextStyle(fontSize: 11, color: Colors.white),
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
                const Icon(Icons.photo_size_select_large, size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                const Text('Card Size: ', style: TextStyle(fontSize: 12, color: Colors.white38)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: theme.primaryColor,
                      inactiveTrackColor: Colors.white10,
                      thumbColor: theme.primaryColor,
                      overlayColor: theme.primaryColor.withOpacity(0.12),
                    ),
                    child: Slider(
                      value: _vodScale,
                      min: 200.0,
                      max: 600.0,
                      onChanged: (val) {
                        setState(() {
                          _vodScale = val;
                        });
                      },
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.format_size, size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                const Text('Font Size: ', style: TextStyle(fontSize: 12, color: Colors.white38)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: theme.primaryColor,
                      inactiveTrackColor: Colors.white10,
                      thumbColor: theme.primaryColor,
                      overlayColor: theme.primaryColor.withOpacity(0.12),
                    ),
                    child: Slider(
                      value: _vodTitleFontSize,
                      min: 11.0,
                      max: 20.0,
                      onChanged: (val) {
                        setState(() {
                          _vodTitleFontSize = val;
                        });
                      },
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
    
    if (file == null) {
      file = _playerService.getDownloadedVodFile(
        vod.id,
        channelName,
        _settings.vodDownloadFolder
      );
    }
    
    if (file != null && file.existsSync()) {
      _playerService.playDownloadedVod(file, vod, _settings);
    } else {
      _playerService.launchStreamlinkForVod(vod, channelName, _settings);
    }
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

  Future<void> _deleteDownloadedVod(String vodId, String channelName) async {
    final downloadFolder = _settings.vodDownloadFolder.trim();
    if (downloadFolder.isNotEmpty) {
      final dir = Directory('$downloadFolder/$channelName');
      if (dir.existsSync()) {
        try {
          final files = dir.listSync();
          for (final file in files) {
            if (file is File && (file.path.contains(' - $vodId') || file.path.contains(' - v$vodId'))) {
              file.deleteSync();
            }
          }
        } catch (_) {}
      }
    }
    
    _playerService.removeVodFromArchive(vodId);
    _downloadedVodsRegistry.remove(vodId);
    await _saveChannels();
    _checkDownloadedVods();
    _showSnackBar('Deleted download for VOD ID: $vodId', isError: false);
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
          title: const Row(
            children: [
              Icon(Icons.download_for_offline, color: Colors.greenAccent),
              SizedBox(width: 10),
              Text('Download Queue Order'),
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
              const Text('Please select how the download order should be processed:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.arrow_downward, color: Colors.white70),
                title: const Text('Newest First', style: TextStyle(fontSize: 13)),
                subtitle: const Text('Downloads the latest broadcasts sequentially', style: TextStyle(fontSize: 11, color: Colors.white38)),
                onTap: () => Navigator.pop(context, 'newest'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.arrow_upward, color: Colors.white70),
                title: const Text('Oldest First', style: TextStyle(fontSize: 13)),
                subtitle: const Text('Downloads the oldest broadcasts sequentially', style: TextStyle(fontSize: 11, color: Colors.white38)),
                onTap: () => Navigator.pop(context, 'oldest'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.bolt, color: Colors.white70),
                title: const Text('Simultaneous Downloads', style: TextStyle(fontSize: 13)),
                subtitle: const Text('Starts all downloads in parallel (may consume high CPU/bandwidth)', style: TextStyle(fontSize: 11, color: Colors.white38)),
                onTap: () => Navigator.pop(context, 'parallel'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.white30)),
            ),
          ],
        );
      },
    );

    if (chosenOrder == null) return;

    final channelName = _selectedChannel?.username ?? 'VOD';

    if (chosenOrder == 'parallel') {
      _showSnackBar('Starting ${selectedVods.length} parallel downloads...', isError: false);
      for (final vod in selectedVods) {
        _playerService.queueVodDownload(vod, channelName, _settings);
      }
    } else {
      final sortedVods = List<TwitchVideo>.from(selectedVods);
      if (chosenOrder == 'newest') {
        sortedVods.sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
      } else {
        sortedVods.sort((a, b) => a.publishedAt.compareTo(b.publishedAt));
      }
      _showSnackBar('Queueing ${selectedVods.length} sequential downloads...', isError: false);
      for (final vod in sortedVods) {
        _playerService.queueVodDownload(vod, channelName, _settings);
      }
    }
    setState(() {});
  }

  Future<void> _bulkDeleteSelectedVods() async {
    final toDelete = <TwitchVideo>[];
    final channelName = _selectedChannel?.username ?? '';
    for (final id in _selectedVodIds) {
      final vod = _channelVods.firstWhere((v) => v.id == id);
      if (_playerService.getDownloadedVodFile(id, channelName, _settings.vodDownloadFolder) != null) {
        toDelete.add(vod);
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
                const Text(
                  'Are you sure you want to delete the downloaded files on disk for the following videos? This cannot be undone.',
                  style: TextStyle(height: 1.4),
                ),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(8),
                  ),
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
                          style: const TextStyle(fontSize: 12),
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
              child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete Files', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
    
    if (confirm != true) return;
    
    int count = 0;
    for (final vod in toDelete) {
      try {
        final downloadFolder = _settings.vodDownloadFolder.trim();
        if (downloadFolder.isNotEmpty) {
          final dir = Directory('$downloadFolder/$channelName');
          if (dir.existsSync()) {
            final files = dir.listSync();
            for (final file in files) {
              if (file is File && (file.path.contains(' - ${vod.id}') || file.path.contains(' - v${vod.id}'))) {
                file.deleteSync();
              }
            }
            count++;
          }
        }
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
