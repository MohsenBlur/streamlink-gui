import 'dart:io';

class AppSettings {
  String defaultQuality;
  bool twitchLowLatency;
  String twitchOauthToken;
  String twitchWebOauthToken;
  String playerType; // 'default', 'vlc', 'mpv', 'mpc-hc', 'custom'
  String customPlayerPath;
  String customPlayerArgs;
  String twitchClientId;
  int localServerPort;
  int watchedThreshold;
  bool sidebarCollapsed;

  /// VOD progress bar colours. Persisted so they can be tuned by hand in
  /// channels_config.json; there is deliberately no UI for them yet.
  String activeProgressColorHex;
  String watchedProgressColorHex;

  String vodDownloadFolder;
  int maxDownloadsToKeep; // 0 = unlimited
  List<dynamic> unfinishedDownloads;
  int maxRecentlyWatched;
  int activeSidebarTab;

  // Window bounds & UI state persistence
  double windowWidth;
  double windowHeight;
  double? windowX;
  double? windowY;
  bool isWindowMaximized;
  bool showGamesOnThumbnails;
  int vodWatchExclusionThreshold; // default 15%
  bool autoPlayPreemptLowerPriority;
  bool isDarkTheme;
  bool disableVodPostProcessing;
  String customVodArgs;

  /// Accent colour per theme mode. These are the values the Styling tab edits.
  String lightAccentColorHex;
  String darkAccentColorHex;

  AppSettings({
    this.defaultQuality = 'best',
    this.twitchLowLatency = true,
    this.twitchOauthToken = '',
    this.twitchWebOauthToken = '',
    this.playerType = 'default',
    this.customPlayerPath = '',
    this.customPlayerArgs = '',
    this.twitchClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko',
    this.localServerPort = 65432,
    this.watchedThreshold = 96,
    this.sidebarCollapsed = false,
    this.activeProgressColorHex = '#9146FF',
    this.watchedProgressColorHex = '#804CAF50',
    this.lightAccentColorHex = '#FF6584',
    this.darkAccentColorHex = '#FF3B30',
    this.vodDownloadFolder = '',
    this.maxDownloadsToKeep = 0,
    this.unfinishedDownloads = const [],
    this.maxRecentlyWatched = 8,
    this.activeSidebarTab = 0,
    this.windowWidth = 1280.0,
    this.windowHeight = 720.0,
    this.windowX,
    this.windowY,
    this.isWindowMaximized = false,
    this.showGamesOnThumbnails = true,
    this.vodWatchExclusionThreshold = 15,
    this.autoPlayPreemptLowerPriority = false,
    this.isDarkTheme = true,
    this.disableVodPostProcessing = true,
    this.customVodArgs = '',
  }) {
    if (vodDownloadFolder.isEmpty) {
      if (Platform.environment['USERPROFILE'] != null) {
        vodDownloadFolder = '${Platform.environment['USERPROFILE']}\\Downloads\\TwitchVODs';
      } else if (Platform.environment['HOME'] != null) {
        vodDownloadFolder = '${Platform.environment['HOME']}/Downloads/TwitchVODs';
      } else {
        vodDownloadFolder = '';
      }
    }
  }

  /// Returns a copy with only the supplied fields replaced.
  ///
  /// Editors MUST use this rather than constructing a fresh [AppSettings]:
  /// building a new instance from only the fields a dialog knows about silently
  /// reset every other persisted field to its default, so saving the settings
  /// dialog used to wipe the theme mode, window geometry, the VOD watch
  /// exclusion threshold and the auto-play preemption toggle.
  ///
  /// Note: [windowX] and [windowY] are nullable and passing null means "keep the
  /// current value". Use [clearWindowPosition] to reset them.
  AppSettings copyWith({
    String? defaultQuality,
    bool? twitchLowLatency,
    String? twitchOauthToken,
    String? twitchWebOauthToken,
    String? playerType,
    String? customPlayerPath,
    String? customPlayerArgs,
    String? twitchClientId,
    int? localServerPort,
    int? watchedThreshold,
    bool? sidebarCollapsed,
    String? activeProgressColorHex,
    String? watchedProgressColorHex,
    String? lightAccentColorHex,
    String? darkAccentColorHex,
    String? vodDownloadFolder,
    int? maxDownloadsToKeep,
    List<dynamic>? unfinishedDownloads,
    int? maxRecentlyWatched,
    int? activeSidebarTab,
    double? windowWidth,
    double? windowHeight,
    double? windowX,
    double? windowY,
    bool? isWindowMaximized,
    bool? showGamesOnThumbnails,
    int? vodWatchExclusionThreshold,
    bool? autoPlayPreemptLowerPriority,
    bool? isDarkTheme,
    bool? disableVodPostProcessing,
    String? customVodArgs,
    bool clearWindowPosition = false,
  }) {
    return AppSettings(
      defaultQuality: defaultQuality ?? this.defaultQuality,
      twitchLowLatency: twitchLowLatency ?? this.twitchLowLatency,
      twitchOauthToken: twitchOauthToken ?? this.twitchOauthToken,
      twitchWebOauthToken: twitchWebOauthToken ?? this.twitchWebOauthToken,
      playerType: playerType ?? this.playerType,
      customPlayerPath: customPlayerPath ?? this.customPlayerPath,
      customPlayerArgs: customPlayerArgs ?? this.customPlayerArgs,
      twitchClientId: twitchClientId ?? this.twitchClientId,
      localServerPort: localServerPort ?? this.localServerPort,
      watchedThreshold: watchedThreshold ?? this.watchedThreshold,
      sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
      activeProgressColorHex: activeProgressColorHex ?? this.activeProgressColorHex,
      watchedProgressColorHex: watchedProgressColorHex ?? this.watchedProgressColorHex,
      lightAccentColorHex: lightAccentColorHex ?? this.lightAccentColorHex,
      darkAccentColorHex: darkAccentColorHex ?? this.darkAccentColorHex,
      vodDownloadFolder: vodDownloadFolder ?? this.vodDownloadFolder,
      maxDownloadsToKeep: maxDownloadsToKeep ?? this.maxDownloadsToKeep,
      unfinishedDownloads: unfinishedDownloads ?? this.unfinishedDownloads,
      maxRecentlyWatched: maxRecentlyWatched ?? this.maxRecentlyWatched,
      activeSidebarTab: activeSidebarTab ?? this.activeSidebarTab,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
      windowX: clearWindowPosition ? null : (windowX ?? this.windowX),
      windowY: clearWindowPosition ? null : (windowY ?? this.windowY),
      isWindowMaximized: isWindowMaximized ?? this.isWindowMaximized,
      showGamesOnThumbnails: showGamesOnThumbnails ?? this.showGamesOnThumbnails,
      vodWatchExclusionThreshold: vodWatchExclusionThreshold ?? this.vodWatchExclusionThreshold,
      autoPlayPreemptLowerPriority: autoPlayPreemptLowerPriority ?? this.autoPlayPreemptLowerPriority,
      isDarkTheme: isDarkTheme ?? this.isDarkTheme,
      disableVodPostProcessing: disableVodPostProcessing ?? this.disableVodPostProcessing,
      customVodArgs: customVodArgs ?? this.customVodArgs,
    );
  }

  Map<String, dynamic> toJson() => {
        'default_quality': defaultQuality,
        'twitch_low_latency': twitchLowLatency,
        'twitch_oauth_token': twitchOauthToken,
        'twitch_web_oauth_token': twitchWebOauthToken,
        'player_type': playerType,
        'custom_player_path': customPlayerPath,
        'custom_player_args': customPlayerArgs,
        'twitch_client_id': twitchClientId,
        'local_server_port': localServerPort,
        'watched_threshold': watchedThreshold,
        'sidebar_collapsed': sidebarCollapsed,
        'active_progress_color_hex': activeProgressColorHex,
        'watched_progress_color_hex': watchedProgressColorHex,
        'light_accent_color_hex': lightAccentColorHex,
        'dark_accent_color_hex': darkAccentColorHex,
        'vod_download_folder': vodDownloadFolder,
        'max_downloads_to_keep': maxDownloadsToKeep,
        'unfinished_downloads': unfinishedDownloads,
        'max_recently_watched': maxRecentlyWatched,
        'active_sidebar_tab': activeSidebarTab,
        'window_width': windowWidth,
        'window_height': windowHeight,
        'window_x': windowX,
        'window_y': windowY,
        'is_window_maximized': isWindowMaximized,
        'show_games_on_thumbnails': showGamesOnThumbnails,
        'vod_watch_exclusion_threshold': vodWatchExclusionThreshold,
        'auto_play_preempt_lower_priority': autoPlayPreemptLowerPriority,
        'is_dark_theme': isDarkTheme,
        'disable_vod_post_processing': disableVodPostProcessing,
        'custom_vod_args': customVodArgs,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        defaultQuality: json['default_quality'] ?? 'best',
        twitchLowLatency: json['twitch_low_latency'] ?? true,
        twitchOauthToken: json['twitch_oauth_token'] ?? '',
        twitchWebOauthToken: json['twitch_web_oauth_token'] ?? '',
        playerType: json['player_type'] ?? 'default',
        customPlayerPath: json['custom_player_path'] ?? '',
        customPlayerArgs: json['custom_player_args'] ?? '',
        twitchClientId: json['twitch_client_id'] ?? 'kimne78kx3ncx6brgo4mv6wki5h1ko',
        localServerPort: json['local_server_port'] ?? 65432,
        watchedThreshold: json['watched_threshold'] ?? 96,
        sidebarCollapsed: json['sidebar_collapsed'] ?? false,
        activeProgressColorHex: json['active_progress_color_hex'] ?? '#9146FF',
        watchedProgressColorHex: json['watched_progress_color_hex'] ?? '#804CAF50',
        lightAccentColorHex: json['light_accent_color_hex'] ?? '#FF6584',
        darkAccentColorHex: json['dark_accent_color_hex'] ?? '#FF3B30',
        vodDownloadFolder: json['vod_download_folder'] ?? '',
        maxDownloadsToKeep: json['max_downloads_to_keep'] ?? 0,
        unfinishedDownloads: json['unfinished_downloads'] ?? const [],
        maxRecentlyWatched: json['max_recently_watched'] ?? 8,
        activeSidebarTab: json['active_sidebar_tab'] ?? 0,
        windowWidth: (json['window_width'] as num?)?.toDouble() ?? 1280.0,
        windowHeight: (json['window_height'] as num?)?.toDouble() ?? 720.0,
        windowX: (json['window_x'] as num?)?.toDouble(),
        windowY: (json['window_y'] as num?)?.toDouble(),
        isWindowMaximized: json['is_window_maximized'] ?? false,
        showGamesOnThumbnails: json['show_games_on_thumbnails'] ?? true,
        vodWatchExclusionThreshold: json['vod_watch_exclusion_threshold'] ?? 15,
        autoPlayPreemptLowerPriority: json['auto_play_preempt_lower_priority'] ?? false,
        isDarkTheme: json['is_dark_theme'] ?? true,
        disableVodPostProcessing: json['disable_vod_post_processing'] ?? true,
        customVodArgs: json['custom_vod_args'] ?? '',
      );
}
