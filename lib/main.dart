import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';
import 'package:local_notifier/local_notifier.dart';

class AppThemeNotifier extends ChangeNotifier {
  Color primaryColor = const Color(0xFF9146FF);
  Color backgroundColor = const Color(0xFF0C0F17);
  Color surfaceColor = const Color(0xFF161B26);
  Color activeProgressColor = const Color(0xFF9146FF);
  Color watchedProgressColor = const Color(0x804CAF50); // transparent green

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

Color parseHexColor(String hex, Color defaultColor) {
  try {
    String clean = hex.replaceAll('#', '').trim();
    if (clean.length == 6) {
      clean = 'FF' + clean;
    }
    if (clean.length == 8) {
      return Color(int.parse(clean, radix: 16));
    }
  } catch (_) {}
  return defaultColor;
}

String colorToHex(Color color) {
  return '#' + color.value.toRadixString(16).padLeft(8, '0').toUpperCase();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await localNotifier.setup(
    appName: 'Twitch Streamlink GUI',
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );

  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(1280, 720),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setPreventClose(true);
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
          ),
          home: const MainScreen(),
        );
      },
    );
  }
}

class AppSettings {
  String defaultQuality = 'best';
  bool twitchLowLatency = true;
  String twitchOauthToken = '';
  String twitchWebOauthToken = '';
  String playerType = 'default';
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
  String vodDownloadFolder = Platform.environment['USERPROFILE'] != null
      ? '${Platform.environment['USERPROFILE']}\\Downloads\\TwitchVODs'
      : '';
  int maxDownloadsToKeep = 0; // 0 = unlimited
  List<dynamic> unfinishedDownloads = const [];

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
  }) {
    if (vodDownloadFolder.isEmpty && Platform.environment['USERPROFILE'] != null) {
      vodDownloadFolder = '${Platform.environment['USERPROFILE']}\\Downloads\\TwitchVODs';
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
      );
}

class TwitchChannel {
  final String username;
  String? id;
  String? avatarUrl;
  String? followerCount;
  bool isLive = false;
  String? uptime;
  String? viewerCount;
  String? game;
  String? streamTitle;
  bool isLoading = false;
  String? errorMessage;
  DateTime? lastUpdated;

  TwitchChannel({required this.username});

  Map<String, dynamic> toJson() => {'username': username};
  factory TwitchChannel.fromJson(Map<String, dynamic> json) =>
      TwitchChannel(username: json['username'] as String);
}

class TwitchVideo {
  final String id;
  final String title;
  final String duration;
  final String thumbnailUrl;
  final String viewCount;
  final DateTime publishedAt;
  List<String> games = [];
  int? watchPosition;
  double? watchProgress;

  TwitchVideo({
    required this.id,
    required this.title,
    required this.duration,
    required this.thumbnailUrl,
    required this.viewCount,
    required this.publishedAt,
    this.games = const [],
    this.watchPosition,
    this.watchProgress,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'duration': duration,
        'thumbnail_url': thumbnailUrl,
        'view_count': int.tryParse(viewCount) ?? 0,
        'published_at': publishedAt.toIso8601String(),
        'games': games,
        'watch_position': watchPosition,
        'watch_progress': watchProgress,
      };

  factory TwitchVideo.fromJson(Map<String, dynamic> json) {
    final rawDuration = json['duration'] as String? ?? '0s';
    final rawViewCount = json['view_count'] as int? ?? 0;
    
    return TwitchVideo(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'No Title',
      duration: rawDuration,
      thumbnailUrl: json['thumbnail_url'] as String? ?? '',
      viewCount: rawViewCount.toString(),
      publishedAt: DateTime.parse(json['published_at'] as String),
      games: List<String>.from(json['games'] ?? const []),
      watchPosition: json['watch_position'] as int?,
      watchProgress: (json['watch_progress'] as num?)?.toDouble(),
    );
  }
}

class TwitchVideoCard extends StatefulWidget {
  final TwitchVideo vod;
  final double scale;
  final ThemeData theme;
  final VoidCallback onPlay;
  final String Function(String) formatNumber;
  final double fontSize;
  final bool isPlaying;
  final AnimationController? pulseController;
  final bool showGamesOnThumbnails;
  final int watchedThreshold;
  final bool isMultiSelectMode;
  final bool isSelected;
  final ValueChanged<bool?>? onSelected;
  final String? downloadStatus;
  final double? downloadProgress;
  final bool isDownloaded;
  final VoidCallback onDownload;
  final VoidCallback onDeleteDownload;
  final VoidCallback onCancel;

  const TwitchVideoCard({
    Key? key,
    required this.vod,
    required this.scale,
    required this.theme,
    required this.onPlay,
    required this.formatNumber,
    required this.fontSize,
    required this.isPlaying,
    required this.pulseController,
    required this.showGamesOnThumbnails,
    required this.watchedThreshold,
    this.isMultiSelectMode = false,
    this.isSelected = false,
    this.onSelected,
    this.downloadStatus,
    this.downloadProgress,
    this.isDownloaded = false,
    required this.onDownload,
    required this.onDeleteDownload,
    required this.onCancel,
  }) : super(key: key);

  @override
  State<TwitchVideoCard> createState() => _TwitchVideoCardState();
}

class _TwitchVideoCardState extends State<TwitchVideoCard> {
  bool _isHovered = false;
  List<String>? get _games => widget.vod.games;

  Widget _buildCardButton({
    required VoidCallback onTap,
    required IconData icon,
    required Color backgroundColor,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          hoverColor: Colors.white.withOpacity(0.2),
          splashColor: Colors.white.withOpacity(0.3),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: backgroundColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
               icon,
               size: 15,
               color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  String _formatTwitchStyleDuration(String duration) {
    final hourReg = RegExp(r'(\d+)h');
    final minReg = RegExp(r'(\d+)m');
    final secReg = RegExp(r'(\d+)s');
    
    final hourMatch = hourReg.firstMatch(duration);
    final minMatch = minReg.firstMatch(duration);
    final secMatch = secReg.firstMatch(duration);
    
    final hours = hourMatch != null ? int.parse(hourMatch.group(1)!) : 0;
    final minutes = minMatch != null ? int.parse(minMatch.group(1)!) : 0;
    final seconds = secMatch != null ? int.parse(secMatch.group(1)!) : 0;
    
    final sSec = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final sMin = minutes.toString().padLeft(2, '0');
      return '$hours:$sMin:$sSec';
    } else {
      return '$minutes:$sSec';
    }
  }

  String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inDays >= 365) {
      final years = (difference.inDays / 365).floor();
      return '$years year${years > 1 ? "s" : ""} ago';
    } else if (difference.inDays >= 30) {
      final months = (difference.inDays / 30).floor();
      return '$months month${months > 1 ? "s" : ""} ago';
    } else if (difference.inDays >= 7) {
      final weeks = (difference.inDays / 7).floor();
      return '$weeks week${weeks > 1 ? "s" : ""} ago';
    } else if (difference.inDays >= 1) {
      return '${difference.inDays} day${difference.inDays > 1 ? "s" : ""} ago';
    } else if (difference.inHours >= 1) {
      return '${difference.inHours} hour${difference.inHours > 1 ? "s" : ""} ago';
    } else if (difference.inMinutes >= 1) {
      return '${difference.inMinutes} minute${difference.inMinutes > 1 ? "s" : ""} ago';
    } else {
      return 'just now';
    }
  }

  Widget _buildGameBadge(ThemeData theme) {
    final firstGame = _games![0];
    final hasMultiple = _games!.length > 1;
    
    final mainBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sports_esports, size: 10, color: Colors.white70),
          const SizedBox(width: 4),
          Text(
            firstGame,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ],
      ),
    );

    if (!hasMultiple) return mainBadge;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Back card layer 2
        Positioned(
          top: 4,
          left: 4,
          right: -4,
          bottom: -4,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        // Back card layer 1
        Positioned(
          top: 2,
          left: 2,
          right: -2,
          bottom: -2,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        mainBadge,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.scale.round().clamp(200, 1280);
    final h = (w * 9 / 16).round();
    final thumbnailUrl = widget.vod.thumbnailUrl.isNotEmpty
        ? widget.vod.thumbnailUrl.replaceAll('%{width}', w.toString()).replaceAll('%{height}', h.toString())
        : null;

    Widget buildCardContent() {
      return MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.isMultiSelectMode
              ? () => widget.onSelected?.call(!widget.isSelected)
              : widget.onPlay,
          child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(0, _isHovered ? -4 : 0, 0),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B26),
                  borderRadius: BorderRadius.circular(12),
                  border: widget.isMultiSelectMode
                      ? Border.all(
                          color: widget.isSelected
                              ? widget.theme.primaryColor
                              : (_isHovered ? widget.theme.primaryColor.withOpacity(0.5) : const Color(0xFF1E2433)),
                          width: widget.isSelected ? 2.0 : 1.0,
                        )
                      : widget.isPlaying
                          ? Border.all(
                              color: widget.theme.primaryColor.withOpacity(0.4 + 0.6 * widget.pulseController!.value),
                              width: 2.5,
                            )
                          : Border.all(
                              color: _isHovered ? widget.theme.primaryColor.withOpacity(0.8) : const Color(0xFF1E2433),
                              width: _isHovered ? 1.5 : 1.0,
                            ),
                  boxShadow: widget.isPlaying
                      ? [
                          BoxShadow(
                            color: widget.theme.primaryColor.withOpacity(0.35 * widget.pulseController!.value),
                            blurRadius: 12 + 8 * widget.pulseController!.value,
                            spreadRadius: 1 + 2 * widget.pulseController!.value,
                          )
                        ]
                      : [
                          BoxShadow(
                            color: _isHovered 
                                ? widget.theme.primaryColor.withOpacity(0.15) 
                                : Colors.black.withOpacity(0.2),
                            blurRadius: _isHovered ? 16 : 8,
                            spreadRadius: _isHovered ? 2 : 0,
                            offset: Offset(0, _isHovered ? 6 : 2),
                          )
                        ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 16:9 Thumbnail Header with overlays
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(11),
                          topRight: Radius.circular(11),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Video Thumbnail
                            thumbnailUrl != null
                                ? Image.network(
                                    thumbnailUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      color: const Color(0xFF1F2937),
                                      child: const Icon(Icons.movie, color: Colors.white30, size: 32),
                                    ),
                                  )
                                : Container(
                                    color: const Color(0xFF1F2937),
                                    child: const Icon(Icons.movie, color: Colors.white30, size: 32),
                                  ),

                            // Video Thumbnail Progress Bar
                            if (widget.vod.watchProgress != null && widget.vod.watchProgress! > 0.0)
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: Container(
                                  height: 4,
                                  color: Colors.black45,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: (widget.vod.watchProgress! >= (widget.watchedThreshold / 100.0))
                                          ? 1.0
                                          : widget.vod.watchProgress!.clamp(0.0, 1.0),
                                      child: Container(
                                        color: (widget.vod.watchProgress! >= (widget.watchedThreshold / 100.0))
                                            ? themeNotifier.watchedProgressColor
                                            : themeNotifier.activeProgressColor,
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                            // Top left duration badge
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.75),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      _formatTwitchStyleDuration(widget.vod.duration),
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                                    ),
                                  ),

                                ],
                              ),
                            ),

                            // Top right Overlays (Videogame Badge & NOW PLAYING badge) or Checkbox in multi-select mode
                            Positioned(
                              top: 8,
                              right: 8,
                              child: widget.isMultiSelectMode
                                  ? Container(
                                      decoration: BoxDecoration(
                                        color: widget.isSelected ? widget.theme.primaryColor : Colors.black54,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 1.5),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.3),
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                      width: 24,
                                      height: 24,
                                      child: widget.isSelected
                                          ? const Icon(Icons.check, size: 16, color: Colors.white)
                                          : null,
                                    )
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        if (_games != null && _games!.isNotEmpty) ...[
                                          if (widget.showGamesOnThumbnails)
                                            Container(
                                              constraints: BoxConstraints(maxWidth: widget.scale * 0.5),
                                              child: Wrap(
                                                spacing: 4,
                                                runSpacing: 4,
                                                alignment: WrapAlignment.end,
                                                children: _games!.map((game) {
                                                  return Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black.withOpacity(0.75),
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        const Icon(Icons.sports_esports, size: 9, color: Colors.white70),
                                                        const SizedBox(width: 4),
                                                        Text(
                                                          game,
                                                          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }).toList(),
                                              ),
                                            )
                                          else
                                            Tooltip(
                                              message: _games!.join('\n'),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF161B26),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: const Color(0xFF1E2433)),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black.withOpacity(0.3),
                                                    blurRadius: 6,
                                                  ),
                                                ],
                                              ),
                                              textStyle: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, height: 1.3),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                              preferBelow: true,
                                              child: _buildGameBadge(widget.theme),
                                            ),
                                          const SizedBox(width: 8),
                                        ],
                                        if (widget.isPlaying && widget.pulseController != null)
                                          AnimatedBuilder(
                                            animation: widget.pulseController!,
                                            builder: (context, child) {
                                              return Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: widget.theme.primaryColor.withOpacity(0.85 + 0.15 * widget.pulseController!.value),
                                                  borderRadius: BorderRadius.circular(4),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: widget.theme.primaryColor.withOpacity(0.5 * widget.pulseController!.value),
                                                      blurRadius: 4,
                                                    )
                                                  ]
                                                ),
                                                child: const Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(Icons.play_arrow, size: 10, color: Colors.white),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      'NOW PLAYING',
                                                      style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.5),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                      ],
                                    ),
                            ),

                            // High-Contrast Hover Play Icon Overlay (reveals play button and all games if showGamesOnThumbnails is off)
                            if (!widget.isMultiSelectMode)
                              Positioned.fill(
                                child: AnimatedOpacity(
                                  duration: const Duration(milliseconds: 150),
                                  opacity: _isHovered ? 1.0 : 0.0,
                                  child: Container(
                                    color: Colors.black.withOpacity(0.4),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.black.withOpacity(0.6),
                                            border: Border.all(color: Colors.white.withOpacity(0.8), width: 2.0),
                                          ),
                                          child: const Icon(
                                            Icons.play_arrow,
                                            size: 28,
                                            color: Colors.white,
                                          ),
                                        ),
                                        if (!widget.showGamesOnThumbnails && _games != null && _games!.isNotEmpty) ...[
                                          const SizedBox(height: 12),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 16),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(0.85),
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: Colors.white24, width: 0.5),
                                              ),
                                              child: Text(
                                                _games!.join('  •  '),
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.white,
                                                  letterSpacing: 0.2,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                            // Bottom left views count badge
                            Positioned(
                              bottom: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.75),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '${widget.formatNumber(widget.vod.viewCount)} views',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                              ),
                            ),

                            // Bottom right badge OR download controls
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: (!widget.isMultiSelectMode && (_isHovered || widget.downloadStatus != null || widget.isDownloaded))
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (widget.downloadStatus != null) ...[
                                          // Downloading / queued state
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacity(0.9),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: Colors.greenAccent.withOpacity(0.5), width: 1.0),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (widget.downloadProgress != null) ...[
                                                  SizedBox(
                                                    width: 12,
                                                    height: 12,
                                                    child: CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      value: widget.downloadProgress,
                                                      valueColor: const AlwaysStoppedAnimation(Colors.greenAccent),
                                                      backgroundColor: Colors.white10,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                ],
                                                Text(
                                                  widget.downloadStatus!,
                                                  style: const TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.greenAccent,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (_isHovered) ...[
                                            const SizedBox(width: 6),
                                            _buildCardButton(
                                              onTap: widget.onCancel,
                                              icon: Icons.close,
                                              backgroundColor: Colors.redAccent,
                                              tooltip: 'Cancel Download',
                                            ),
                                          ],
                                        ] else if (widget.isDownloaded) ...[
                                          // Downloaded state: Play and Delete buttons
                                          _buildCardButton(
                                            onTap: widget.onPlay,
                                            icon: Icons.play_arrow,
                                            backgroundColor: Colors.green,
                                            tooltip: 'Play Local VOD',
                                          ),
                                          const SizedBox(width: 6),
                                          _buildCardButton(
                                            onTap: widget.onDeleteDownload,
                                            icon: Icons.delete,
                                            backgroundColor: Colors.redAccent,
                                            tooltip: 'Delete Download',
                                          ),
                                        ] else ...[
                                          // Not downloaded state: Download button on hover
                                          _buildCardButton(
                                            onTap: widget.onDownload,
                                            icon: Icons.download,
                                            backgroundColor: Colors.black.withOpacity(0.8),
                                            tooltip: 'Download VOD',
                                          ),
                                        ]
                                      ],
                                    )
                                  : Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.75),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _timeAgo(widget.vod.publishedAt),
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    
                    // Title text area beneath thumbnail
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            widget.vod.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: widget.fontSize * (1.0 + (widget.scale - 200.0) / 400.0 * 0.8), 
                              fontWeight: FontWeight.bold, 
                              color: Colors.white, 
                              height: 1.25
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

    if (widget.isPlaying && widget.pulseController != null) {
      return AnimatedBuilder(
        animation: widget.pulseController!,
        builder: (context, child) => buildCardContent(),
      );
    }

    return buildCardContent();
  }
}

class VodDownloadTask {
  final TwitchVideo vod;
  final String channelName;
  
  VodDownloadTask({required this.vod, required this.channelName});
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin, WindowListener {
  final List<TwitchChannel> _channels = [];
  TwitchChannel? _selectedChannel;
  bool _isGlobalLoading = false;
  final TextEditingController _searchController = TextEditingController();
  bool _isAdding = false;
  final AppSettings _settings = AppSettings();
  final SystemTray _systemTray = SystemTray();
  final Set<String> _previouslyLiveFavoriteUsernames = {};
  Timer? _favoritesLiveCheckTimer;
  HttpServer? _oauthServer;
  List<TwitchChannel> _followedChannels = [];
  bool _isLoadingFollowed = false;
  String? _authenticatedUserLogin;
  String? _authenticatedUserAvatar;
  int _sidebarTab = 0; // 0 = Custom List, 1 = Followed
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
  Set<String> _selectedGamesFilter = {};
  Timer? _vodProgressTimer;
  int _lastSyncedPosition = 0;
  bool _isWebTokenExpired = false;
  bool _isMultiSelectMode = false;
  final Set<String> _selectedVodIds = {};
  bool _isBulkUpdatingVods = false;
  Map<String, int> _localVodsProgress = {};

  final Map<String, double> _activeDownloadsProgress = {};
  final Map<String, Process> _activeDownloadProcesses = {};
  final Map<String, String> _activeDownloadTasks = {};
  final List<String> _downloadQueue = [];
  final Map<String, VodDownloadTask> _queuedDownloadTasks = {};
  bool _isQueueProcessing = false;
  Set<String> _downloadedVodIds = {};
  Timer? _downloadCheckTimer;

  final Map<String, Process> _activePlayerProcesses = {};
  final Map<String, int> _activePlayerPorts = {};
  final Map<String, Timer> _activePlayerTimers = {};
  final Set<String> _playingVodIds = {};
  final Set<String> _runningChannels = {};

  int _getNextAvailablePlayerPort() {
    int port = 8089;
    while (_activePlayerPorts.containsValue(port)) {
      port++;
    }
    return port;
  }

  void _showSettingsDialog() {
    String tempQuality = _settings.defaultQuality;
    bool tempLowLatency = _settings.twitchLowLatency;
    String tempPlayerType = _settings.playerType;
    int tempWatchedThreshold = _settings.watchedThreshold;
    final tokenController = TextEditingController(text: _settings.twitchOauthToken);
    final webTokenController = TextEditingController(text: _settings.twitchWebOauthToken);
    final playerPathController = TextEditingController(text: _settings.customPlayerPath);
    final playerArgsController = TextEditingController(text: _settings.customPlayerArgs);
    final clientIdController = TextEditingController(text: _settings.twitchClientId);
    final portController = TextEditingController(text: _settings.localServerPort.toString());
    final downloadFolderController = TextEditingController(text: _settings.vodDownloadFolder);
    final maxDownloadsController = TextEditingController(text: _settings.maxDownloadsToKeep == 0 ? '' : _settings.maxDownloadsToKeep.toString());
    bool obscureToken = true;
    bool obscureWebToken = true;
    bool isTestingToken = false;
    String? tokenTestResult;
    bool isTokenValid = false;

    // Capture original theme colors to support Cancel/Rollback
    final origPrimary = parseHexColor(_settings.primaryColorHex, const Color(0xFF9146FF));
    final origBackground = parseHexColor(_settings.backgroundColorHex, const Color(0xFF0C0F17));
    final origSurface = parseHexColor(_settings.surfaceColorHex, const Color(0xFF161B26));
    final origActiveProgress = parseHexColor(_settings.activeProgressColorHex, const Color(0xFF9146FF));
    final origWatchedProgress = parseHexColor(_settings.watchedProgressColorHex, const Color(0x804CAF50));

    Color tempPrimary = origPrimary;
    Color tempBackground = origBackground;
    Color tempSurface = origSurface;
    Color tempActiveProgress = origActiveProgress;
    Color tempWatchedProgress = origWatchedProgress;

    String activeColorKey = 'primary';
    final hexController = TextEditingController(text: colorToHex(tempPrimary));

    showDialog(
      context: context,
      barrierDismissible: false, // Force user to click save/cancel to ensure proper color rollback
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Color getActiveColor() {
              switch (activeColorKey) {
                case 'primary': return tempPrimary;
                case 'background': return tempBackground;
                case 'surface': return tempSurface;
                case 'activeProgress': return tempActiveProgress;
                case 'watchedProgress': return tempWatchedProgress;
                default: return tempPrimary;
              }
            }

            void updateActiveColor(Color c) {
              setDialogState(() {
                switch (activeColorKey) {
                  case 'primary': tempPrimary = c; break;
                  case 'background': tempBackground = c; break;
                  case 'surface': tempSurface = c; break;
                  case 'activeProgress': tempActiveProgress = c; break;
                  case 'watchedProgress': tempWatchedProgress = c; break;
                }
                final activeColor = getActiveColor();
                final hexStr = colorToHex(activeColor);
                if (hexController.text.toUpperCase() != hexStr.toUpperCase()) {
                  hexController.text = hexStr;
                }
              });
              themeNotifier.updateTheme(
                primary: tempPrimary,
                background: tempBackground,
                surface: tempSurface,
                activeProgress: tempActiveProgress,
                watchedProgress: tempWatchedProgress,
              );
            }

            Widget buildColorSlider({
              required String label,
              required double value,
              required Color sliderColor,
              required ValueChanged<double> onChanged,
            }) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70)),
                        Text(value.round().toString(), style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: Colors.white70)),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        activeTrackColor: sliderColor,
                        inactiveTrackColor: Colors.white10,
                        thumbColor: sliderColor,
                      ),
                      child: Slider(
                        value: value,
                        min: 0,
                        max: 255,
                        onChanged: onChanged,
                      ),
                    ),
                  ],
                ),
              );
            }

            final presets = [
              const Color(0xFF9146FF), // Twitch Purple
              const Color(0xFF00F2FE), // Cyan Accent
              const Color(0xFF4CAF50), // Green
              const Color(0xFFF44336), // Red
              const Color(0xFFFF9800), // Orange
              const Color(0xFFFFEB3B), // Yellow
              const Color(0xFFE91E63), // Pink
              const Color(0xFF2196F3), // Blue
              const Color(0xFF0C0F17), // Dark Background
              const Color(0xFF161B26), // Dark Card
            ];

            final activeColor = getActiveColor();

            return DefaultTabController(
              length: 3,
              child: AlertDialog(
                titlePadding: EdgeInsets.zero,
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                      child: Row(
                        children: [
                          Icon(Icons.settings, color: themeNotifier.primaryColor),
                          const SizedBox(width: 10),
                          const Text('Streamlink Settings'),
                        ],
                      ),
                    ),
                    TabBar(
                      labelColor: themeNotifier.primaryColor,
                      unselectedLabelColor: Colors.white60,
                      indicatorColor: themeNotifier.primaryColor,
                      indicatorSize: TabBarIndicatorSize.tab,
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      tabs: const [
                        Tab(text: 'General'),
                        Tab(text: 'Theme & Colors'),
                        Tab(text: 'Downloads'),
                      ],
                    ),
                  ],
                ),
                backgroundColor: themeNotifier.surfaceColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                content: SizedBox(
                  width: 500,
                  height: 520,
                  child: TabBarView(
                    children: [
                      // TAB 1: GENERAL SETTINGS
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Default Video Quality',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: tempQuality,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: 12),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'best', child: Text('Best Available')),
                                DropdownMenuItem(value: '1080p60', child: Text('1080p 60fps')),
                                DropdownMenuItem(value: '1080p', child: Text('1080p')),
                                DropdownMenuItem(value: '720p60', child: Text('720p 60fps')),
                                DropdownMenuItem(value: '720p', child: Text('720p')),
                                DropdownMenuItem(value: '480p', child: Text('480p')),
                                DropdownMenuItem(value: 'worst', child: Text('Worst Available')),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() => tempQuality = val);
                                }
                              },
                            ),
                            const SizedBox(height: 18),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Twitch Low Latency', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              subtitle: const Text('Reduces live stream delay, but may increase buffering on slow networks.', style: TextStyle(fontSize: 11)),
                              value: tempLowLatency,
                              activeColor: themeNotifier.primaryColor,
                              onChanged: (val) {
                                setDialogState(() => tempLowLatency = val);
                              },
                            ),
                            const SizedBox(height: 12),
                            const Divider(color: Colors.white12),
                            const SizedBox(height: 12),
                            const Text('Video Player Selection', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: tempPlayerType,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: 12),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'default', child: Text('System / Streamlink Default')),
                                DropdownMenuItem(value: 'vlc', child: Text('Force VLC Player')),
                                DropdownMenuItem(value: 'mpv', child: Text('Force MPV Player')),
                                DropdownMenuItem(value: 'custom', child: Text('Use Custom Executable Path')),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() => tempPlayerType = val);
                                }
                              },
                            ),
                            if (tempPlayerType == 'custom') ...[
                              const SizedBox(height: 14),
                              const Text('Custom Player Executable Path', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              const SizedBox(height: 6),
                              TextField(
                                controller: playerPathController,
                                style: const TextStyle(fontSize: 13),
                                decoration: const InputDecoration(
                                  hintText: 'e.g. C:\\Program Files\\VideoLAN\\VLC\\vlc.exe',
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            Text('Watched VOD Completion Threshold: $tempWatchedThreshold%', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Text('50%', style: TextStyle(fontSize: 11, color: Colors.white30)),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                      activeTrackColor: themeNotifier.primaryColor,
                                      inactiveTrackColor: Colors.white10,
                                      thumbColor: themeNotifier.primaryColor,
                                    ),
                                    child: Slider(
                                      value: tempWatchedThreshold.toDouble(),
                                      min: 50.0,
                                      max: 100.0,
                                      divisions: 50,
                                      onChanged: (val) {
                                        setDialogState(() {
                                          tempWatchedThreshold = val.round();
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                const Text('100%', style: TextStyle(fontSize: 11, color: Colors.white30)),
                              ],
                            ),
                            const SizedBox(height: 18),
                            const Text('Custom Player Arguments (Optional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: playerArgsController,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                hintText: 'e.g. --ontop --no-border (for mpv)',
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Divider(color: Colors.white12),
                            const SizedBox(height: 12),
                            const Text('Twitch API Authentication', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: themeNotifier.backgroundColor,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            _settings.twitchOauthToken.trim().isNotEmpty ? Icons.check_circle : Icons.error_outline,
                                            color: _settings.twitchOauthToken.trim().isNotEmpty ? Colors.green : Colors.orange,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _settings.twitchOauthToken.trim().isNotEmpty
                                                ? (_authenticatedUserLogin != null ? 'Connected: $_authenticatedUserLogin' : 'Connected')
                                                : 'Not connected',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: _settings.twitchOauthToken.trim().isNotEmpty ? Colors.green : Colors.orange,
                                            ),
                                          ),
                                        ],
                                      ),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: themeNotifier.primaryColor,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () {
                                          _startOAuthServer();
                                          Navigator.pop(context);
                                        },
                                        icon: const Icon(Icons.login, size: 12, color: Colors.white),
                                        label: const Text('Connect Account', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                                      ),
                                    ],
                                  ),
                                  if (_settings.twitchOauthToken.trim().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    const Text(
                                      'Connecting allows you to automatically load your followed channels, view channel VOD lists, stream subscriber-only feeds, and remove ads.',
                                      style: TextStyle(fontSize: 10, color: Colors.white38, height: 1.4),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('Twitch Client ID', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                      const SizedBox(height: 4),
                                      TextField(
                                        controller: clientIdController,
                                        style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                                        decoration: const InputDecoration(
                                          hintText: 'Twitch Client ID',
                                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('Local Port', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                      const SizedBox(height: 4),
                                      TextField(
                                        controller: portController,
                                        style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          hintText: '65432',
                                          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Twitch OAuth Token (Optional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                TextButton(
                                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                  onPressed: () => _openExternalLink('https://twitchapps.com/tmi/'),
                                  child: const Text('Get Token Manually', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: tokenController,
                              obscureText: obscureToken,
                              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                              decoration: InputDecoration(
                                hintText: 'oauth:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                suffixIcon: IconButton(
                                  icon: Icon(obscureToken ? Icons.visibility : Icons.visibility_off, size: 16),
                                  onPressed: () => setDialogState(() => obscureToken = !obscureToken),
                                  constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Twitch Browser Token (Optional, for VOD Sync)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                IconButton(
                                  icon: const Icon(Icons.help_outline, size: 16),
                                  color: themeNotifier.primaryColor,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _showBrowserTokenHelp(context),
                                  tooltip: 'How to get Browser Token',
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: webTokenController,
                                    obscureText: obscureWebToken,
                                    style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                                    decoration: InputDecoration(
                                      hintText: 'e.g. 5vnv4iix6wz8y31ok3p7xlccuyb72s',
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      suffixIcon: IconButton(
                                        icon: Icon(obscureWebToken ? Icons.visibility : Icons.visibility_off, size: 16),
                                        onPressed: () => setDialogState(() => obscureWebToken = !obscureWebToken),
                                        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  height: 36,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isTestingToken ? const Color(0xFF1E2433) : themeNotifier.primaryColor,
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                    ),
                                    onPressed: isTestingToken
                                        ? null
                                        : () async {
                                            final rawInput = webTokenController.text.trim();
                                            if (rawInput.isEmpty) {
                                              setDialogState(() {
                                                tokenTestResult = 'Please enter a token first.';
                                                isTokenValid = false;
                                              });
                                              return;
                                            }
                                            setDialogState(() {
                                              isTestingToken = true;
                                              tokenTestResult = null;
                                            });

                                            String testToken = rawInput;
                                            if (testToken.startsWith('oauth:')) {
                                              testToken = testToken.substring(6);
                                            }

                                            try {
                                              final valUrl = Uri.parse('https://id.twitch.tv/oauth2/validate');
                                              final valRes = await http.get(valUrl, headers: {
                                                'Authorization': 'OAuth $testToken',
                                              }).timeout(const Duration(seconds: 5));

                                              if (valRes.statusCode == 200) {
                                                final decoded = json.decode(valRes.body);
                                                final login = decoded['login'] as String?;
                                                setDialogState(() {
                                                  isTestingToken = false;
                                                  isTokenValid = true;
                                                  tokenTestResult = 'Success! Connected as: $login';
                                                });
                                              } else {
                                                setDialogState(() {
                                                  isTestingToken = false;
                                                  isTokenValid = false;
                                                  tokenTestResult = 'Invalid token (Status ${valRes.statusCode})';
                                                });
                                              }
                                            } catch (e) {
                                              setDialogState(() {
                                                isTestingToken = false;
                                                isTokenValid = false;
                                                tokenTestResult = 'Connection error: $e';
                                              });
                                            }
                                          },
                                    child: isTestingToken
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white60),
                                          )
                                        : const Text('Test', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                              ],
                            ),
                            if (tokenTestResult != null) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    isTokenValid ? Icons.check_circle : Icons.error,
                                    size: 14,
                                    color: isTokenValid ? Colors.green : Colors.redAccent,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      tokenTestResult!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isTokenValid ? Colors.green : Colors.redAccent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),

                      // TAB 2: THEME & COLOR SETTINGS
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Choose Custom Color to Edit',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: activeColorKey,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: 12),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'primary', child: Text('Primary Color (Highlights & Active Buttons)')),
                                DropdownMenuItem(value: 'background', child: Text('Scaffold Background Color')),
                                DropdownMenuItem(value: 'surface', child: Text('Card / Sidebar / Dialog Background')),
                                DropdownMenuItem(value: 'activeProgress', child: Text('In-Progress VOD Color')),
                                DropdownMenuItem(value: 'watchedProgress', child: Text('Fully Watched VOD Color')),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() {
                                    activeColorKey = val;
                                    hexController.text = colorToHex(getActiveColor());
                                  });
                                }
                              },
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: activeColor,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.white24, width: 1.5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.3),
                                        blurRadius: 4,
                                      )
                                    ]
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: TextField(
                                    controller: hexController,
                                    style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
                                    decoration: const InputDecoration(
                                      labelText: 'Hex Color Value',
                                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    ),
                                    onChanged: (val) {
                                      final newCol = parseHexColor(val, getActiveColor());
                                      if (newCol != getActiveColor()) {
                                        updateActiveColor(newCol);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            buildColorSlider(
                              label: 'Red Channel',
                              value: activeColor.red.toDouble(),
                              sliderColor: Colors.redAccent,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(activeColor.alpha, val.round(), activeColor.green, activeColor.blue));
                              },
                            ),
                            buildColorSlider(
                              label: 'Green Channel',
                              value: activeColor.green.toDouble(),
                              sliderColor: Colors.greenAccent,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(activeColor.alpha, activeColor.red, val.round(), activeColor.blue));
                              },
                            ),
                            buildColorSlider(
                              label: 'Blue Channel',
                              value: activeColor.blue.toDouble(),
                              sliderColor: Colors.blueAccent,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(activeColor.alpha, activeColor.red, activeColor.green, val.round()));
                              },
                            ),
                            buildColorSlider(
                              label: 'Opacity (Alpha Channel)',
                              value: activeColor.alpha.toDouble(),
                              sliderColor: Colors.white70,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(val.round(), activeColor.red, activeColor.green, activeColor.blue));
                              },
                            ),
                            const SizedBox(height: 18),
                            const Text(
                              'Quick Presets Swatches',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white70),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: presets.map((preset) {
                                final isSelected = activeColor.value == preset.value;
                                return GestureDetector(
                                  onTap: () {
                                    updateActiveColor(preset);
                                  },
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color: preset,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected ? Colors.white : Colors.white24,
                                        width: isSelected ? 2.5 : 1.0,
                                      ),
                                      boxShadow: [
                                        if (isSelected)
                                          BoxShadow(
                                            color: preset.withOpacity(0.5),
                                            blurRadius: 6,
                                          )
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('VOD Download Directory', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: downloadFolderController,
                                    style: const TextStyle(fontSize: 13),
                                    decoration: const InputDecoration(
                                      hintText: 'e.g. C:\\Downloads\\TwitchVODs',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: themeNotifier.primaryColor,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                                  ),
                                  onPressed: () async {
                                    final result = await Process.run('powershell', [
                                      '-Command',
                                      'Add-Type -AssemblyName System.Windows.Forms; \$f = New-Object System.Windows.Forms.FolderBrowserDialog; if (\$f.ShowDialog() -eq \'OK\') { \$f.SelectedPath }'
                                    ]);
                                    if (result.exitCode == 0) {
                                      final path = result.stdout.toString().trim();
                                      if (path.isNotEmpty) {
                                        setDialogState(() {
                                          downloadFolderController.text = path;
                                        });
                                      }
                                    }
                                  },
                                  icon: const Icon(Icons.folder_open, color: Colors.white, size: 16),
                                  label: const Text('Browse', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            const Text('Maximum downloads to keep (Threshold)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 4),
                            const Text('Delete oldest downloads automatically when limit is reached. Leave empty or set to 0 for unlimited.', style: TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: maxDownloadsController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                hintText: 'e.g. 5, 10, or leave empty',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      themeNotifier.updateTheme(
                        primary: origPrimary,
                        background: origBackground,
                        surface: origSurface,
                        activeProgress: origActiveProgress,
                        watchedProgress: origWatchedProgress,
                      );
                      Navigator.pop(context);
                    },
                    child: const Text('Cancel', style: TextStyle(color: Colors.white30)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.primaryColor),
                    onPressed: () async {
                      setState(() {
                        _settings.defaultQuality = tempQuality;
                        _settings.twitchLowLatency = tempLowLatency;
                        _settings.playerType = tempPlayerType;
                        _settings.watchedThreshold = tempWatchedThreshold;
                        _settings.twitchOauthToken = tokenController.text.trim();
                        _settings.twitchWebOauthToken = webTokenController.text.trim();
                        _settings.customPlayerPath = playerPathController.text.trim();
                        _settings.customPlayerArgs = playerArgsController.text.trim();
                        _settings.twitchClientId = clientIdController.text.trim();
                        _settings.localServerPort = int.tryParse(portController.text.trim()) ?? 65432;
                        _settings.vodDownloadFolder = downloadFolderController.text.trim();
                        _settings.maxDownloadsToKeep = int.tryParse(maxDownloadsController.text.trim()) ?? 0;
                        _isWebTokenExpired = false;

                        _settings.primaryColorHex = colorToHex(tempPrimary);
                        _settings.backgroundColorHex = colorToHex(tempBackground);
                        _settings.surfaceColorHex = colorToHex(tempSurface);
                        _settings.activeProgressColorHex = colorToHex(tempActiveProgress);
                        _settings.watchedProgressColorHex = colorToHex(tempWatchedProgress);
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

                      if (context.mounted) {
                        Navigator.pop(context);
                        _showSnackBar('Settings saved successfully!', isError: false);
                      }
                    },
                    child: const Text('Save Changes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showBrowserTokenHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.help_outline, color: theme.primaryColor),
              const SizedBox(width: 10),
              const Text('How to get Browser Token'),
            ],
          ),
          backgroundColor: const Color(0xFF161B26),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'To enable background watch progress syncing and VOD progress bars, you must copy your first-party browser login token from Twitch:',
                    style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  _buildStep(
                    '1',
                    'Open your web browser (Chrome, Firefox, Edge, etc.), go to twitch.tv, and make sure you are logged in to your account.',
                  ),
                  const SizedBox(height: 12),
                  _buildStep(
                    '2',
                    'Press F12 (or right-click anywhere on the page and select Inspect) to open the Developer Tools panel.',
                  ),
                  const SizedBox(height: 12),
                  _buildStep(
                    '3',
                    'Locate your cookies:\n'
                    '• Chrome/Edge/Opera: Go to the Application tab -> expand Cookies on the left -> select https://www.twitch.tv\n'
                    '• Firefox: Go to the Storage tab -> expand Cookies -> select https://www.twitch.tv',
                  ),
                  const SizedBox(height: 12),
                  _buildStep(
                    '4',
                    'In the list of cookies, find the one named auth-token. Double-click its value, copy it, and paste it into the settings field.',
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.info, size: 14, color: Colors.white30),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Note: Do NOT click "Log Out" on the Twitch website after copying this token. Clicking log out will immediately revoke the token on Twitch\'s servers.',
                          style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.4), height: 1.3),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor),
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStep(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFF1E2433),
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.35),
          ),
        ),
      ],
    );
  }

  // Streamlink Process State

  bool _consoleCollapsed = false;
  final Map<String, List<String>> _playerLogs = {};
  final Map<String, String> _playerTabTitles = {};
  String? _selectedConsoleTabKey;
  final Map<String, ScrollController> _playerScrollControllers = {};


  void _addPlayerLogLine(String key, String line) {
    if (!mounted) return;
    setState(() {
      final logs = _playerLogs.putIfAbsent(key, () => []);
      logs.add(line);
    });
    
    if (key == _selectedConsoleTabKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final controller = _playerScrollControllers[key];
        if (controller != null && controller.hasClients) {
          controller.animateTo(
            controller.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initSystemTray();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
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
    for (final proc in _activePlayerProcesses.values) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
    _activePlayerProcesses.clear();
    for (final timer in _activePlayerTimers.values) {
      timer.cancel();
    }
    _activePlayerTimers.clear();
    _searchController.dispose();
    for (final ctrl in _playerScrollControllers.values) {
      ctrl.dispose();
    }
    _playerScrollControllers.clear();
    _oauthServer?.close(force: true);
    _downloadCheckTimer?.cancel();
    _favoritesLiveCheckTimer?.cancel();
    for (final proc in _activeDownloadProcesses.values) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
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

    final hasUnfinished = _activeDownloadProcesses.isNotEmpty || _downloadQueue.isNotEmpty;
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
      
      for (final vodId in _activeDownloadProcesses.keys) {
        final task = _queuedDownloadTasks[vodId];
        if (task != null) {
          unfinishedList.add({
            'vod': task.vod.toJson(),
            'channelName': task.channelName,
          });
        }
      }
      
      for (final vodId in _downloadQueue) {
        final task = _queuedDownloadTasks[vodId];
        if (task != null) {
          unfinishedList.add({
            'vod': task.vod.toJson(),
            'channelName': task.channelName,
          });
        }
      }

      setState(() {
        _settings.unfinishedDownloads = unfinishedList;
      });
      _saveChannels();
    }

    for (final proc in _activePlayerProcesses.values) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
    _activePlayerProcesses.clear();

    for (final proc in _activeDownloadProcesses.values) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
    _activeDownloadProcesses.clear();

    await windowManager.destroy();
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

  File _getStorageFile() {
    try {
      final exePath = Platform.resolvedExecutable;
      if (exePath.contains('flutter_tester') || exePath.contains('flutter_tools') || exePath.contains('dart')) {
        return File('channels_config.json');
      }
      final exeDir = Directory(exePath).parent.path;
      final exeFile = File('$exeDir/channels_config.json');

      // Helper to check if a directory is writable by attempting to create and delete a temporary file
      bool isDirWritable(String path) {
        try {
          final testFile = File('$path/.write_test');
          testFile.writeAsStringSync('test');
          testFile.deleteSync();
          return true;
        } catch (_) {
          return false;
        }
      }

      // If the executable directory is writable, keep portable mode configuration in exeDir
      if (isDirWritable(exeDir)) {
        return exeFile;
      }

      // If not writable (e.g., Program Files), use the user's AppData/Config directory
      String? appDataDir;
      if (Platform.isWindows) {
        appDataDir = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'];
      } else if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          appDataDir = '$home/Library/Application Support';
        }
      } else if (Platform.isLinux) {
        appDataDir = Platform.environment['XDG_CONFIG_HOME'];
        if (appDataDir == null || appDataDir.isEmpty) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            appDataDir = '$home/.config';
          }
        }
      }

      if (appDataDir != null) {
        final configDir = Directory('$appDataDir/TwitchStreamlinkGUI');
        final appDataFile = File('${configDir.path}/channels_config.json');

        // Migrate existing config file from exeDir if it exists but the AppData config doesn't
        if (!appDataFile.existsSync() && exeFile.existsSync()) {
          try {
            if (!configDir.existsSync()) {
              configDir.createSync(recursive: true);
            }
            exeFile.copySync(appDataFile.path);
          } catch (_) {
            // Ignore migration failure, fallback to clean config creation
          }
        } else if (!appDataFile.existsSync()) {
          try {
            if (!configDir.existsSync()) {
              configDir.createSync(recursive: true);
            }
          } catch (_) {}
        }
        return appDataFile;
      }

      return exeFile;
    } catch (_) {
      return File('channels_config.json');
    }
  }

  File? _getDownloadedVodFile(String vodId, String channelName) {
    if (_settings.vodDownloadFolder.trim().isEmpty) return null;
    final dir = Directory(
      '${_settings.vodDownloadFolder.trim()}/$channelName'
    );
    if (!dir.existsSync()) return null;
    try {
      final files = dir.listSync();
      for (final file in files) {
        if (file is File) {
          final name = file.path;
          if (RegExp(' - $vodId\\.[a-zA-Z0-9]+\$').hasMatch(name)) {
            return file;
          }
        }
      }
    } catch (_) {}
    return null;
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
    for (final vod in _channelVods) {
      final file = _getDownloadedVodFile(vod.id, _selectedChannel?.username ?? '');
      if (file != null) {
        newDownloaded.add(vod.id);
      }
    }
    
    if (mounted) {
      setState(() {
        _downloadedVodIds = newDownloaded;
      });
    }
  }

  Future<void> _startVodDownload(TwitchVideo vod, String channelName) async {
    if (_settings.vodDownloadFolder.trim().isEmpty) {
      _showSnackBar('Please configure a VOD Download Folder in Settings first.', isError: true);
      return;
    }
    
    final outputDir = Directory('${_settings.vodDownloadFolder.trim()}/$channelName');
    if (!outputDir.existsSync()) {
      try {
        outputDir.createSync(recursive: true);
      } catch (e) {
        _showSnackBar('Failed to create download folder: $e', isError: true);
        return;
      }
    }

    final vodId = vod.id;
    setState(() {
      _activeDownloadsProgress[vodId] = 0.0;
      _activeDownloadTasks[vodId] = 'Starting...';
    });

    final outputTemplate = '${outputDir.path}/%(title)s - %(id)s.%(ext)s';
    final url = 'https://twitch.tv/videos/$vodId';
    
    try {
      final proc = await Process.start(
        'yt-dlp',
        ['-o', outputTemplate, url],
        runInShell: true,
      );
      
      _activeDownloadProcesses[vodId] = proc;
      
      proc.stdout.transform(utf8.decoder).listen((line) {
        final pctMatch = RegExp(r'(\d+\.\d+)%').firstMatch(line);
        final speedMatch = RegExp(r'at\s+(\S+)').firstMatch(line);
        
        double? pct;
        String? speed;
        if (pctMatch != null) {
          pct = double.tryParse(pctMatch.group(1)!);
        }
        if (speedMatch != null) {
          speed = speedMatch.group(1);
        }
        
        if (pct != null && mounted) {
          setState(() {
            _activeDownloadsProgress[vodId] = pct! / 100.0;
            if (speed != null) {
              _activeDownloadTasks[vodId] = 'Downloading: ${pct.toStringAsFixed(1)}% ($speed)';
            } else {
              _activeDownloadTasks[vodId] = 'Downloading: ${pct.toStringAsFixed(1)}%';
            }
          });
        }
      });
      
      proc.stderr.transform(utf8.decoder).listen((line) {});

      final exitCode = await proc.exitCode;
      
      if (mounted) {
        setState(() {
          _activeDownloadProcesses.remove(vodId);
          _activeDownloadsProgress.remove(vodId);
          _activeDownloadTasks.remove(vodId);
        });
      }
      
      if (exitCode == 0) {
        _checkDownloadedVods();
        _showSnackBar('Download completed: ${vod.title}', isError: false);
        _cleanupOldestDownloads();
      } else {
        _showSnackBar('Download failed for: ${vod.title} (Exit code $exitCode)', isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _activeDownloadProcesses.remove(vodId);
          _activeDownloadsProgress.remove(vodId);
          _activeDownloadTasks.remove(vodId);
        });
      }
      _showSnackBar('Failed to run yt-dlp: $e. Ensure it is installed and in your PATH.', isError: true);
    }
  }

  void _cleanupOldestDownloads() {
    if (_settings.maxDownloadsToKeep <= 0) return;
    if (_settings.vodDownloadFolder.trim().isEmpty) return;

    final mainDir = Directory(_settings.vodDownloadFolder.trim());
    if (!mainDir.existsSync()) return;

    try {
      final allFiles = <File>[];
      final entities = mainDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.path;
          if (RegExp(r' - \d+\.[a-zA-Z0-9]+$').hasMatch(name)) {
            allFiles.add(entity);
          }
        }
      }

      if (allFiles.length > _settings.maxDownloadsToKeep) {
        allFiles.sort((a, b) {
          try {
            return a.lastModifiedSync().compareTo(b.lastModifiedSync());
          } catch (_) {
            return 0;
          }
        });

        int deletedCount = 0;
        while (allFiles.length > _settings.maxDownloadsToKeep) {
          final oldestFile = allFiles.removeAt(0);
          try {
            if (oldestFile.existsSync()) {
              oldestFile.deleteSync();
              deletedCount++;
            }
          } catch (_) {}
        }

        if (deletedCount > 0) {
          _checkDownloadedVods();
          _showSnackBar('Cleaned up $deletedCount oldest local VOD(s) to stay within keep limit.', isError: false);
        }
      }
    } catch (_) {}
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
                final result = await Process.run('powershell', [
                  '-Command',
                  'Add-Type -AssemblyName System.Windows.Forms; \$f = New-Object System.Windows.Forms.FolderBrowserDialog; if (\$f.ShowDialog() -eq \'OK\') { \$f.SelectedPath }'
                ]);
                if (result.exitCode == 0) {
                  final path = result.stdout.toString().trim();
                  if (path.isNotEmpty) {
                    setState(() {
                      _settings.vodDownloadFolder = path;
                    });
                    await _saveChannels();
                    _checkDownloadedVods();
                    if (context.mounted) {
                      Navigator.pop(context, true);
                    }
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

  Future<void> _cancelVodDownload(String vodId, String channelName) async {
    final proc = _activeDownloadProcesses[vodId];
    if (proc != null) {
      try {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
    
    _downloadQueue.remove(vodId);
    _queuedDownloadTasks.remove(vodId);
    
    setState(() {
      _activeDownloadProcesses.remove(vodId);
      _activeDownloadsProgress.remove(vodId);
      _activeDownloadTasks.remove(vodId);
    });
    
    _showSnackBar('Download cancelled.', isError: true);

    final filesToDelete = <File>[];
    if (_settings.vodDownloadFolder.trim().isNotEmpty) {
      final dir = Directory('${_settings.vodDownloadFolder.trim()}/$channelName');
      if (dir.existsSync()) {
        try {
          final files = dir.listSync();
          for (final file in files) {
            if (file is File) {
              final name = file.path;
              if (name.contains(' - $vodId')) {
                filesToDelete.add(file);
              }
            }
          }
        } catch (_) {}
      }
    }

    if (filesToDelete.isNotEmpty) {
      if (!mounted) return;
      final bool? deleteConfirm = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Delete Incomplete Files?'),
            content: Text('The download was cancelled. Do you want to delete the ${filesToDelete.length} incomplete temporary files from your disk?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep Files'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete Files'),
              ),
            ],
          );
        },
      );

      if (deleteConfirm == true) {
        for (final file in filesToDelete) {
          try {
            if (file.existsSync()) {
              file.deleteSync();
            }
          } catch (_) {}
        }
        _checkDownloadedVods();
        _showSnackBar('Deleted incomplete download files.', isError: false);
      }
    }
  }

  void _queueVodDownload(TwitchVideo vod, String channelName) {
    _ensureDownloadFolderConfigured(() {
      final vodId = vod.id;
    if (_queuedDownloadTasks.containsKey(vodId) || _activeDownloadProcesses.containsKey(vodId)) {
      _showSnackBar('VOD is already downloading or queued: ${vod.title}', isError: false);
      return;
    }
    
    _queuedDownloadTasks[vodId] = VodDownloadTask(vod: vod, channelName: channelName);
    _downloadQueue.add(vodId);
    setState(() {
      _activeDownloadTasks[vodId] = 'Queued';
    });
    
    _processDownloadQueue();
    });
  }

  Future<void> _processDownloadQueue() async {
    if (_isQueueProcessing) return;
    _isQueueProcessing = true;
    
    while (_downloadQueue.isNotEmpty) {
      final vodId = _downloadQueue.first;
      final task = _queuedDownloadTasks[vodId];
      if (task != null) {
        await _startVodDownload(task.vod, task.channelName);
      }
      if (mounted) {
        setState(() {
          _downloadQueue.remove(vodId);
          _queuedDownloadTasks.remove(vodId);
        });
      }
    }
    
    _isQueueProcessing = false;
  }

  Future<void> _deleteDownloadedVod(String vodId, String channelName) async {
    final file = _getDownloadedVodFile(vodId, channelName);
    if (file != null && file.existsSync()) {
      try {
        file.deleteSync();
        _checkDownloadedVods();
        _showSnackBar('Deleted download for VOD ID: $vodId', isError: false);
      } catch (e) {
        _showSnackBar('Failed to delete VOD file: $e', isError: true);
      }
    } else {
      _showSnackBar('Downloaded file not found.', isError: true);
    }
  }

  Future<void> _playDownloadedVod(File file, TwitchVideo vod) async {
    final path = file.path;
    final args = <String>[];
    String exe = '';
    
    final seekTime = (vod.watchPosition != null && vod.watchPosition! > 10) ? vod.watchPosition! : 0;
    final watchedThresholdPct = _settings.watchedThreshold / 100.0;
    final isFullyWatched = vod.watchProgress != null && vod.watchProgress! >= watchedThresholdPct;
    final finalSeek = isFullyWatched ? 0 : seekTime;

    final port = _getNextAvailablePlayerPort();

    if (_settings.playerType == 'vlc') {
      exe = 'vlc';
      if (finalSeek > 0) {
        args.add('--start-time=$finalSeek');
      }
      args.addAll(['--extraintf=http', '--http-port=$port', '--http-password=streamlink']);
      args.add(path);
    } else if (_settings.playerType == 'mpv') {
      exe = 'mpv';
      if (finalSeek > 0) {
        args.add('--start=$finalSeek');
      }
      args.add('--input-ipc-server=127.0.0.1:$port');
      args.add(path);
    } else if (_settings.playerType == 'custom' && _settings.customPlayerPath.trim().isNotEmpty) {
      exe = _settings.customPlayerPath.trim();
      final lowerPath = exe.toLowerCase();
      if (lowerPath.contains('vlc')) {
        if (finalSeek > 0) {
          args.add('--start-time=$finalSeek');
        }
        args.addAll(['--extraintf=http', '--http-port=$port', '--http-password=streamlink']);
      } else if (lowerPath.contains('mpv')) {
        if (finalSeek > 0) {
          args.add('--start=$finalSeek');
        }
        args.add('--input-ipc-server=127.0.0.1:$port');
      }
      args.add(path);
    } else {
      exe = 'cmd';
      args.addAll(['/c', 'start', '""', path]);
    }

    try {
      final key = vod.id;
      final title = 'Local: ${vod.title}';
      setState(() {
        _playingVodIds.add(vod.id);
        _activePlayerPorts[vod.id] = port;
        _playerTabTitles[key] = title;
        _playerLogs[key] = [];
        _playerScrollControllers.putIfAbsent(key, () => ScrollController());
        _selectedConsoleTabKey = key;
        _consoleCollapsed = false;
      });

      _addPlayerLogLine(key, '[System] Initializing local player for VOD ${vod.id}...');
      _addPlayerLogLine(key, '[System] Seek time offset: ${finalSeek}s');
      _addPlayerLogLine(key, '[System] Running local file command: $exe ${args.join(" ")}');

      final proc = await Process.start(
        exe,
        args,
        runInShell: true,
      );

      _activePlayerProcesses[vod.id] = proc;
      _startVODProgressTracker(vod, port);

      proc.exitCode.then((exitCode) {
        _addPlayerLogLine(key, '[System] Local player process exited with code $exitCode');
        if (mounted) {
          setState(() {
            _playingVodIds.remove(vod.id);
            _activePlayerProcesses.remove(vod.id);
            _activePlayerPorts.remove(vod.id);
            _stopVODProgressTracker(vod.id);
          });
        }
      });
    } catch (e) {
      final key = vod.id;
      _addPlayerLogLine(key, '[System Error] Failed to launch local player: $e');
      setState(() {
        _playingVodIds.remove(vod.id);
        _activePlayerPorts.remove(vod.id);
      });
      _showSnackBar('Failed to play local VOD: $e', isError: true);
    }
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
        _queueVodDownload(vod, channelName);
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
        _queueVodDownload(vod, channelName);
      }
    }
  }

  void _bulkDownloadSelectedVods() {
    if (_selectedVodIds.isEmpty) return;
    final selectedVods = _channelVods.where((v) => _selectedVodIds.contains(v.id)).toList();
    if (selectedVods.isEmpty) return;
    
    _ensureDownloadFolderConfigured(() {
      if (selectedVods.length == 1) {
        _queueVodDownload(selectedVods.first, _selectedChannel?.username ?? 'VOD');
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

  Future<void> _bulkDeleteSelectedVods() async {
    final toDelete = <TwitchVideo>[];
    final channelName = _selectedChannel?.username ?? '';
    for (final id in _selectedVodIds) {
      final vod = _channelVods.firstWhere((v) => v.id == id);
      if (_getDownloadedVodFile(id, channelName) != null) {
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
          title: const Text('Delete VOD Downloads'),
          content: Text('Are you sure you want to delete the downloaded files for ${toDelete.length} VODs?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    
    if (confirm != true) return;
    
    int count = 0;
    for (final vod in toDelete) {
      final file = _getDownloadedVodFile(vod.id, channelName);
      if (file != null && file.existsSync()) {
        try {
          file.deleteSync();
          count++;
        } catch (_) {}
      }
    }
    
    _checkDownloadedVods();
    setState(() {
      _selectedVodIds.clear();
      _isMultiSelectMode = false;
    });
    _showSnackBar('Deleted $count downloaded VOD files.', isError: false);
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
          
          final vodId = vod.id;
          if (!_queuedDownloadTasks.containsKey(vodId) && !_activeDownloadProcesses.containsKey(vodId)) {
            final task = VodDownloadTask(vod: vod, channelName: channelName);
            _queuedDownloadTasks[vodId] = task;
            _downloadQueue.add(vodId);
            _activeDownloadTasks[vodId] = 'Queued';
            _activeDownloadsProgress[vodId] = 0.0;
            resumedCount++;
          }
        }
      } catch (e) {
        print('[Resume Downloads] Failed to parse item: $e');
      }
    }
    
    if (resumedCount > 0) {
      _showSnackBar('Resumed $resumedCount unfinished downloads.', isError: false);
      _processDownloadQueue();
    }
  }

  // Load channels from local configuration file
  Future<void> _loadChannels() async {
    setState(() => _isGlobalLoading = true);
    try {
      final file = _getStorageFile();
      List<String> usernames = [];

      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = json.decode(content);
          if (decoded is List) {
            usernames = decoded.map((item) => item.toString()).toList();
          } else if (decoded is Map) {
            final channelsJson = decoded['channels'];
            if (channelsJson is List) {
              usernames = channelsJson.map((item) => item.toString()).toList();
            }
            final settingsJson = decoded['settings'];
            if (settingsJson is Map<String, dynamic>) {
              setState(() {
                _settings.defaultQuality = settingsJson['default_quality'] ?? 'best';
                _settings.twitchLowLatency = settingsJson['twitch_low_latency'] ?? true;
                _settings.twitchOauthToken = settingsJson['twitch_oauth_token'] ?? '';
                _settings.twitchWebOauthToken = settingsJson['twitch_web_oauth_token'] ?? '';
                _settings.playerType = settingsJson['player_type'] ?? 'default';
                _settings.customPlayerPath = settingsJson['custom_player_path'] ?? '';
                _settings.customPlayerArgs = settingsJson['custom_player_args'] ?? '';
                _settings.twitchClientId = settingsJson['twitch_client_id'] ?? 'kimne78kx3ncx6brgo4mv6wki5h1ko';
                _settings.localServerPort = settingsJson['local_server_port'] ?? 65432;
                _settings.watchedThreshold = settingsJson['watched_threshold'] ?? 96;
                _settings.sidebarCollapsed = settingsJson['sidebar_collapsed'] ?? false;
                _sidebarCollapsed = _settings.sidebarCollapsed;
                _settings.primaryColorHex = settingsJson['primary_color_hex'] ?? '#9146FF';
                _settings.backgroundColorHex = settingsJson['background_color_hex'] ?? '#0C0F17';
                _settings.surfaceColorHex = settingsJson['surface_color_hex'] ?? '#161B26';
                _settings.activeProgressColorHex = settingsJson['active_progress_color_hex'] ?? '#9146FF';
                _settings.watchedProgressColorHex = settingsJson['watched_progress_color_hex'] ?? '#804CAF50';
                _settings.vodDownloadFolder = settingsJson['vod_download_folder'] ?? '';
                _settings.maxDownloadsToKeep = settingsJson['max_downloads_to_keep'] ?? 0;
                _settings.unfinishedDownloads = settingsJson['unfinished_downloads'] ?? const [];
                 
                if (_settings.unfinishedDownloads.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _resumeUnfinishedDownloads();
                  });
                }
                
                if (_settings.vodDownloadFolder.isEmpty && Platform.environment['USERPROFILE'] != null) {
                  _settings.vodDownloadFolder = '${Platform.environment['USERPROFILE']}\\Downloads\\TwitchVODs';
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
            final localProgressJson = decoded['local_vods_progress'];
            if (localProgressJson is Map) {
              _localVodsProgress = localProgressJson.map((k, v) => MapEntry(k.toString(), v as int));
            }
          }
        }
      }

      _channels.clear();
      if (usernames.isNotEmpty) {
        for (var str in usernames) {
          final channel = TwitchChannel(username: str.toLowerCase().trim());
          _channels.add(channel);
        }
      } else {
        // Seed default channels if empty
        final defaults = ['limmy'];
        for (var name in defaults) {
          _channels.add(TwitchChannel(username: name));
        }
        await _saveChannels();
      }

      // Fetch stats for all loaded channels
      await _refreshAllChannels(isInitialLoad: true);
      if (_settings.twitchOauthToken.trim().isNotEmpty) {
        _loadFollowedChannels();
      }
    } catch (e) {
      _showSnackBar('Error loading saved channels: $e', isError: true);
    } finally {
      setState(() => _isGlobalLoading = false);
    }
  }

  // Save channel usernames to local configuration file
  Future<void> _saveChannels() async {
    try {
      final file = _getStorageFile();
      final usernames = _channels.map((c) => c.username).toList();
      final config = {
        'channels': usernames,
        'settings': _settings.toJson(),
        'local_vods_progress': _localVodsProgress,
      };
      final content = json.encode(config);
      await file.writeAsString(content);
    } catch (e) {
      _showSnackBar('Error saving channels: $e', isError: true);
    }
  }

  String _getRawOauthToken() {
    String token = _settings.twitchOauthToken.trim();
    if (token.startsWith('oauth:')) {
      token = token.substring(6);
    }
    return token;
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
    final token = _getRawOauthToken();
    if (token.isEmpty) return;

    setState(() {
      _isLoadingFollowed = true;
    });

    try {
      final clientId = _settings.twitchClientId.trim().isNotEmpty
          ? _settings.twitchClientId.trim()
          : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

      final headers = {
        'Client-Id': clientId,
        'Authorization': 'Bearer $token',
      };

      final userRes = await http.get(
        Uri.parse('https://api.twitch.tv/helix/users'),
        headers: headers,
      );

      if (userRes.statusCode != 200) {
        throw Exception('Failed to get user profile: ${userRes.body}');
      }

      final userData = json.decode(userRes.body);
      if (userData['data'] == null || userData['data'].isEmpty) {
        throw Exception('User data empty');
      }

      final userId = userData['data'][0]['id'] as String;
      final userLogin = userData['data'][0]['login'] as String;
      final userAvatar = userData['data'][0]['profile_image_url'] as String?;

      setState(() {
        _authenticatedUserLogin = userLogin;
        _authenticatedUserAvatar = userAvatar;
      });

      final followsRes = await http.get(
        Uri.parse('https://api.twitch.tv/helix/channels/followed?user_id=$userId&first=100'),
        headers: headers,
      );

      if (followsRes.statusCode != 200) {
        throw Exception('Failed to get followed channels: ${followsRes.body}');
      }

      final followsData = json.decode(followsRes.body);
      final List<dynamic> data = followsData['data'] ?? [];

      final List<TwitchChannel> tempFollowed = [];
      for (var item in data) {
        final name = item['broadcaster_login'] as String;
        final channel = TwitchChannel(username: name.toLowerCase().trim());
        channel.id = item['broadcaster_id'] as String;
        channel.game = item['game_name'] as String?;
        tempFollowed.add(channel);
      }

      setState(() {
        _followedChannels = tempFollowed;
      });

      for (var ch in _followedChannels) {
        _fetchChannelStats(ch);
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
    final token = _getRawOauthToken();
    if (token.isEmpty) return;

    setState(() {
      _isLoadingVods = true;
      _vodsError = null;
      if (!loadMore) {
        _channelVods = [];
        _vodPaginationCursor = null;
      }
    });

    try {
      if (channel.id == null || channel.id!.isEmpty) {
        final idResponse = await http.get(Uri.parse('https://decapi.me/twitch/id/${channel.username}'));
        if (idResponse.statusCode == 200) {
          final resText = idResponse.body.trim();
          if (!resText.toLowerCase().contains('user not found')) {
            channel.id = resText;
          }
        }
      }

      if (channel.id == null || channel.id!.isEmpty) {
        throw Exception('Could not resolve Twitch User ID for ${channel.username}');
      }

      final clientId = _settings.twitchClientId.trim().isNotEmpty
          ? _settings.twitchClientId.trim()
          : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

      final headers = {
        'Client-Id': clientId,
        'Authorization': 'Bearer $token',
      };

      String url = 'https://api.twitch.tv/helix/videos?user_id=${channel.id}&type=archive&first=20';
      if (loadMore && _vodPaginationCursor != null && _vodPaginationCursor!.isNotEmpty) {
        url += '&after=$_vodPaginationCursor';
      }

      final response = await http.get(
        Uri.parse(url),
        headers: headers,
      );

      if (response.statusCode != 200) {
        throw Exception('Twitch API error: ${response.statusCode} - ${response.body}');
      }

      final data = json.decode(response.body);
      final List<dynamic> videosList = data['data'] ?? [];
      final nextCursor = data['pagination']?['cursor'];

      final newVods = videosList.map((item) => TwitchVideo.fromJson(item)).toList();

      // Fetch games and watch progress in parallel for each VOD using GQL queries
      await Future.wait(newVods.map((vod) async {
        // 1. Fetch games via persisted GQL query
        try {
          final body = json.encode({
            'operationName': 'VideoPlayer_ChapterSelectButtonVideo',
            'variables': {
              'videoID': vod.id,
            },
            'extensions': {
              'persistedQuery': {
                'version': 1,
                'sha256Hash': '71835d5ef425e154bf282453a926d99b328cdc5e32f36d3a209d0f4778b41203',
              },
            },
          });

          final gResponse = await http.post(
            Uri.parse('https://gql.twitch.tv/gql'),
            headers: {
              'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
              'Content-Type': 'application/json',
            },
            body: body,
          );

          if (gResponse.statusCode == 200) {
            final decoded = json.decode(gResponse.body);
            final moments = decoded['data']?['video']?['moments']?['edges'] as List<dynamic>?;
            if (moments != null) {
              final List<String> fetchedGames = [];
              for (final edge in moments) {
                final gameName = edge['node']?['details']?['game']?['displayName'] as String?;
                if (gameName != null && gameName.isNotEmpty) {
                  fetchedGames.add(gameName);
                }
              }
              vod.games = fetchedGames.toSet().toList();
            }
          }
        } catch (_) {}

        // 2. Fetch watch progress via GQL viewingHistory query if web token is present
        String webToken = _settings.twitchWebOauthToken.trim();
        if (webToken.startsWith('oauth:')) {
          webToken = webToken.substring(6);
        }
        if (webToken.isNotEmpty) {
          try {
            final progressBody = json.encode({
              'query': '''
                query(\$videoID: ID!) {
                  video(id: \$videoID) {
                    self {
                      viewingHistory {
                        position
                      }
                    }
                  }
                }
              ''',
              'variables': {
                'videoID': vod.id,
              },
            });

            final progressResponse = await http.post(
              Uri.parse('https://gql.twitch.tv/gql'),
              headers: {
                'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
                'Authorization': 'OAuth $webToken',
                'Content-Type': 'application/json',
              },
              body: progressBody,
            );

            if (progressResponse.statusCode == 200) {
              final decoded = json.decode(progressResponse.body);
              final position = decoded['data']?['video']?['self']?['viewingHistory']?['position'] as int?;
              if (position != null) {
                vod.watchPosition = position;
                final totalSeconds = _parseDurationToSeconds(vod.duration);
                if (totalSeconds > 0) {
                  vod.watchProgress = position / totalSeconds;
                }
              }
            } else {
              print('[VOD Progress Fetch] Failed to load progress for video ${vod.id}: status code ${progressResponse.statusCode}');
              if (progressResponse.statusCode == 401) {
                if (mounted && !_isWebTokenExpired) {
                  setState(() {
                    _isWebTokenExpired = true;
                  });
                }
              }
            }
          } catch (e) {
            print('[VOD Progress Fetch Error] Failed to load progress for video ${vod.id}: $e');
          }
        }

        if (_localVodsProgress.containsKey(vod.id)) {
          final localPos = _localVodsProgress[vod.id]!;
          vod.watchPosition = localPos;
          final totalSeconds = _parseDurationToSeconds(vod.duration);
          if (totalSeconds > 0) {
            vod.watchProgress = localPos / totalSeconds;
          } else {
            vod.watchProgress = 0.0;
          }
        }
      }));

      setState(() {
        _vodPaginationCursor = nextCursor;
        if (loadMore) {
          _channelVods.addAll(newVods);
        } else {
          _channelVods = newVods;
        }
      });
      _checkDownloadedVods();
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

  int _parseDurationToSeconds(String duration) {
    try {
      final hourReg = RegExp(r'(\d+)h');
      final minReg = RegExp(r'(\d+)m');
      final secReg = RegExp(r'(\d+)s');

      int hours = 0;
      int minutes = 0;
      int seconds = 0;

      final hMatch = hourReg.firstMatch(duration);
      if (hMatch != null) {
        hours = int.parse(hMatch.group(1)!);
      }

      final mMatch = minReg.firstMatch(duration);
      if (mMatch != null) {
        minutes = int.parse(mMatch.group(1)!);
      }

      final sMatch = secReg.firstMatch(duration);
      if (sMatch != null) {
        seconds = int.parse(sMatch.group(1)!);
      }

      return (hours * 3600) + (minutes * 60) + seconds;
    } catch (_) {
      return 0;
    }
  }

  void _startVODProgressTracker(TwitchVideo vod, int port) {
    int lastSynced = -1;
    String webToken = _settings.twitchWebOauthToken.trim();
    if (webToken.startsWith('oauth:')) {
      webToken = webToken.substring(6);
    }
    if (webToken.isEmpty) {
      print('[VOD Progress Sync] No Browser OAuth Token configured. Skipping sync.');
      return;
    }

    final timer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      final isVlc = _settings.playerType == 'vlc' || 
          (_settings.playerType == 'custom' && _settings.customPlayerPath.toLowerCase().contains('vlc'));
      final isMpv = _settings.playerType == 'mpv' || 
          (_settings.playerType == 'custom' && _settings.customPlayerPath.toLowerCase().contains('mpv'));

      if (isVlc) {
        try {
          final auth = 'Basic ' + base64Encode(utf8.encode(':streamlink'));
          final response = await http.get(
            Uri.parse('http://localhost:$port/requests/status.json'),
            headers: {
              'Authorization': auth,
            },
          ).timeout(const Duration(seconds: 2));

          if (response.statusCode == 200) {
            final data = json.decode(response.body);
            final state = data['state'] as String?;
            final time = data['time'] as int?;
            if (state == 'playing' && time != null && time > 0) {
              if ((time - lastSynced).abs() >= 3) {
                lastSynced = time;
                _syncVODProgressToTwitch(vod.id, time, webToken);
              }
            }
          }
        } catch (_) {}
      } else if (isMpv) {
        try {
          final socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(seconds: 2));
          String responseBuffer = '';
          socket.listen((data) {
            responseBuffer += utf8.decode(data);
            if (responseBuffer.contains('\n')) {
              socket.destroy();
            }
          });
          socket.write('{"command": ["get_property", "time-pos"]}\n');
          socket.write('{"command": ["get_property", "pause"]}\n');
          await Future.delayed(const Duration(milliseconds: 300));

          final lines = responseBuffer.split('\n').where((l) => l.trim().isNotEmpty).toList();
          if (lines.isNotEmpty) {
            double? timePos;
            bool isPaused = false;
            for (final line in lines) {
              try {
                final parsed = json.decode(line);
                if (parsed['data'] is num) {
                  timePos = (parsed['data'] as num).toDouble();
                } else if (parsed['data'] is bool) {
                  isPaused = parsed['data'] as bool;
                }
              } catch (_) {}
            }
            if (timePos != null && !isPaused) {
              final rounded = timePos.round();
              if ((rounded - lastSynced).abs() >= 3) {
                lastSynced = rounded;
                _syncVODProgressToTwitch(vod.id, rounded, webToken);
              }
            }
          }
        } catch (_) {}
      }
    });

    _activePlayerTimers[vod.id] = timer;
  }

  void _stopVODProgressTracker(String videoID) {
    final t = _activePlayerTimers.remove(videoID);
    t?.cancel();
  }

  Future<void> _syncVODProgressToTwitch(String videoID, int position, String webToken) async {
    try {
      print('[VOD Progress Sync] Sending position update for VOD $videoID: ${position}s');
      final body = json.encode({
        'query': '''
          mutation(\$videoID: ID!, \$position: Int!) {
            updateVideoPlaybackPosition(input: {videoID: \$videoID, position: \$position}) {
              error {
                code
              }
            }
          }
        ''',
        'variables': {
          'videoID': videoID,
          'position': position,
        },
      });

      final response = await http.post(
        Uri.parse('https://gql.twitch.tv/gql'),
        headers: {
          'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
          'Authorization': 'OAuth $webToken',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      print('[VOD Progress Sync] Twitch tracking status: ${response.statusCode}');

      if (response.statusCode == 401) {
        print('[VOD Progress Sync] Browser OAuth Token has expired (401). Stopping tracking.');
        final t = _activePlayerTimers.remove(videoID);
        t?.cancel();
        if (mounted && !_isWebTokenExpired) {
          setState(() {
            _isWebTokenExpired = true;
          });
        }
        return;
      }

      final vodIndex = _channelVods.indexWhere((v) => v.id == videoID);
      setState(() {
        _localVodsProgress[videoID] = position;
        if (vodIndex != -1) {
          final currentVod = _channelVods[vodIndex];
          currentVod.watchPosition = position;
          final totalSeconds = _parseDurationToSeconds(currentVod.duration);
          if (totalSeconds > 0) {
            currentVod.watchProgress = position / totalSeconds;
          }
        }
      });
      _saveChannels();
    } catch (e) {
      print('[VOD Progress Sync Error] Failed to sync progress: $e');
    }
  }

  Future<void> _syncSingleVODProgressDirect(String videoID, int position, String webToken) async {
    try {
      final body = json.encode({
        'query': '''
          mutation(\$videoID: ID!, \$position: Int!) {
            updateVideoPlaybackPosition(input: {videoID: \$videoID, position: \$position}) {
              error {
                code
              }
            }
          }
        ''',
        'variables': {
          'videoID': videoID,
          'position': position,
        },
      });

      final response = await http.post(
        Uri.parse('https://gql.twitch.tv/gql'),
        headers: {
          'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
          'Authorization': 'OAuth $webToken',
          'Content-Type': 'application/json',
        },
        body: body,
      );

      if (response.statusCode == 401) {
        if (mounted && !_isWebTokenExpired) {
          setState(() {
            _isWebTokenExpired = true;
          });
        }
        throw Exception('Unauthorized');
      }
    } catch (e) {
      print('[VOD Bulk Sync Error] Failed to sync progress for $videoID: $e');
      rethrow;
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
        targetPosition = _parseDurationToSeconds(vod.duration);
      }

      // Update local state and cache immediately
      setState(() {
        _localVodsProgress[videoId] = targetPosition;
        vod.watchPosition = targetPosition;
        vod.watchProgress = markAsWatched ? 1.0 : 0.0;
      });
      successCount++;

      // Attempt background GQL sync (fails silently as Twitch private API blocks ad-hoc mutations)
      try {
        _syncSingleVODProgressDirect(videoId, targetPosition, webToken).catchError((_) {});
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

  Future<void> _launchStreamlinkForVod(TwitchVideo vod) async {
    String titleString = '${_selectedChannel?.username ?? "VOD"} - ${vod.title}';
    final args = <String>[];
    args.addAll(['--title', titleString]);

    final token = _getRawOauthToken();
    final clientId = _settings.twitchClientId.trim().isNotEmpty
        ? _settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    if (token.isNotEmpty && clientId == 'kimne78kx3ncx6brgo4mv6wki5h1ko') {
      args.addAll(['--twitch-api-header', 'Authorization=OAuth $token']);
    }

    final port = _getNextAvailablePlayerPort();

    final extraArgsList = <String>[];
    if (_settings.playerType == 'vlc') {
      args.addAll(['--player', 'vlc']);
      extraArgsList.addAll(['--extraintf=http', '--http-port=$port', '--http-password=streamlink']);
    } else if (_settings.playerType == 'mpv') {
      args.addAll(['--player', 'mpv']);
      extraArgsList.add('--input-ipc-server=127.0.0.1:$port');
    } else if (_settings.playerType == 'custom' && _settings.customPlayerPath.trim().isNotEmpty) {
      args.addAll(['--player', _settings.customPlayerPath.trim()]);
      final lowerPath = _settings.customPlayerPath.toLowerCase();
      if (lowerPath.contains('vlc')) {
        extraArgsList.addAll(['--extraintf=http', '--http-port=$port', '--http-password=streamlink']);
      } else if (lowerPath.contains('mpv')) {
        extraArgsList.add('--input-ipc-server=127.0.0.1:$port');
      }
    }

    String combinedPlayerArgs = '';
    if (_settings.customPlayerArgs.trim().isNotEmpty) {
      combinedPlayerArgs = _settings.customPlayerArgs.trim();
    }
    if (extraArgsList.isNotEmpty) {
      if (combinedPlayerArgs.isNotEmpty) {
        combinedPlayerArgs += ' ' + extraArgsList.join(' ');
      } else {
        combinedPlayerArgs = extraArgsList.join(' ');
      }
    }

    if (combinedPlayerArgs.isNotEmpty) {
      args.addAll(['--player-args', combinedPlayerArgs]);
    }

    final watchedThresholdPct = _settings.watchedThreshold / 100.0;
    final isFullyWatched = vod.watchProgress != null && vod.watchProgress! >= watchedThresholdPct;
    if (vod.watchPosition != null && vod.watchPosition! > 10 && !isFullyWatched) {
      args.addAll(['--hls-start-offset', '${vod.watchPosition}s']);
    }

    args.add('twitch.tv/videos/${vod.id}');
    args.add(_settings.defaultQuality);

    final key = vod.id;
    final title = 'VOD: ${vod.title}';
    setState(() {
      _playingVodIds.add(vod.id);
      _activePlayerPorts[vod.id] = port;
      _playerTabTitles[key] = title;
      _playerLogs[key] = [];
      _playerScrollControllers.putIfAbsent(key, () => ScrollController());
      _selectedConsoleTabKey = key;
      _consoleCollapsed = false;
    });

    _addPlayerLogLine(key, '[System] Initializing Streamlink for twitch.tv/videos/${vod.id} ${_settings.defaultQuality}...');
    _addPlayerLogLine(key, '[System] Arguments: ${args.join(" ")}');

    try {
      final proc = await Process.start(
        'streamlink',
        args,
        runInShell: true,
      );

      _activePlayerProcesses[vod.id] = proc;
      _startVODProgressTracker(vod, port);

      proc.stdout.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            _addPlayerLogLine(key, '[Streamlink] ${line.trim()}');
          }
        }
      });

      proc.stderr.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            _addPlayerLogLine(key, '[Streamlink ERR] ${line.trim()}');
          }
        }
      });

      proc.exitCode.then((exitCode) {
        _addPlayerLogLine(key, '[System] Streamlink process for VOD ${vod.id} exited with code $exitCode');
        if (!mounted) return;
        setState(() {
          _playingVodIds.remove(vod.id);
          _activePlayerProcesses.remove(vod.id);
          _activePlayerPorts.remove(vod.id);
        });
        _stopVODProgressTracker(vod.id);
      });
    } catch (e) {
      _addPlayerLogLine(key, '[System Error] Failed to start Streamlink: $e');
      setState(() {
        _playingVodIds.remove(vod.id);
        _activePlayerPorts.remove(vod.id);
      });
      _showSnackBar('Failed to start Streamlink: $e', isError: true);
    }
  }

  // Fetch DecAPI statistics for a single channel
  String _calculateUptime(String startedAtStr) {
    try {
      final startedAt = DateTime.parse(startedAtStr);
      final diff = DateTime.now().toUtc().difference(startedAt);
      final hours = diff.inHours;
      final minutes = diff.inMinutes.remainder(60);
      final seconds = diff.inSeconds.remainder(60);
      
      if (hours > 0) {
        return '${hours}h ${minutes}m ${seconds}s';
      } else if (minutes > 0) {
        return '${minutes}m ${seconds}s';
      } else {
        return '${seconds}s';
      }
    } catch (_) {
      return 'Live';
    }
  }

  // Fetch DecAPI or official Twitch Helix statistics for a single channel
  Future<void> _fetchChannelStats(TwitchChannel channel) async {
    setState(() {
      channel.isLoading = true;
      channel.errorMessage = null;
    });

    final username = channel.username;
    final token = _getRawOauthToken();
    final clientId = _settings.twitchClientId.trim().isNotEmpty
        ? _settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    try {
      if (token.isNotEmpty) {
        // Authenticated: Use Helix API
        final headers = {
          'Client-Id': clientId,
          'Authorization': 'Bearer $token',
        };

        // 1. Resolve ID & Profile Avatar if not cached
        if (channel.id == null || channel.id!.isEmpty || channel.avatarUrl == null || channel.avatarUrl!.isEmpty) {
          final userRes = await http.get(
            Uri.parse('https://api.twitch.tv/helix/users?login=$username'),
            headers: headers,
          );
          if (userRes.statusCode == 200) {
            final userData = json.decode(userRes.body);
            if (userData['data'] != null && userData['data'].isNotEmpty) {
              channel.id = userData['data'][0]['id'] as String;
              channel.avatarUrl = userData['data'][0]['profile_image_url'] as String?;
            } else {
              throw Exception('Twitch user "$username" not found.');
            }
          } else {
            throw Exception('Helix User API error: status ${userRes.statusCode}');
          }
        }

        // 2. Fetch Stream status
        final streamRes = await http.get(
          Uri.parse('https://api.twitch.tv/helix/streams?user_id=${channel.id}'),
          headers: headers,
        );
        if (streamRes.statusCode == 200) {
          final streamData = json.decode(streamRes.body);
          if (streamData['data'] != null && streamData['data'].isNotEmpty) {
            final stream = streamData['data'][0];
            channel.isLive = true;
            channel.streamTitle = stream['title'] as String?;
            channel.game = stream['game_name'] as String?;
            channel.viewerCount = stream['viewer_count']?.toString() ?? '0';
            
            final startedAt = stream['started_at'] as String?;
            if (startedAt != null) {
              channel.uptime = _calculateUptime(startedAt);
            } else {
              channel.uptime = 'Live';
            }
          } else {
            channel.isLive = false;
            channel.uptime = 'Offline';
            channel.viewerCount = '0';
            channel.game = 'Offline';
            channel.streamTitle = 'No active broadcast';
          }
        } else {
          throw Exception('Helix Stream API error: status ${streamRes.statusCode}');
        }

        // 3. Fetch Follower count
        final followsRes = await http.get(
          Uri.parse('https://api.twitch.tv/helix/channels/followers?broadcaster_id=${channel.id}'),
          headers: headers,
        );
        if (followsRes.statusCode == 200) {
          final followsData = json.decode(followsRes.body);
          final totalFollowers = followsData['total'] as int?;
          if (totalFollowers != null) {
            channel.followerCount = _formatNumberString(totalFollowers.toString());
          }
        }
      } else {
        // Unauthenticated: Fallback to DecAPI
        // 1. Verify/Fetch User ID
        final idResponse = await http.get(Uri.parse('https://decapi.me/twitch/id/$username'));
        if (idResponse.statusCode == 200) {
          final resText = idResponse.body.trim();
          if (resText.toLowerCase().contains('user not found')) {
            throw Exception('Twitch user "$username" not found on Twitch.');
          }
          channel.id = resText;
        } else {
          throw Exception('API returned status code ${idResponse.statusCode}');
        }

        // 2. Fetch Uptime, Avatar, Followers, Viewers, Game, and Title in parallel
        final futures = await Future.wait([
          http.get(Uri.parse('https://decapi.me/twitch/avatar/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/uptime/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/followcount/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/viewercount/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/game/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/title/$username')),
        ]);

        if (futures[0].statusCode == 200) {
          channel.avatarUrl = futures[0].body.trim();
        }
        
        if (futures[1].statusCode == 200) {
          final uptimeStr = futures[1].body.trim();
          if (uptimeStr.toLowerCase().contains('offline')) {
            channel.isLive = false;
            channel.uptime = 'Offline';
          } else {
            channel.isLive = true;
            channel.uptime = uptimeStr;
          }
        }

        if (futures[2].statusCode == 200) {
          channel.followerCount = _formatNumberString(futures[2].body.trim());
        }

        if (channel.isLive) {
          if (futures[3].statusCode == 200) {
            channel.viewerCount = _formatNumberString(futures[3].body.trim());
          }
          if (futures[4].statusCode == 200) {
            channel.game = futures[4].body.trim();
          }
          if (futures[5].statusCode == 200) {
            channel.streamTitle = futures[5].body.trim();
          }
        } else {
          channel.viewerCount = '0';
          channel.game = 'Offline';
          channel.streamTitle = 'No active broadcast';
        }
      }

      channel.lastUpdated = DateTime.now();
    } catch (e) {
      channel.errorMessage = e.toString().replaceFirst('Exception: ', '');
      channel.isLive = false;
      channel.uptime = 'Offline';
    } finally {
      setState(() {
        channel.isLoading = false;
      });
    }
  }

  // Refresh all channels (Favorites and Followed Live Status)
  Future<void> _refreshAllChannels({bool isInitialLoad = false}) async {
    // 1. Refresh favorites list
    final futures = _channels.map((c) => _fetchChannelStats(c));
    await Future.wait(futures);

    // Check favorites transitions and trigger notifications for favorites ONLY
    for (final channel in _channels) {
      final cleanName = channel.username.toLowerCase().trim();
      if (channel.isLive) {
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

    // If a channel is selected, update it in state
    if (_selectedChannel != null) {
      final index = _channels.indexWhere((c) => c.username == _selectedChannel!.username);
      if (index != -1) {
        setState(() {
          _selectedChannel = _channels[index];
        });
      }
    }

    // 2. Refresh followed channels stats in background (if authenticated)
    if (_settings.twitchOauthToken.trim().isNotEmpty && _followedChannels.isNotEmpty) {
      final followedFutures = _followedChannels.map((c) => _fetchChannelStats(c));
      await Future.wait(followedFutures);

      // If a channel is selected, update it in state
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

  // Add a new Twitch channel to the list
  Future<void> _addChannel(String name) async {
    final cleanName = name.toLowerCase().trim();
    if (cleanName.isEmpty) return;

    if (_channels.any((c) => c.username == cleanName)) {
      _showSnackBar('Channel "$cleanName" is already in your list.', isError: true);
      return;
    }

    setState(() => _isAdding = true);

    final newChannel = TwitchChannel(username: cleanName);
    await _fetchChannelStats(newChannel);

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
      
      _fetchChannelStats(newFav).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  // Streamlink Launching Logic
  Future<void> _launchStreamlink(String channelName) async {
    final channel = _channels.firstWhere(
      (c) => c.username == channelName.toLowerCase().trim(),
      orElse: () => TwitchChannel(username: channelName),
    );

    String titleString = channelName;
    if (channel.isLive) {
      final titleText = channel.streamTitle ?? 'Live Stream';
      final gameText = channel.game ?? 'Twitch';
      titleString = '${channel.username} - $titleText ($gameText)';
    } else {
      titleString = '${channel.username} - Offline Stream';
    }

    final args = <String>[];
    args.addAll(['--title', titleString]);

    final token = _getRawOauthToken();
    final clientId = _settings.twitchClientId.trim().isNotEmpty
        ? _settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    if (token.isNotEmpty && clientId == 'kimne78kx3ncx6brgo4mv6wki5h1ko') {
      args.addAll(['--twitch-api-header', 'Authorization=OAuth $token']);
    }

    if (_settings.twitchLowLatency) {
      args.add('--twitch-low-latency');
    }

    if (_settings.playerType == 'vlc') {
      args.addAll(['--player', 'vlc']);
    } else if (_settings.playerType == 'mpv') {
      args.addAll(['--player', 'mpv']);
    } else if (_settings.playerType == 'custom' && _settings.customPlayerPath.trim().isNotEmpty) {
      args.addAll(['--player', _settings.customPlayerPath.trim()]);
    }

    if (_settings.customPlayerArgs.trim().isNotEmpty) {
      args.addAll(['--player-args', _settings.customPlayerArgs.trim()]);
    }

    args.add('twitch.tv/$channelName');
    args.add(_settings.defaultQuality);

    final key = 'stream_$channelName';
    final title = '${channel.username} (Live)';
    setState(() {
      _runningChannels.add(channelName);
      _playerTabTitles[key] = title;
      _playerLogs[key] = [];
      _playerScrollControllers.putIfAbsent(key, () => ScrollController());
      _selectedConsoleTabKey = key;
      _consoleCollapsed = false;
    });

    _addPlayerLogLine(key, '[System] Initializing Streamlink for twitch.tv/$channelName ${_settings.defaultQuality}...');
    _addPlayerLogLine(key, '[System] Arguments: ${args.join(" ")}');

    try {
      final proc = await Process.start(
        'streamlink',
        args,
        runInShell: true,
      );

      _activePlayerProcesses[key] = proc;

      proc.stdout.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            _addPlayerLogLine(key, '[Streamlink] ${line.trim()}');
          }
        }
      });

      proc.stderr.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            _addPlayerLogLine(key, '[Streamlink Err] ${line.trim()}');
          }
        }
      });

      proc.exitCode.then((exitCode) {
        _addPlayerLogLine(key, '[System] Streamlink process for channel $channelName terminated with exit code $exitCode');
        if (!mounted) return;
        setState(() {
          _runningChannels.remove(channelName);
          _activePlayerProcesses.remove(key);
        });
      });
    } catch (e) {
      _addPlayerLogLine(key, '[System Error] Failed to run streamlink: $e');
      _addPlayerLogLine(key, '[System Error] Ensure Streamlink is installed and available in your environment.');
      setState(() {
        _runningChannels.remove(channelName);
        _activePlayerProcesses.remove(key);
      });
    }
  }



  // Open link in default web browser using OS cmd start
  Future<void> _openExternalLink(String url) async {
    try {
      if (Platform.isWindows) {
        // cmd.exe parses ampersands (&) as command separators, so we must escape them with carets (^)
        final escapedUrl = url.replaceAll('&', '^&');
        await Process.run('cmd', ['/c', 'start', '""', escapedUrl], runInShell: false);
      } else {
        _showSnackBar('Unsupported platform for launching external link', isError: true);
      }
    } catch (e) {
      _showSnackBar('Failed to open link: $e', isError: true);
    }
  }

  // UI Utilities
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

  String _formatNumberString(String value) {
    try {
      final numValue = int.tryParse(value);
      if (numValue == null) return value;
      if (numValue >= 1000000) {
        return '${(numValue / 1000000).toStringAsFixed(1)}M';
      } else if (numValue >= 1000) {
        return '${(numValue / 1000).toStringAsFixed(1)}K';
      }
      return numValue.toString();
    } catch (_) {
      return value;
    }
  }

  String _timeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inDays >= 365) {
      final years = (difference.inDays / 365).floor();
      return '$years year${years > 1 ? "s" : ""} ago';
    } else if (difference.inDays >= 30) {
      final months = (difference.inDays / 30).floor();
      return '$months month${months > 1 ? "s" : ""} ago';
    } else if (difference.inDays >= 7) {
      final weeks = (difference.inDays / 7).floor();
      return '$weeks week${weeks > 1 ? "s" : ""} ago';
    } else if (difference.inDays >= 1) {
      return '${difference.inDays} day${difference.inDays > 1 ? "s" : ""} ago';
    } else if (difference.inHours >= 1) {
      return '${difference.inHours} hour${difference.inHours > 1 ? "s" : ""} ago';
    } else if (difference.inMinutes >= 1) {
      return '${difference.inMinutes} minute${difference.inMinutes > 1 ? "s" : ""} ago';
    } else {
      return 'just now';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      body: Row(
        children: [
          // Sidebar Panel
          Container(
            width: _sidebarCollapsed ? 72.0 : 320.0,
            color: const Color(0xFF111420),
            child: _sidebarCollapsed
                ? _buildCollapsedSidebar(theme)
                : Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                        decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: Color(0xFF1E2433), width: 1.5)),
                        ),
                        child: Row(
                          children: [
                            _authenticatedUserAvatar != null
                                ? CircleAvatar(
                                    radius: 20,
                                    backgroundColor: const Color(0xFF1F2937),
                                    backgroundImage: NetworkImage(_authenticatedUserAvatar!),
                                  )
                                : Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: theme.primaryColor.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: theme.primaryColor, width: 1.5),
                                    ),
                                    child: Icon(Icons.live_tv, color: theme.colorScheme.secondary, size: 24),
                                  ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Streamlink Twitch',
                                    style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    _authenticatedUserLogin != null
                                        ? 'User: $_authenticatedUserLogin'
                                        : 'DecAPI Live stats manager',
                                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.keyboard_double_arrow_left, color: Colors.white70, size: 20),
                              tooltip: 'Collapse Sidebar',
                              onPressed: () {
                                setState(() {
                                  _sidebarCollapsed = true;
                                  _settings.sidebarCollapsed = true;
                                });
                                _saveChannels();
                              },
                              hoverColor: theme.primaryColor.withOpacity(0.2),
                              splashRadius: 20,
                            ),
                          ],
                        ),
                      ),
                
                // Add channel section
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: TextField(
                            controller: _searchController,
                            style: const TextStyle(fontSize: 13, color: Colors.white),
                            decoration: const InputDecoration(
                              hintText: 'Add favorite username...',
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                            ),
                            onSubmitted: (val) => _addChannel(val),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 42,
                        width: 42,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.primaryColor,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: _isAdding ? null : () => _addChannel(_searchController.text),
                          child: _isAdding
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.add, color: Colors.white, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),

                // Sidebar Tabs (Only if authenticated)
                if (_settings.twitchOauthToken.trim().isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B26),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF1E2433)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() => _sidebarTab = 0),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: _sidebarTab == 0 ? theme.primaryColor : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Center(
                                  child: Text(
                                    'Favorites',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                setState(() => _sidebarTab = 1);
                                if (_followedChannels.isEmpty && !_isLoadingFollowed) {
                                  _loadFollowedChannels();
                                }
                              },
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: _sidebarTab == 1 ? theme.primaryColor : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Center(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Text(
                                        'Followed',
                                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                                      ),
                                      if (_isLoadingFollowed) ...[
                                        const SizedBox(width: 6),
                                        const SizedBox(
                                          width: 10,
                                          height: 10,
                                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() => _sidebarTab = 2),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                decoration: BoxDecoration(
                                  color: _sidebarTab == 2 ? theme.primaryColor : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Center(
                                  child: Text(
                                    'Live',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],

                // Global Actions
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF1E2433)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            foregroundColor: Colors.white70,
                          ),
                          onPressed: _isGlobalLoading || _isLoadingFollowed
                              ? null
                              : () async {
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
                          icon: _isGlobalLoading || _isLoadingFollowed
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                                )
                              : const Icon(Icons.refresh, size: 14),
                          label: Text(
                            _sidebarTab == 0
                                ? 'Refresh Favorites'
                                : (_sidebarTab == 1 ? 'Refresh Follows' : 'Refresh Live'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                
                // Channel list
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final listToDisplay = (() {
                        if (_sidebarTab == 0) return _channels;
                        if (_sidebarTab == 1) return _followedChannels;
                        
                        final liveList = <TwitchChannel>[];
                        final seenUsernames = <String>{};
                        for (final c in _channels) {
                          if (c.isLive) {
                            final clean = c.username.toLowerCase().trim();
                            if (!seenUsernames.contains(clean)) {
                              seenUsernames.add(clean);
                              liveList.add(c);
                            }
                          }
                        }
                        for (final c in _followedChannels) {
                          if (c.isLive) {
                            final clean = c.username.toLowerCase().trim();
                            if (!seenUsernames.contains(clean)) {
                              seenUsernames.add(clean);
                              liveList.add(c);
                            }
                          }
                        }
                        liveList.sort((a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));
                        return liveList;
                      })();
                      final isLoading = _sidebarTab == 0
                          ? _isGlobalLoading
                          : (_sidebarTab == 1 ? _isLoadingFollowed : (_isGlobalLoading || _isLoadingFollowed));

                      if (isLoading && listToDisplay.isEmpty) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (listToDisplay.isEmpty) {
                        return Center(
                          child: Text(
                            _sidebarTab == 0
                                ? 'No favorites saved.\nAdd one above.'
                                : (_sidebarTab == 1
                                    ? 'No followed channels found.\nMake sure your account is connected.'
                                    : 'No live channels found.'),
                            textAlign: TextAlign.center,
                          ),
                        );
                      }

                      return ListView.builder(
                        itemCount: listToDisplay.length,
                        itemBuilder: (context, index) {
                          final channel = listToDisplay[index];
                          final isSelected = _selectedChannel?.username == channel.username;
                          final cleanUsername = channel.username.toLowerCase().trim();
                          final isFavorite = _channels.any((c) => c.username == cleanUsername);
                          bool isRowHovered = false;

                          return StatefulBuilder(
                            builder: (context, setRowState) {
                              return MouseRegion(
                                onEnter: (_) => setRowState(() => isRowHovered = true),
                                onExit: (_) => setRowState(() => isRowHovered = false),
                                child: Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    color: isSelected
                                        ? theme.primaryColor.withOpacity(0.15)
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: isSelected
                                          ? theme.primaryColor.withOpacity(0.4)
                                          : Colors.transparent,
                                      width: 1,
                                    ),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.only(left: 12, right: 4),
                                    leading: Stack(
                                      children: [
                                        CircleAvatar(
                                          radius: 18,
                                          backgroundColor: const Color(0xFF1F2937),
                                          backgroundImage: channel.avatarUrl != null
                                              ? NetworkImage(channel.avatarUrl!)
                                              : null,
                                          child: channel.avatarUrl == null
                                              ? const Icon(Icons.person, size: 18, color: Colors.white70)
                                              : null,
                                        ),
                                        Positioned(
                                          bottom: 0,
                                          right: 0,
                                          child: Container(
                                            width: 10,
                                            height: 10,
                                            decoration: BoxDecoration(
                                              color: channel.isLive ? Colors.green : Colors.grey,
                                              shape: BoxShape.circle,
                                              border: Border.all(color: const Color(0xFF111420), width: 1.5),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            channel.username,
                                            style: theme.textTheme.bodyLarge?.copyWith(
                                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                              fontSize: 14,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (channel.isLive)
                                          AnimatedBuilder(
                                            animation: _pulseController!,
                                            builder: (context, child) {
                                              return Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: Colors.red.withOpacity(0.7 + 0.3 * _pulseController!.value),
                                                  borderRadius: BorderRadius.circular(4),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.red.withOpacity(0.4 * _pulseController!.value),
                                                      blurRadius: 4,
                                                    )
                                                  ],
                                                ),
                                                child: const Text(
                                                  'LIVE',
                                                  style: TextStyle(
                                                    fontSize: 8,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                      ],
                                    ),
                                    subtitle: channel.isLoading
                                        ? const Padding(
                                            padding: EdgeInsets.only(top: 4),
                                            child: LinearProgressIndicator(minHeight: 1.5),
                                          )
                                        : Text(
                                            channel.isLive
                                                ? (channel.game ?? 'Playing...')
                                                : 'Offline',
                                            style: const TextStyle(fontSize: 11),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                    trailing: _sidebarTab == 0
                                        ? IconButton(
                                            icon: const Icon(Icons.star, color: Colors.amber, size: 18),
                                            onPressed: () => _toggleFavorite(channel),
                                            tooltip: 'Remove from Favorites',
                                            splashRadius: 18,
                                          )
                                        : (isFavorite
                                            ? IconButton(
                                                icon: const Icon(Icons.star, color: Colors.amber, size: 18),
                                                onPressed: () => _toggleFavorite(channel),
                                                tooltip: 'Remove from Favorites',
                                                splashRadius: 18,
                                              )
                                            : (isRowHovered
                                                ? HoverStarIcon(
                                                    isFavorite: false,
                                                    onTap: () => _toggleFavorite(channel),
                                                  )
                                                : null)),
                                    onTap: () {
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
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
                // Settings bottom bar (Bottom Left)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFF1E2433), width: 1)),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.settings, color: Colors.white60, size: 20),
                        tooltip: 'Settings',
                        onPressed: _showSettingsDialog,
                        hoverColor: theme.primaryColor.withOpacity(0.2),
                        splashRadius: 20,
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // Main Content Area
          Expanded(
            child: Container(
              color: const Color(0xFF0C0F17),
              child: _selectedChannel == null
                  ? _buildWelcomeScreen(theme)
                  : _buildDashboard(theme, _selectedChannel!),
            ),
          ),
        ],
      ),
    );
  }

  // Welcome Screen when no channel is selected
  Widget _buildWelcomeScreen(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF161B26),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF1E2433), width: 2),
              boxShadow: [
                BoxShadow(
                  color: theme.primaryColor.withOpacity(0.1),
                  blurRadius: 40,
                  spreadRadius: 10,
                )
              ],
            ),
            child: Icon(Icons.live_tv, size: 72, color: theme.primaryColor),
          ),
          const SizedBox(height: 24),
          Text(
            'Twitch Channel Dashboard',
            style: theme.textTheme.titleLarge?.copyWith(fontSize: 24, letterSpacing: 0.5),
          ),
          const SizedBox(height: 10),
          const SizedBox(
            width: 320,
            child: Text(
              'Select a Twitch channel from the sidebar or search/add a new one to view real-time stats and launch streams.',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.5, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // Active Dashboard
  Widget _buildDashboard(ThemeData theme, TwitchChannel channel) {
    final isSmall = MediaQuery.of(context).size.width < 1180;
    return Column(
      children: [
        // Main Dashboard Body (Scrollable)
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Live/Profile Header Card
                _buildHeaderCard(theme, channel),
                
                // VOD section (Only shown if token is configured)
                if (_settings.twitchOauthToken.trim().isNotEmpty) ...[
                  const SizedBox(height: 32),
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
                      isSmall
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                HoverOverlayMenu(
                                  trigger: MouseRegion(
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
                                  menu: Container(
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
                                                      });
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
                                        
                                        // Card Size Slider
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
                                        
                                        // Font Size Slider
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
                                ),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Show All Games on Thumbnails switch
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
                                            });
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // VOD game filter multi-select
                                PopupMenuButton<String>(
                                  icon: Icon(
                                    _selectedGamesFilter.isEmpty ? Icons.filter_alt_outlined : Icons.filter_alt,
                                    color: _selectedGamesFilter.isEmpty ? Colors.white70 : theme.primaryColor,
                                    size: 16,
                                  ),
                                  tooltip: 'Filter VODs by Games',
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: const BorderSide(color: Color(0xFF1E2433)),
                                  ),
                                  color: const Color(0xFF161B26),
                                  onSelected: (game) {
                                    setState(() {
                                      if (game == '__all__') {
                                        _selectedGamesFilter.clear();
                                      } else {
                                        if (_selectedGamesFilter.contains(game)) {
                                          _selectedGamesFilter.remove(game);
                                        } else {
                                          _selectedGamesFilter.add(game);
                                        }
                                      }
                                    });
                                  },
                                  itemBuilder: (context) {
                                    final uniqueGames = _channelVods.expand((vod) => vod.games).toSet().toList()..sort();
                                    return [
                                      PopupMenuItem<String>(
                                        value: '__all__',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.all_inclusive,
                                              size: 14,
                                              color: _selectedGamesFilter.isEmpty ? theme.primaryColor : Colors.white70,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'All Games',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: _selectedGamesFilter.isEmpty ? FontWeight.bold : FontWeight.normal,
                                                color: _selectedGamesFilter.isEmpty ? theme.primaryColor : Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      ...uniqueGames.map((game) {
                                        final isSelected = _selectedGamesFilter.contains(game);
                                        return CheckedPopupMenuItem<String>(
                                          value: game,
                                          checked: isSelected,
                                          child: Text(
                                            game,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                              color: isSelected ? theme.primaryColor : Colors.white,
                                            ),
                                          ),
                                        );
                                      }),
                                    ];
                                  },
                                ),
                                const SizedBox(width: 10),
                                // VOD Filter TextField
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
                                // Card Size Slider
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
                                // Font Size Slider
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
                  _buildVodsList(theme),
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

        // Streamlink logs console drawer (Bottom Panel)
        _buildConsolePanel(theme),
      ],
    );
  }

  Widget _buildVodsList(ThemeData theme) {
    if (_isLoadingVods && _channelVods.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: CircularProgressIndicator(),
        ),
      );
    }
    
    if (_vodsError != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: Text(
          'Error loading VODs: $_vodsError',
          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
        ),
      );
    }
    
    final searchQuery = _vodSearchController.text.trim().toLowerCase();
    final filteredVods = _channelVods.where((vod) {
      final matchesSearch = searchQuery.isEmpty ||
          vod.title.toLowerCase().contains(searchQuery) ||
          vod.games.any((game) => game.toLowerCase().contains(searchQuery));
      final matchesGameFilter = _selectedGamesFilter.isEmpty ||
          vod.games.any((game) => _selectedGamesFilter.contains(game));
      return matchesSearch && matchesGameFilter;
    }).toList();

    if (filteredVods.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            _selectedGamesFilter.isNotEmpty
                ? 'No past broadcasts match game filter "${_selectedGamesFilter.join(', ')}".'
                : (searchQuery.isEmpty ? 'No past broadcasts found.' : 'No VODs match "$searchQuery".'),
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    // Dynamic Aspect Ratio based on VOD Card scale slider to optimize space (more landscape/square layout)
    final childAspectRatio = 1.0 + ((_vodScale - 200) / 400.0) * 0.25;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: filteredVods.length,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _vodScale,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: childAspectRatio,
      ),
      itemBuilder: (context, index) {
        final vod = filteredVods[index];
        return TwitchVideoCard(
          vod: vod,
          scale: _vodScale,
          theme: theme,
          onPlay: () {
            final file = _getDownloadedVodFile(vod.id, _selectedChannel?.username ?? '');
            if (file != null && file.existsSync()) {
              _playDownloadedVod(file, vod);
            } else {
              _launchStreamlinkForVod(vod);
            }
          },
          formatNumber: _formatNumberString,
          fontSize: _vodTitleFontSize,
          isPlaying: _playingVodIds.contains(vod.id),
          pulseController: _pulseController,
          showGamesOnThumbnails: _showGamesOnThumbnails,
          watchedThreshold: _settings.watchedThreshold,
          isMultiSelectMode: _isMultiSelectMode,
          isSelected: _selectedVodIds.contains(vod.id),
          onSelected: (isSelected) {
            setState(() {
              if (isSelected ?? false) {
                _selectedVodIds.add(vod.id);
              } else {
                _selectedVodIds.remove(vod.id);
              }
            });
          },
          downloadStatus: _activeDownloadTasks[vod.id],
          downloadProgress: _activeDownloadsProgress[vod.id],
          isDownloaded: _downloadedVodIds.contains(vod.id),
          onDownload: () => _queueVodDownload(vod, _selectedChannel?.username ?? 'VOD'),
          onDeleteDownload: () => _deleteDownloadedVod(vod.id, _selectedChannel?.username ?? 'VOD'),
          onCancel: () => _cancelVodDownload(vod.id, _selectedChannel?.username ?? 'VOD'),
        );
      },
    );
  }

  Widget _buildCollapsedSidebar(ThemeData theme) {
    final activeList = _sidebarTab == 0 ? _channels : _followedChannels;
    
    return Column(
      children: [
        const SizedBox(height: 16),
        // Expand Toggle Button
        IconButton(
          icon: const Icon(Icons.keyboard_double_arrow_right, color: Colors.white70, size: 24),
          tooltip: 'Expand sidebar',
          onPressed: () {
            setState(() {
              _sidebarCollapsed = false;
              _settings.sidebarCollapsed = false;
            });
            _saveChannels();
          },
          hoverColor: theme.primaryColor.withOpacity(0.2),
          splashRadius: 22,
        ),
        const SizedBox(height: 10),
        const Divider(color: Color(0xFF1E2433), height: 1.5, thickness: 1.5),
        const SizedBox(height: 16),
        
        // Tab toggle button (Favorites vs Followed vs Live)
        (() {
          bool isHovered = false;
          return StatefulBuilder(
            builder: (context, setHoverState) {
              return MouseRegion(
                onEnter: (_) => setHoverState(() => isHovered = true),
                onExit: (_) => setHoverState(() => isHovered = false),
                child: Tooltip(
                  message: _sidebarTab == 0
                      ? 'Favorites (Click to switch to Followed)'
                      : (_sidebarTab == 1
                          ? 'Followed List (Click to switch to Live)'
                          : 'Live Channels (Click to switch to Favorites)'),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          _sidebarTab = (_sidebarTab + 1) % 3;
                          if (_sidebarTab == 1 && _followedChannels.isEmpty && !_isLoadingFollowed) {
                            _loadFollowedChannels();
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                           color: theme.primaryColor.withOpacity(0.15),
                           borderRadius: BorderRadius.circular(8),
                           border: Border.all(color: theme.primaryColor, width: 1.5),
                        ),
                        child: Icon(
                          isHovered
                              ? Icons.swap_horiz
                              : (_sidebarTab == 0
                                  ? Icons.star
                                  : (_sidebarTab == 1 ? Icons.people : Icons.live_tv)),
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        })(),
        
        const SizedBox(height: 16),
        
        // Global refresh action (icon button in collapsed mode)
        Tooltip(
          message: _sidebarTab == 0 ? 'Refresh Favorites' : 'Refresh Followed List',
          child: IconButton(
            icon: _isGlobalLoading || _isLoadingFollowed
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.refresh, color: Colors.white70, size: 18),
            onPressed: _isGlobalLoading || _isLoadingFollowed
                ? null
                : (_sidebarTab == 0 ? _refreshAllChannels : _loadFollowedChannels),
            hoverColor: theme.primaryColor.withOpacity(0.2),
            splashRadius: 20,
          ),
        ),
        
        const SizedBox(height: 10),
        const Divider(color: Color(0xFF1E2433), height: 1, thickness: 1),
        const SizedBox(height: 12),
        
        // Collapsed channels list showing round avatar images with status glows & tooltips
        Expanded(
          child: ListView.builder(
            itemCount: activeList.length,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemBuilder: (context, index) {
              final ch = activeList[index];
              final isSelected = _selectedChannel?.username == ch.username;
              
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Tooltip(
                  message: '${ch.username} (${ch.isLive ? "LIVE: " + (ch.game ?? "Streaming") : "Offline"})',
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _selectedChannel = ch;
                        _channelVods.clear();
                        _selectedGamesFilter.clear();
                        _isLoadingVods = true;
                        _vodsError = null;
                      });
                      _fetchChannelStats(ch);
                      if (_settings.twitchOauthToken.trim().isNotEmpty) {
                        _fetchVodsForChannel(ch);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(2.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? theme.primaryColor
                              : (ch.isLive ? Colors.redAccent.withOpacity(0.4) : Colors.transparent),
                          width: 2.0,
                        ),
                      ),
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: const Color(0xFF1F2937),
                            backgroundImage: ch.avatarUrl != null ? NetworkImage(ch.avatarUrl!) : null,
                            child: ch.avatarUrl == null
                                ? const Icon(Icons.person, size: 18, color: Colors.white70)
                                : null,
                          ),
                          if (ch.isLive)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFF111420), width: 1),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        
        // Settings bottom bar (Bottom Center)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          width: double.infinity,
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFF1E2433), width: 1)),
          ),
          child: Center(
            child: IconButton(
              icon: const Icon(Icons.settings, color: Colors.white60, size: 20),
              tooltip: 'Settings',
              onPressed: _showSettingsDialog,
              hoverColor: theme.primaryColor.withOpacity(0.2),
              splashRadius: 20,
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOverlayActionItem({required IconData icon, required String label, VoidCallback? onPressed}) {
    return SizedBox(
      width: double.infinity,
      height: 32,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 14, color: Colors.white70),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  // Dashboard Header widget
  Widget _buildHeaderCard(ThemeData theme, TwitchChannel channel) {
    final isSmall = MediaQuery.of(context).size.width < 1180;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF161B26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E2433)),
        boxShadow: [
          BoxShadow(
            color: (channel.isLive ? Colors.green : Colors.grey).withOpacity(0.03),
            blurRadius: 20,
            spreadRadius: 2,
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Profile Avatar & Info
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar Left Block (width: 90)
              SizedBox(
                width: 90,
                child: Center(
                  child: AnimatedBuilder(
                    animation: _pulseController!,
                    builder: (context, child) {
                      final pulseVal = _pulseController!.value;
                      return Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: channel.isLive
                                ? Colors.redAccent.withOpacity(0.5 + pulseVal * 0.5)
                                : Colors.white24,
                            width: 2.5,
                          ),
                          boxShadow: channel.isLive
                              ? [
                                  BoxShadow(
                                    color: Colors.redAccent.withOpacity(0.2 * pulseVal),
                                    blurRadius: 8 + 8 * pulseVal,
                                    spreadRadius: 1 + 2 * pulseVal,
                                  )
                                ]
                              : null,
                        ),
                        child: CircleAvatar(
                          radius: 36,
                          backgroundColor: const Color(0xFF1F2937),
                          backgroundImage: channel.avatarUrl != null ? NetworkImage(channel.avatarUrl!) : null,
                          child: channel.avatarUrl == null
                              ? const Icon(Icons.person, size: 36, color: Colors.white70)
                              : null,
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 20),
              
              // Info Column & Actions (Blue Area)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Username & Status (left), Action buttons (right - Blue Area)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Text(
                              channel.username,
                              style: theme.textTheme.titleLarge?.copyWith(fontSize: 22),
                            ),
                            const SizedBox(width: 10),
                            if (channel.isLive)
                              AnimatedBuilder(
                                animation: _pulseController!,
                                builder: (context, child) {
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.15 + 0.1 * _pulseController!.value),
                                      border: Border.all(
                                        color: Colors.redAccent.withOpacity(0.4 + 0.6 * _pulseController!.value),
                                        width: 1,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Text(
                                      'LIVE',
                                      style: TextStyle(
                                        color: Colors.redAccent,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  );
                                },
                              )
                            else
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.grey.withOpacity(0.15),
                                  border: Border.all(
                                    color: Colors.grey,
                                    width: 1,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'OFFLINE',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        
                        // Action buttons (Blue Area)
                        isSmall
                            ? HoverOverlayMenu(
                                trigger: MouseRegion(
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
                                        Icon(Icons.more_vert, color: Colors.white70, size: 16),
                                        SizedBox(width: 4),
                                        Text('Actions', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ),
                                menu: Container(
                                  width: 160,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF161B26),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF1E2433)),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.5),
                                        blurRadius: 10,
                                      )
                                    ],
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildOverlayActionItem(
                                        icon: Icons.open_in_new,
                                        label: 'Open Channel',
                                        onPressed: () {
                                          _openExternalLink('https://twitch.tv/${channel.username}');
                                        },
                                      ),
                                      const SizedBox(height: 4),
                                      _buildOverlayActionItem(
                                        icon: Icons.chat_bubble_outline,
                                        label: 'Open Chat',
                                        onPressed: () {
                                          _openExternalLink('https://twitch.tv/${channel.username}/chat');
                                        },
                                      ),
                                      const SizedBox(height: 4),
                                      _buildOverlayActionItem(
                                        icon: Icons.refresh,
                                        label: 'Refresh Stats',
                                        onPressed: channel.isLoading ? null : () => _fetchChannelStats(channel),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildMiniActionBtn(
                                    icon: Icons.open_in_new,
                                    tooltip: 'Open Twitch channel',
                                    onPressed: () => _openExternalLink('https://twitch.tv/${channel.username}'),
                                  ),
                                  const SizedBox(width: 8),
                                  _buildMiniActionBtn(
                                    icon: Icons.chat_bubble_outline,
                                    tooltip: 'Open Twitch chat popout',
                                    onPressed: () => _openExternalLink('https://twitch.tv/${channel.username}/chat'),
                                  ),
                                  const SizedBox(width: 8),
                                  _buildMiniActionBtn(
                                    icon: Icons.refresh,
                                    tooltip: 'Refresh statistics',
                                    onPressed: channel.isLoading ? null : () => _fetchChannelStats(channel),
                                  ),
                                ],
                              ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (channel.isLive && channel.streamTitle != null) ...[
                      Text(
                        channel.streamTitle!,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, height: 1.3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                    ],
                    Text(
                      channel.isLive
                          ? 'Streaming: ${channel.game ?? "Unknown Game"}'
                          : 'Channel is currently offline',
                      style: TextStyle(
                        fontSize: 13, 
                        color: channel.isLive ? Colors.white70 : Colors.white38,
                        fontWeight: channel.isLive ? FontWeight.w500 : FontWeight.normal
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          const SizedBox(height: 14),
          
          // Row 2: PLAY Button & Stats Chips (perfectly aligned horizontally!)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // PLAY Button Left Block (width: 90 - matches avatar column alignment)
              SizedBox(
                width: 90,
                height: 32,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    elevation: 4,
                  ),
                  onPressed: () => _launchStreamlink(channel.username),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.play_arrow, size: 16),
                      SizedBox(width: 4),
                      Text('PLAY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              
              // Stats Chips Block (Red Area)
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (channel.isLive) ...[
                      _buildHeaderChip(
                        icon: Icons.visibility,
                        color: Colors.redAccent,
                        label: '${channel.viewerCount ?? "0"} viewers',
                      ),
                      _buildHeaderChip(
                        icon: Icons.schedule,
                        color: Colors.orangeAccent,
                        label: channel.uptime ?? 'Live',
                      ),
                    ],
                    _buildHeaderChip(
                      icon: Icons.people,
                      color: theme.primaryColor,
                      label: '${channel.followerCount ?? "N/A"} followers',
                    ),
                    _buildHeaderChip(
                      icon: Icons.update,
                      color: Colors.white38,
                      label: channel.lastUpdated != null
                          ? 'Updated: ${_timeAgo(channel.lastUpdated!)}'
                          : 'Not updated',
                    ),
                  ],
                ),
              ),
            ],
          ),
          
          if (channel.errorMessage != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 90),
                const SizedBox(width: 20),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.redAccent.withOpacity(0.2)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Error: ${channel.errorMessage}',
                            style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeaderChip({required IconData icon, required Color color, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0C0F17),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  // Mini actions helper
  Widget _buildMiniActionBtn({required IconData icon, required String tooltip, required VoidCallback? onPressed}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF374151)),
      ),
      child: IconButton(
        icon: Icon(icon, size: 14, color: Colors.white70),
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        splashRadius: 16,
      ),
    );
  }



  // Console output Widget at the bottom
  Widget _buildConsolePanel(ThemeData theme) {
    if (_playerLogs.isEmpty) return const SizedBox.shrink();

    // Ensure we have a valid selection
    if (_selectedConsoleTabKey == null || !_playerLogs.containsKey(_selectedConsoleTabKey)) {
      _selectedConsoleTabKey = _playerLogs.keys.first;
    }

    final activeKey = _selectedConsoleTabKey!;
    final activeLogs = _playerLogs[activeKey] ?? [];
    final activeController = _playerScrollControllers.putIfAbsent(activeKey, () => ScrollController());
    final isProcessRunning = _activePlayerProcesses.containsKey(activeKey);

    return Container(
      height: _consoleCollapsed ? 38 : 220,
      decoration: const BoxDecoration(
        color: Color(0xFF07090E),
        border: Border(top: BorderSide(color: Color(0xFF1E2433), width: 1.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Console Header / Tab Bar
          Container(
            height: 36,
            color: const Color(0xFF111420),
            child: Row(
              children: [
                // Expand / Collapse Trigger
                IconButton(
                  icon: Icon(
                    _consoleCollapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: Colors.white70,
                  ),
                  onPressed: () {
                    setState(() {
                      _consoleCollapsed = !_consoleCollapsed;
                    });
                  },
                  tooltip: _consoleCollapsed ? 'Expand Console' : 'Collapse Console',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 16,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Terminal Console',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                  ),
                ),
                const SizedBox(width: 16),
                
                // Tabs List
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: _playerLogs.keys.map((key) {
                      final isSelected = key == activeKey;
                      final isRunning = _activePlayerProcesses.containsKey(key);
                      final title = _playerTabTitles[key] ?? key;
                      
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedConsoleTabKey = key;
                            _consoleCollapsed = false;
                          });
                        },
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF1A1F31) : const Color(0xFF0D0F16),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isSelected ? Colors.greenAccent.withOpacity(0.4) : const Color(0xFF1E2433),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Status dot
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: isRunning ? Colors.greenAccent : Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Title
                              Text(
                                title.length > 25 ? '${title.substring(0, 22)}...' : title,
                                style: TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 11,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? Colors.white : Colors.white60,
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Close button
                              GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _playerLogs.remove(key);
                                    _playerTabTitles.remove(key);
                                    _playerScrollControllers.remove(key)?.dispose();
                                    
                                    // If we deleted the active tab, pick another one
                                    if (_selectedConsoleTabKey == key) {
                                      _selectedConsoleTabKey = _playerLogs.keys.isNotEmpty 
                                          ? _playerLogs.keys.first 
                                          : null;
                                    }
                                  });
                                },
                                child: const Icon(Icons.close, size: 10, color: Colors.white38),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                
                // Actions (Kill / Clear)
                if (isProcessRunning) ...[
                  SizedBox(
                    height: 26,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.stop, size: 14),
                      label: const Text('Kill Process', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      onPressed: () {
                        final proc = _activePlayerProcesses[activeKey];
                        if (proc != null) {
                          try {
                            if (Platform.isWindows) {
                              Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
                            } else {
                              proc.kill();
                            }
                          } catch (_) {}
                        }
                      },
                    ),
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 14, color: Colors.white30),
                  onPressed: () {
                    setState(() {
                      _playerLogs[activeKey]?.clear();
                    });
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 16,
                  tooltip: 'Clear Console logs',
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
          
          // Console Log Lines
          if (!_consoleCollapsed)
            Expanded(
              child: SelectionArea(
                child: ListView.builder(
                  controller: activeController,
                  padding: const EdgeInsets.all(12),
                  itemCount: activeLogs.length,
                  itemBuilder: (context, index) {
                    final log = activeLogs[index];
                    Color logColor = Colors.white70;
                    if (log.startsWith('[System Error]') || log.startsWith('[Streamlink Err]') || log.startsWith('[Streamlink ERR]')) {
                      logColor = Colors.redAccent;
                    } else if (log.startsWith('[System]')) {
                      logColor = theme.colorScheme.secondary;
                    } else if (log.contains('[cli][info]')) {
                      logColor = Colors.greenAccent;
                    }

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        log,
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          color: logColor,
                          height: 1.3,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class HoverOverlayMenu extends StatefulWidget {
  final Widget trigger;
  final Widget menu;
  
  const HoverOverlayMenu({
    Key? key,
    required this.trigger,
    required this.menu,
  }) : super(key: key);

  @override
  State<HoverOverlayMenu> createState() => _HoverOverlayMenuState();
}

class _HoverOverlayMenuState extends State<HoverOverlayMenu> {
  OverlayEntry? _entry;
  final LayerLink _layerLink = LayerLink();
  bool _isHovered = false;

  void _showMenu() {
    if (_entry != null) return;
    
    _entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 0,
        top: 0,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 8),
          child: MouseRegion(
            onEnter: (_) {
              setState(() => _isHovered = true);
            },
            onExit: (_) {
              setState(() => _isHovered = false);
              _hideMenu();
            },
            child: Theme(
              data: Theme.of(context),
              child: Material(
                color: Colors.transparent,
                child: widget.menu,
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _hideMenu() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      if (!_isHovered) {
        _entry?.remove();
        _entry = null;
      }
    });
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        onEnter: (_) {
          setState(() => _isHovered = true);
          _showMenu();
        },
        onExit: (_) {
          setState(() => _isHovered = false);
          _hideMenu();
        },
        child: widget.trigger,
      ),
    );
  }
}

class HoverStarIcon extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onTap;
  
  const HoverStarIcon({
    Key? key,
    required this.isFavorite,
    required this.onTap,
  }) : super(key: key);

  @override
  State<HoverStarIcon> createState() => _HoverStarIconState();
}

class _HoverStarIconState extends State<HoverStarIcon> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final useGold = widget.isFavorite || _isHovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: IconButton(
        icon: Icon(
          useGold ? Icons.star : Icons.star_border,
          color: useGold ? Colors.amber : Colors.white30,
          size: 18,
        ),
        onPressed: widget.onTap,
        tooltip: widget.isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
        splashRadius: 18,
      ),
    );
  }
}
