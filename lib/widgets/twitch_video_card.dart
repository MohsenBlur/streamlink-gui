import 'package:flutter/material.dart';
import '../models/twitch_video.dart';

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
                                        ? widget.watchedProgressColor
                                        : widget.activeProgressColor,
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

                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: (!widget.isMultiSelectMode && (_isHovered || widget.downloadStatus != null || widget.isDownloaded))
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (widget.downloadStatus != null) ...[
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
