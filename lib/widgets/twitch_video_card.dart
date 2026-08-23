import 'package:flutter/material.dart';
import '../models/twitch_video.dart';
import '../utils/time_utils.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_progress.dart';
import '../theme/theme_notifier.dart';

class TwitchVideoCard extends StatefulWidget {
  final TwitchVideo vod;
  final double scale;
  final ThemeData theme;
  final VoidCallback onPlay;
  final String Function(String) formatNumber;
  /// The rendered title size, in logical pixels.
  ///
  /// It used to be a base that the card multiplied by 1.0-1.8 depending on
  /// [scale], so the number in Settings was never the number on screen - at
  /// the shipped defaults it read 14 and rendered 18.2, and at scale 600 with
  /// the slider at 20 it reached 36. Stored values are migrated to their
  /// effective size on load, so nobody's cards change size.
  final double titleFontSize;
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
    required this.titleFontSize,
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
          borderRadius: BorderRadius.circular(NeuRadius.r16),
          hoverColor: Colors.white.withValues(alpha: 0.2),
          splashColor: Colors.white.withValues(alpha: 0.3),
          child: Container(
            padding: const EdgeInsets.all(NeuSpace.s4),
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
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(NeuRadius.r4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sports_esports, size: 10, color: Colors.white70),
          const SizedBox(width: NeuSpace.s4),
          Text(
            firstGame,
            style: NeuType.plate(true, color: Colors.white),
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
              borderRadius: BorderRadius.circular(NeuRadius.r4),
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
              borderRadius: BorderRadius.circular(NeuRadius.r4),
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
              radius: NeuRadius.r16,
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
                  // The bezel goes in FRONT of the picture, which is why it is
                  // a foregroundDecoration and not the decoration. A background
                  // one would paint behind the image and be invisible; the
                  // thumbnail fills its box edge to edge.
                  //
                  // Null on any material that declares no bezel, and a null
                  // foregroundDecoration paints nothing - so Soft renders this
                  // exactly as it always has, with no branch here.
                  child: Container(
                    foregroundDecoration: NeuTheme.bezel(
                      themeNotifier.isDarkTheme,
                      radius: NeuRadius.inner(NeuRadius.r16, 1),
                    ),
                    child: ClipRRect(
                    // Concentric: the card is 16 with a 1px border, so a
                    // flush child is 15. At 11 the corners left a visible
                    // crescent of card colour inside the thumbnail's edge.
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(NeuRadius.inner(NeuRadius.r16, 1)),
                      topRight: Radius.circular(NeuRadius.inner(NeuRadius.r16, 1)),
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
                                padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.75),
                                  borderRadius: BorderRadius.circular(NeuRadius.r4),
                                ),
                                child: Text(
                                  _formatTwitchStyleDuration(widget.vod.duration),
                                  style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: Colors.white),
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
                                          radius: NeuRadius.r12,
                                          border: Border.all(color: themeNotifier.accentInk, width: 2),
                                        )
                                      : NeuTheme.sunkenDecoration(
                                          themeNotifier.isDarkTheme,
                                          radius: NeuRadius.r12,
                                        ),
                                  child: widget.isSelected
                                      ? Icon(Icons.check_rounded, size: 14, color: themeNotifier.accentInk)
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
                                                // Intentional: sub-grid. A 2px scrim pill over artwork; 4 would
                                                    // swallow the 10px label it wraps.
                                                    padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s4, vertical: 2.5),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withValues(alpha: 0.75),
                                                  borderRadius: BorderRadius.circular(NeuRadius.r4),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    const Icon(Icons.sports_esports, size: 9, color: Colors.white70),
                                                    const SizedBox(width: NeuSpace.s4),
                                                    Text(
                                                      game,
                                                      style: NeuType.plate(themeNotifier.isDarkTheme, color: Colors.white),
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
                                            borderRadius: BorderRadius.circular(NeuRadius.r6),
                                            border: Border.all(color: NeuTheme.border(themeNotifier.isDarkTheme)),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(alpha: 0.2),
                                                blurRadius: 6,
                                              ),
                                            ],
                                          ),
                                          textStyle: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)).copyWith(height: 1.3),
                                          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
                                          preferBelow: true,
                                          child: _buildGameBadge(widget.theme),
                                        ),
                                      const SizedBox(width: NeuSpace.s8),
                                    ],
                                    if (widget.isPlaying && widget.pulseController != null)
                                      RepaintBoundary(
                                          child: AnimatedBuilder(
                                        animation: widget.pulseController!,
                                        builder: (context, child) {
                                          return Container(
                                            padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s4),
                                            decoration: BoxDecoration(
                                              color: widget.theme.primaryColor.withValues(alpha: 0.85 + 0.15 * widget.pulseController!.value),
                                              borderRadius: BorderRadius.circular(NeuRadius.r4),
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
                                            const SizedBox(width: NeuSpace.s4),
                                            Text(
                                              'NOW PLAYING',
                                              style: NeuType.plate(themeNotifier.isDarkTheme, color: themeNotifier.onPrimaryColor),
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
                                      padding: const EdgeInsets.all(NeuSpace.s8),
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
                                      const SizedBox(height: NeuSpace.s12),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.85),
                                            borderRadius: BorderRadius.circular(NeuRadius.r6),
                                            border: Border.all(color: Colors.white24, width: 0.5),
                                          ),
                                          child: Text(
                                            _games!.join('  •  '),
                                            textAlign: TextAlign.center,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: NeuType.plate(themeNotifier.isDarkTheme, color: Colors.white),
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
                            padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: BorderRadius.circular(NeuRadius.r4),
                            ),
                            child: Text(
                              '${widget.formatNumber(widget.vod.viewCount)} views',
                              style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: Colors.white),
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
                                          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.9),
                                            borderRadius: BorderRadius.circular(NeuRadius.r6),
                                            border: Border.all(color: NeuTheme.live.withValues(alpha: 0.5), width: 1.0),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (widget.downloadProgress != null) ...[
                                                NeuProgressRing(
                                                  value: widget.downloadProgress,
                                                  size: NeuProgressRingSize.xs,
                                                  color: NeuTheme.live,
                                                  semanticLabel: 'Downloading',
                                                ),
                                                const SizedBox(width: NeuSpace.s8),
                                              ],
                                              Text(
                                                widget.downloadStatus!,
                                                style: NeuType.plate(themeNotifier.isDarkTheme, color: NeuTheme.live),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (_isHovered) ...[
                                          const SizedBox(width: NeuSpace.s6),
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
                                                  const SizedBox(width: NeuSpace.s6),
                                                  _buildCardButton(
                                                    onTap: widget.onOpenFolder!,
                                                    icon: Icons.folder_open,
                                                    backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                                    tooltip: 'Show in Explorer',
                                                  ),
                                                ],
                                                const SizedBox(width: NeuSpace.s6),
                                                _buildCardButton(
                                                  onTap: widget.onDeleteDownload,
                                                  icon: Icons.delete,
                                                  backgroundColor: NeuTheme.danger,
                                                  tooltip: 'Delete Download',
                                                ),
                                              ],
                                            )
                                          : Container(
                                              padding: const EdgeInsets.all(NeuSpace.s4),
                                              decoration: NeuTheme.raisedDecoration(
                                                themeNotifier.isDarkTheme,
                                                radius: NeuRadius.r12,
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
                                              padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s4),
                                              decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r4),
                                              child: Text(
                                                timeAgo(widget.vod.publishedAt),
                                                style: NeuType.captionStrong(themeNotifier.isDarkTheme),
                                              ),
                                            )))),
                        ),
                      ],
                    ),
                  ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.vod.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: NeuType.bodyStrong(themeNotifier.isDarkTheme,
                                color: themeNotifier.textColor)
                            // Intentional: the one user-settable size in the
                            // app. The step supplies the weight and ink.
                            .copyWith(
                                fontSize: widget.titleFontSize,
                                fontWeight: FontWeight.w700,
                                height: 1.25),
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
