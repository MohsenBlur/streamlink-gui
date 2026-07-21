import 'dart:io';

class AppSettings {
  String defaultQuality = 'best';
  bool twitchLowLatency = true;
  String twitchOauthToken = '';
  String twitchWebOauthToken = '';
  String playerType = 'default'; // 'default', 'vlc', 'mpv', 'mpc-hc', 'custom'
  String customPlayerPath = '';
  String customPlayerArgs = '';
  String twitchClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
  int localServerPort = 65432;
  int watchedThreshold = 96;
  bool sidebarCollapsed = false;
  String primaryColorHex = '#9146FF';
  String backgroundColorHex = '#0C0F17';
  String surfaceColorHex = '#161B26';
  String activeProgressColorHex = '#9146FF';
  String watchedProgressColorHex = '#804CAF50';
  String vodDownloadFolder = '';
  int maxDownloadsToKeep = 0; // 0 = unlimited
  List<dynamic> unfinishedDownloads = const [];
  int maxRecentlyWatched = 8;
  int activeSidebarTab = 0;

  // Window bounds & UI state persistence
  double windowWidth = 1280.0;
  double windowHeight = 720.0;
  double? windowX;
  double? windowY;
  bool isWindowMaximized = false;
  bool showGamesOnThumbnails = true;

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
    this.primaryColorHex = '#9146FF',
    this.backgroundColorHex = '#0C0F17',
    this.surfaceColorHex = '#161B26',
    this.activeProgressColorHex = '#9146FF',
    this.watchedProgressColorHex = '#804CAF50',
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
        'primary_color_hex': primaryColorHex,
        'background_color_hex': backgroundColorHex,
        'surface_color_hex': surfaceColorHex,
        'active_progress_color_hex': activeProgressColorHex,
        'watched_progress_color_hex': watchedProgressColorHex,
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
        primaryColorHex: json['primary_color_hex'] ?? '#9146FF',
        backgroundColorHex: json['background_color_hex'] ?? '#0C0F17',
        surfaceColorHex: json['surface_color_hex'] ?? '#161B26',
        activeProgressColorHex: json['active_progress_color_hex'] ?? '#9146FF',
        watchedProgressColorHex: json['watched_progress_color_hex'] ?? '#804CAF50',
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
      );
}
