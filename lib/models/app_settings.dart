import 'dart:io';

class AppSettings {
  String defaultQuality;
  /// Passes `--twitch-low-latency` to streamlink when enabled.
  ///
  /// Defaults OFF: streamlink reduces `--hls-live-edge` to 2 and prefetches,
  /// which its own help warns can cause buffering on regular streams. The
  /// control was inert for a long time while every stored config carried
  /// `true`, so honouring that value would have silently changed playback for
  /// everyone on upgrade.
  bool twitchLowLatency;
  String twitchOauthToken;
  String twitchWebOauthToken;
  String playerType; // 'default', 'vlc', 'mpv', 'mpc-hc', 'custom'
  String customPlayerPath;
  String customPlayerArgs;

  /// Hand the player the VOD's HLS URL instead of piping the stream through
  /// streamlink, so the player's own seek bar works across the whole VOD.
  /// Turning this off restores piping, where no timeline exists at all.
  bool seekableVodStreaming;
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

  // --- v1.1.0: view state that previously reset every restart ---
  double vodCardScale;
  double vodTitleFontSize;

  // --- v1.1.0: window & tray behavior ---
  /// What the title-bar close button does: 'tray' (keep monitoring in the
  /// background) or 'exit'.
  String closeAction;

  /// What minimize does: 'taskbar' (Windows convention) or 'tray'.
  String minimizeAction;

  /// Whether a Run-key autostart entry is maintained for this install.
  bool launchAtStartup;

  /// Start hidden to the tray on manual launches too.
  bool startMinimized;

  /// One-time "still running in the tray" notice has been shown.
  bool trayNoticeShown;

  /// Show live favorites as direct launch items in the tray menu.
  bool trayLiveMenuEnabled;

  // --- v1.1.0: per-category notification toggles ---
  bool notifyWentLive;
  bool notifyAutoPlay;
  bool notifyAutoDownloadStart;
  bool notifyDownloadComplete;

  /// First-run wizard has been completed or skipped.
  bool onboardingCompleted;

  /// Accent colour per theme mode. These are the values the Styling tab edits.
  String lightAccentColorHex;
  String darkAccentColorHex;

  AppSettings({
    this.defaultQuality = 'best',
    this.twitchLowLatency = false,
    this.twitchOauthToken = '',
    this.twitchWebOauthToken = '',
    this.playerType = 'default',
    this.customPlayerPath = '',
    this.customPlayerArgs = '',
    this.seekableVodStreaming = true,
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
    this.vodCardScale = 350.0,
    this.vodTitleFontSize = 14.0,
    this.closeAction = 'tray',
    this.minimizeAction = 'taskbar',
    this.launchAtStartup = false,
    this.startMinimized = false,
    this.trayNoticeShown = false,
    this.trayLiveMenuEnabled = true,
    this.notifyWentLive = true,
    this.notifyAutoPlay = true,
    this.notifyAutoDownloadStart = true,
    this.notifyDownloadComplete = true,
    this.onboardingCompleted = false,
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
    bool? seekableVodStreaming,
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
    double? vodCardScale,
    double? vodTitleFontSize,
    String? closeAction,
    String? minimizeAction,
    bool? launchAtStartup,
    bool? startMinimized,
    bool? trayNoticeShown,
    bool? trayLiveMenuEnabled,
    bool? notifyWentLive,
    bool? notifyAutoPlay,
    bool? notifyAutoDownloadStart,
    bool? notifyDownloadComplete,
    bool? onboardingCompleted,
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
      seekableVodStreaming: seekableVodStreaming ?? this.seekableVodStreaming,
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
      vodCardScale: vodCardScale ?? this.vodCardScale,
      vodTitleFontSize: vodTitleFontSize ?? this.vodTitleFontSize,
      closeAction: closeAction ?? this.closeAction,
      minimizeAction: minimizeAction ?? this.minimizeAction,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      startMinimized: startMinimized ?? this.startMinimized,
      trayNoticeShown: trayNoticeShown ?? this.trayNoticeShown,
      trayLiveMenuEnabled: trayLiveMenuEnabled ?? this.trayLiveMenuEnabled,
      notifyWentLive: notifyWentLive ?? this.notifyWentLive,
      notifyAutoPlay: notifyAutoPlay ?? this.notifyAutoPlay,
      notifyAutoDownloadStart: notifyAutoDownloadStart ?? this.notifyAutoDownloadStart,
      notifyDownloadComplete: notifyDownloadComplete ?? this.notifyDownloadComplete,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
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
        'seekable_vod_streaming': seekableVodStreaming,
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
        'vod_card_scale': vodCardScale,
        'vod_title_font_size': vodTitleFontSize,
        'close_action': closeAction,
        'minimize_action': minimizeAction,
        'launch_at_startup': launchAtStartup,
        'start_minimized': startMinimized,
        'tray_notice_shown': trayNoticeShown,
        'tray_live_menu_enabled': trayLiveMenuEnabled,
        'notify_went_live': notifyWentLive,
        'notify_auto_play': notifyAutoPlay,
        'notify_auto_download_start': notifyAutoDownloadStart,
        'notify_download_complete': notifyDownloadComplete,
        'onboarding_completed': onboardingCompleted,
      };

  /// Clamps a persisted number into the range its UI control supports, so a
  /// hand-edited or corrupted config cannot feed a Slider/Dropdown an
  /// out-of-range value (which asserts in debug builds and renders wrong in
  /// release).
  static int _clampInt(dynamic value, int fallback, int min, int max) {
    final n = value is num ? value.toInt() : fallback;
    return n.clamp(min, max);
  }

  static double _clampDouble(dynamic value, double fallback, double min, double max) {
    final n = value is num ? value.toDouble() : fallback;
    return n.clamp(min, max);
  }

  static String _oneOf(dynamic value, List<String> allowed, String fallback) {
    return value is String && allowed.contains(value) ? value : fallback;
  }

  /// The remaining readers, made total.
  ///
  /// `fromJson` is called on a file a user can hand-edit, and it runs in
  /// `main()` before the first frame. A bare `json['x'] ?? default` returns the
  /// wrong TYPE rather than the default when the value is present but wrong
  /// (`"true"` for a bool, `"1"` for an int), which throws out of the
  /// constructor and prevents the app starting at all.
  static String _str(dynamic value, String fallback) =>
      value is String ? value : fallback;

  static bool _flag(dynamic value, bool fallback) =>
      value is bool ? value : fallback;

  static double? _maybeDouble(dynamic value) =>
      value is num ? value.toDouble() : null;

  static List<dynamic> _list(dynamic value) =>
      value is List ? value : const [];

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        defaultQuality: _str(json['default_quality'], 'best'),
        twitchLowLatency: _flag(json['twitch_low_latency'], false),
        twitchOauthToken: _str(json['twitch_oauth_token'], ''),
        twitchWebOauthToken: _str(json['twitch_web_oauth_token'], ''),
        playerType: _oneOf(json['player_type'],
            const ['default', 'vlc', 'mpv', 'mpc-hc', 'custom'], 'default'),
        customPlayerPath: _str(json['custom_player_path'], ''),
        customPlayerArgs: _str(json['custom_player_args'], ''),
        seekableVodStreaming: _flag(json['seekable_vod_streaming'], true),
        twitchClientId: _str(
            json['twitch_client_id'], 'kimne78kx3ncx6brgo4mv6wki5h1ko'),
        localServerPort: _clampInt(json['local_server_port'], 65432, 1, 65535),
        watchedThreshold: _clampInt(json['watched_threshold'], 96, 50, 100),
        sidebarCollapsed: _flag(json['sidebar_collapsed'], false),
        activeProgressColorHex: _str(json['active_progress_color_hex'], '#9146FF'),
        watchedProgressColorHex:
            _str(json['watched_progress_color_hex'], '#804CAF50'),
        lightAccentColorHex: _str(json['light_accent_color_hex'], '#FF6584'),
        darkAccentColorHex: _str(json['dark_accent_color_hex'], '#FF3B30'),
        vodDownloadFolder: _str(json['vod_download_folder'], ''),
        maxDownloadsToKeep: _clampInt(json['max_downloads_to_keep'], 0, 0, 1 << 30),
        unfinishedDownloads: _list(json['unfinished_downloads']),
        maxRecentlyWatched: _clampInt(json['max_recently_watched'], 8, 1, 20),
        activeSidebarTab: _clampInt(json['active_sidebar_tab'], 0, 0, 2),
        windowWidth: _maybeDouble(json['window_width']) ?? 1280.0,
        windowHeight: _maybeDouble(json['window_height']) ?? 720.0,
        windowX: _maybeDouble(json['window_x']),
        windowY: _maybeDouble(json['window_y']),
        isWindowMaximized: _flag(json['is_window_maximized'], false),
        showGamesOnThumbnails: _flag(json['show_games_on_thumbnails'], true),
        vodWatchExclusionThreshold:
            _clampInt(json['vod_watch_exclusion_threshold'], 15, 5, 90),
        autoPlayPreemptLowerPriority:
            _flag(json['auto_play_preempt_lower_priority'], false),
        isDarkTheme: _flag(json['is_dark_theme'], true),
        disableVodPostProcessing: _flag(json['disable_vod_post_processing'], true),
        customVodArgs: _str(json['custom_vod_args'], ''),
        vodCardScale: _clampDouble(json['vod_card_scale'], 350.0, 200.0, 600.0),
        vodTitleFontSize:
            _clampDouble(json['vod_title_font_size'], 14.0, 11.0, 20.0),
        closeAction: _oneOf(json['close_action'], ['tray', 'exit'], 'tray'),
        minimizeAction:
            _oneOf(json['minimize_action'], ['taskbar', 'tray'], 'taskbar'),
        launchAtStartup: _flag(json['launch_at_startup'], false),
        startMinimized: _flag(json['start_minimized'], false),
        trayNoticeShown: _flag(json['tray_notice_shown'], false),
        trayLiveMenuEnabled: _flag(json['tray_live_menu_enabled'], true),
        notifyWentLive: _flag(json['notify_went_live'], true),
        notifyAutoPlay: _flag(json['notify_auto_play'], true),
        notifyAutoDownloadStart: _flag(json['notify_auto_download_start'], true),
        notifyDownloadComplete: _flag(json['notify_download_complete'], true),
        onboardingCompleted: _flag(json['onboarding_completed'], false),
      );
}
