import 'package:flutter/material.dart';
import '../models/twitch_video.dart';
import '../utils/time_utils.dart';
import '../theme/neu_theme.dart';
import '../theme/theme_notifier.dart';

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
  final VoidCallback? onOpenFolder;
  final Color activeProgressColor;
  final Color watchedProgressColor;

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
    required this.activeProgressColor,
    required this.watchedProgressColor,
    this.isMultiSelectMode = false,
    this.isSelected = false,
    this.onSelected,
    this.downloadStatus,
    this.downloadProgress,
    this.isDownloaded = false,
    required this.onDownload,
    required this.onDeleteDownload,
    required this.onCancel,
    this.onOpenFolder,
  }) : super(key: key);

  @override
  State<TwitchVideoCard> createState() => _TwitchVideoCardState();
}

// Intentional: the white-on-black pills/scrims in this file sit over video
// artwork, not app surfaces, and stay theme-independent by design.
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
          hoverColor: Colors.white.withValues(alpha: 0.2),
          splashColor: Colors.white.withValues(alpha: 0.3),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: backgroundColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              icon,
              size: 15,
              color: NeuTheme.onAccent(backgroundColor),
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


  Widget _buildGameBadge(ThemeData theme) {
    final firstGame = _games![0];
    final hasMultiple = _games!.length > 1;
    
    final mainBadge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
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
        Positioned(
          top: 4,
          left: 4,
          right: -4,
          bottom: -4,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        Positioned(
          top: 2,
          left: 2,
          right: -2,
          bottom: -2,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        mainBadge,
      ],
    );
  }

  /// Quantized CDN thumbnail width. Deriving the URL from the raw slider
  /// value minted a fresh URL for every pixel of a card-size drag - hundreds
  /// of image downloads per drag. Four buckets cover the whole scale x DPR
  /// range; a bucket change swaps gaplessly instead of flashing blank.
  static int _thumbBucket(double logicalWidth) {
    if (logicalWidth <= 320) return 320;
    if (logicalWidth <= 480) return 480;
    if (logicalWidth <= 640) return 640;
    return 960;
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = _thumbBucket(widget.scale * dpr);
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
              : (widget.isPlaying ? null : widget.onPlay),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, _isHovered ? -4 : 0, 0),
            decoration: NeuTheme.raisedDecoration(
              themeNotifier.isDarkTheme,
              radius: 16,
              border: widget.isSelected || widget.isPlaying
                  ? Border.all(
                      color: widget.theme.primaryColor,
                      width: widget.isSelected ? 2.5 : 2.0,
                    )
                  : (_isHovered
                      ? Border.all(color: widget.theme.primaryColor.withValues(alpha: 0.6), width: 1.5)
                      : null),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                        AnimatedScale(
                          scale: _isHovered ? 1.035 : 1.0,
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          child: thumbnailUrl != null
                              ? Image.network(
                                  thumbnailUrl,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  frameBuilder: (context, child, frame, wasSyncLoaded) {
                                    if (wasSyncLoaded) return child;
                                    return AnimatedOpacity(
                                      opacity: frame == null ? 0 : 1,
                                      duration: const Duration(milliseconds: 180),
                                      curve: Curves.easeOut,
                                      child: child,
                                    );
                                  },
                                  errorBuilder: (context, error, stackTrace) => Container(
                                    color: NeuTheme.surface(themeNotifier.isDarkTheme),
                                    child: Icon(Icons.movie, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 32),
                                  ),
                                )
                              : Container(
                                  color: NeuTheme.surface(themeNotifier.isDarkTheme),
                                  child: Icon(Icons.movie, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 32),
                                ),
                        ),

                         if (widget.vod.watchProgress != null && widget.vod.watchProgress! > 0.0)
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              height: _isHovered ? 6.0 : 4.0,
                              color: Colors.black45,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: (widget.vod.watchProgress! >= (widget.watchedThreshold / 100.0))
                                      ? 1.0
                                      : widget.vod.watchProgress!.clamp(0.0, 1.0),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: (widget.vod.watchProgress! >= (widget.watchedThreshold / 100.0))
                                            ? [
                                                widget.watchedProgressColor.withValues(alpha: 0.8),
                                                widget.watchedProgressColor,
                                              ]
                                            : [
                                                widget.activeProgressColor,
                                                widget.activeProgressColor.withValues(alpha: 0.8),
                                              ],
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: (widget.vod.watchProgress! >= (widget.watchedThreshold / 100.0))
                                              ? widget.watchedProgressColor.withValues(alpha: 0.6)
                                              : widget.activeProgressColor.withValues(alpha: 0.6),
                                          blurRadius: _isHovered ? 8.0 : 2.0,
                                          spreadRadius: _isHovered ? 1.0 : 0.0,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                        Positioned(
                          top: 8,
                          left: 8,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.75),
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

                        Positioned(
                          top: 8,
                          right: 8,
                          child: widget.isMultiSelectMode
                              ? AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  width: 24,
                                  height: 24,
                                  decoration: widget.isSelected
                                      ? NeuTheme.raisedDecoration(
                                          themeNotifier.isDarkTheme,
                                          radius: 12,
                                          border: Border.all(color: widget.theme.primaryColor, width: 2),
                                        )
                                      : NeuTheme.sunkenDecoration(
                                          themeNotifier.isDarkTheme,
                                          radius: 12,
                                        ),
                                  child: widget.isSelected
                                      ? Icon(Icons.check_rounded, size: 14, color: widget.theme.primaryColor)
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
                                                  color: Colors.black.withValues(alpha: 0.75),
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
                                            color: NeuTheme.surface(themeNotifier.isDarkTheme),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: NeuTheme.border(themeNotifier.isDarkTheme)),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(alpha: 0.2),
                                                blurRadius: 6,
                                              ),
                                            ],
                                          ),
                                          textStyle: TextStyle(color: NeuTheme.text(themeNotifier.isDarkTheme), fontSize: 11, fontWeight: FontWeight.w600, height: 1.3),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                          preferBelow: true,
                                          child: _buildGameBadge(widget.theme),
                                        ),
                                      const SizedBox(width: 8),
                                    ],
                                    if (widget.isPlaying && widget.pulseController != null)
                                      RepaintBoundary(
                                          child: AnimatedBuilder(
                                        animation: widget.pulseController!,
                                        builder: (context, child) {
                                          return Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: widget.theme.primaryColor.withValues(alpha: 0.85 + 0.15 * widget.pulseController!.value),
                                              borderRadius: BorderRadius.circular(4),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: widget.theme.primaryColor.withValues(alpha: 0.5 * widget.pulseController!.value),
                                                  blurRadius: 4,
                                                )
                                              ]
                                            ),
                                            child: child,
                                          );
                                        },
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.play_arrow, size: 10, color: themeNotifier.onPrimaryColor),
                                            const SizedBox(width: 4),
                                            Text(
                                              'NOW PLAYING',
                                              style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.bold, color: themeNotifier.onPrimaryColor, letterSpacing: 0.5),
                                            ),
                                          ],
                                        ),
                                      )),
                                  ],
                                ),
                        ),

                        if (!widget.isMultiSelectMode)
                          Positioned.fill(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 150),
                              opacity: (_isHovered && !widget.isPlaying) ? 1.0 : 0.0,
                              child: Container(
                                color: Colors.black.withValues(alpha: 0.4),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.black.withValues(alpha: 0.6),
                                        border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2.0),
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
                                            color: Colors.black.withValues(alpha: 0.85),
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

                        Positioned(
                          bottom: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${widget.formatNumber(widget.vod.viewCount)} views',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ),
                        ),

                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: widget.isMultiSelectMode
                              ? const SizedBox.shrink()
                              : (widget.downloadStatus != null
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.9),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: NeuTheme.live.withValues(alpha: 0.5), width: 1.0),
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
                                                    valueColor: const AlwaysStoppedAnimation(NeuTheme.live),
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
                                                  color: NeuTheme.live,
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
                                            backgroundColor: NeuTheme.danger,
                                            tooltip: 'Cancel Download',
                                          ),
                                        ],
                                      ],
                                    )
                                  : (widget.isDownloaded
                                      ? (_isHovered
                                          ? Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildCardButton(
                                                  onTap: widget.onPlay,
                                                  icon: Icons.play_arrow,
                                                  backgroundColor: NeuTheme.live,
                                                  tooltip: 'Play Local VOD',
                                                ),
                                                if (widget.onOpenFolder != null) ...[
                                                  const SizedBox(width: 6),
                                                  _buildCardButton(
                                                    onTap: widget.onOpenFolder!,
                                                    icon: Icons.folder_open,
                                                    backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                                    tooltip: 'Show in Explorer',
                                                  ),
                                                ],
                                                const SizedBox(width: 6),
                                                _buildCardButton(
                                                  onTap: widget.onDeleteDownload,
                                                  icon: Icons.delete,
                                                  backgroundColor: NeuTheme.danger,
                                                  tooltip: 'Delete Download',
                                                ),
                                              ],
                                            )
                                          : Container(
                                              padding: const EdgeInsets.all(5),
                                              decoration: NeuTheme.raisedDecoration(
                                                themeNotifier.isDarkTheme,
                                                radius: 12,
                                                border: Border.all(color: NeuTheme.liveText(themeNotifier.isDarkTheme), width: 1.5),
                                              ),
                                              child: Icon(
                                                Icons.check_rounded,
                                                size: 14,
                                                color: NeuTheme.liveText(themeNotifier.isDarkTheme),
                                              ),
                                            ))
                                      : (_isHovered
                                          ? _buildCardButton(
                                              onTap: widget.onDownload,
                                              icon: Icons.download,
                                              backgroundColor: widget.theme.primaryColor,
                                              tooltip: 'Download VOD',
                                            )
                                          : Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                              decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 4),
                                              child: Text(
                                                timeAgo(widget.vod.publishedAt),
                                                style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11, fontWeight: FontWeight.bold),
                                              ),
                                            )))),
                        ),
                      ],
                    ),
                  ),
                ),
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
                          color: themeNotifier.textColor, 
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

    return buildCardContent();
  }
}
