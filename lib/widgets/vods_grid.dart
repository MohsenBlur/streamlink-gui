import 'package:flutter/material.dart';
import '../models/twitch_video.dart';
import 'twitch_video_card.dart';
import 'horizontal_mouse_scrollable.dart';
import 'neumorphic/neu_button.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_progress.dart';
import '../theme/theme_notifier.dart';

class VodsGrid extends StatefulWidget {
  final List<TwitchVideo> vods;
  final bool isLoading;
  final String? vodsError;
  final double vodScale;
  final double vodTitleFontSize;
  final bool showGamesOnThumbnails;
  final Set<String> selectedGamesFilter;
  final TextEditingController vodSearchController;
  final ThemeData theme;
  
  final bool isMultiSelectMode;
  final Set<String> selectedVodIds;
  final bool Function(String) isPlaying;
  final bool Function(String) isDownloaded;
  final String? Function(String) getDownloadStatus;
  final double? Function(String) getDownloadProgress;
  final AnimationController? pulseController;
  final int watchedThreshold;
  final Color activeProgressColor;
  final Color watchedProgressColor;

  final ValueChanged<String> onGameFilterSelected;
  final VoidCallback onClearGameFilter;
  
  final void Function(TwitchVideo) onPlay;
  final void Function(TwitchVideo) onDownload;
  final void Function(String) onDeleteDownload;
  final void Function(String) onCancelDownload;
  final void Function(String, bool) onVodSelectedChange;
  final void Function(TwitchVideo)? onOpenFolder;

  const VodsGrid({
    Key? key,
    required this.vods,
    required this.isLoading,
    required this.vodsError,
    required this.vodScale,
    required this.vodTitleFontSize,
    required this.showGamesOnThumbnails,
    required this.selectedGamesFilter,
    required this.vodSearchController,
    required this.theme,
    required this.isMultiSelectMode,
    required this.selectedVodIds,
    required this.isPlaying,
    required this.isDownloaded,
    required this.getDownloadStatus,
    required this.getDownloadProgress,
    required this.pulseController,
    required this.watchedThreshold,
    required this.activeProgressColor,
    required this.watchedProgressColor,
    required this.onGameFilterSelected,
    required this.onClearGameFilter,
    required this.onPlay,
    required this.onDownload,
    required this.onDeleteDownload,
    required this.onCancelDownload,
    required this.onVodSelectedChange,
    this.onOpenFolder,
  }) : super(key: key);

  @override
  State<VodsGrid> createState() => _VodsGridState();
}

class _VodsGridState extends State<VodsGrid> {
  late ScrollController _gameScrollController;
  bool _showLeftIndicator = false;
  bool _showRightIndicator = false;

  @override
  void initState() {
    super.initState();
    _gameScrollController = ScrollController();
    _gameScrollController.addListener(_updateScrollIndicators);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateScrollIndicators();
    });
  }

  @override
  void dispose() {
    _gameScrollController.removeListener(_updateScrollIndicators);
    _gameScrollController.dispose();
    super.dispose();
  }

  void _updateScrollIndicators() {
    if (!_gameScrollController.hasClients) return;
    final isScrollable = _gameScrollController.position.maxScrollExtent > 0.0;
    final showLeft = isScrollable && _gameScrollController.offset > 2.0;
    final showRight = isScrollable && _gameScrollController.offset < (_gameScrollController.position.maxScrollExtent - 2.0);

    if (showLeft != _showLeftIndicator || showRight != _showRightIndicator) {
      setState(() {
        _showLeftIndicator = showLeft;
        _showRightIndicator = showRight;
      });
    }
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

  /// Builds SLIVERS: this widget must live inside a CustomScrollView. The
  /// grid used to be a shrinkWrap GridView inside the page's scroll view,
  /// which materialized every card at once; SliverGrid culls off-screen ones.
  @override
  Widget build(BuildContext context) {
    if (widget.isLoading && widget.vods.isEmpty) {
      return const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: NeuProgressRing(semanticLabel: 'Loading broadcasts'),
          ),
        ),
      );
    }

    if (widget.vodsError != null) {
      return SliverToBoxAdapter(
        child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: NeuTheme.danger.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: NeuTheme.danger.withValues(alpha: 0.3)),
        ),
        child: Text(
          'Error loading VODs: ${widget.vodsError}',
          style: TextStyle(color: NeuTheme.dangerText(themeNotifier.isDarkTheme), fontSize: 13),
        ),
        ),
      );
    }
    
    final searchQuery = widget.vodSearchController.text.trim().toLowerCase();
    final filteredVods = widget.vods.where((vod) {
      final matchesSearch = searchQuery.isEmpty ||
          vod.title.toLowerCase().contains(searchQuery) ||
          vod.games.any((game) => game.toLowerCase().contains(searchQuery));
      final matchesGameFilter = widget.selectedGamesFilter.isEmpty ||
          vod.games.any((game) => widget.selectedGamesFilter.contains(game));
      return matchesSearch && matchesGameFilter;
    }).toList();

    final allGames = <String>{};
    for (final vod in widget.vods) {
      if (vod.games.isNotEmpty) {
        allGames.addAll(vod.games);
      }
    }
    final sortedGames = allGames.toList()..sort();

    Widget buildGameChips() {
      if (sortedGames.isEmpty) return const SizedBox.shrink();
      
      return Container(
        height: 38,
        margin: const EdgeInsets.only(bottom: 16),
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            _updateScrollIndicators();
            return false;
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: HorizontalMouseScrollable(
                  controller: _gameScrollController,
                  child: Row(
                    children: List.generate(sortedGames.length + 1, (index) {
                      final isAll = index == 0;
                      final game = isAll ? 'All Games' : sortedGames[index - 1];
                      final isSelected = isAll 
                          ? widget.selectedGamesFilter.isEmpty 
                          : widget.selectedGamesFilter.contains(game);
                          
                      return Container(
                        margin: EdgeInsets.only(
                          left: isAll ? 0 : 4,
                          right: (index == sortedGames.length) ? 0 : 4,
                        ),
                        child: NeuButton(
                          onPressed: () {
                            if (isAll) {
                              widget.onClearGameFilter();
                            } else {
                              widget.onGameFilterSelected(game);
                            }
                          },
                          isSelected: isSelected,
                          borderRadius: BorderRadius.circular(18),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Selected chips sit on NeuButton's translucent
                              // accent TINT, so the readable color is the accent
                              // itself (NeuButton's own selected text style).
                              if (isSelected) ...[
                                Icon(Icons.check, size: 13, color: themeNotifier.accentInk),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                game,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                  color: isSelected
                                      ? widget.theme.primaryColor
                                      : themeNotifier.textColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
              if (_showLeftIndicator)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 32,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            themeNotifier.backgroundColor,
                            themeNotifier.backgroundColor.withValues(alpha: 0.0),
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                      ),
                    ),
                  ),
                ),
              if (_showRightIndicator)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: 32,
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            themeNotifier.backgroundColor.withValues(alpha: 0.0),
                            themeNotifier.backgroundColor,
                          ],
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final childAspectRatio = 1.0 + ((widget.vodScale - 200) / 400.0) * 0.25;

    Widget contentSliver;
    if (filteredVods.isEmpty) {
      contentSliver = SliverToBoxAdapter(
        child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            widget.selectedGamesFilter.isNotEmpty
                ? 'No past broadcasts match game filter "${widget.selectedGamesFilter.join(', ')}".'
                : (searchQuery.isEmpty ? 'No past broadcasts found.' : 'No VODs match "$searchQuery".'),
            style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 13),
          ),
        ),
        ),
      );
    } else {
      contentSliver = SliverGrid.builder(
        itemCount: filteredVods.length,
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: widget.vodScale,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          childAspectRatio: childAspectRatio,
        ),
        itemBuilder: (context, index) {
          final vod = filteredVods[index];
          return TwitchVideoCard(
            key: ValueKey(vod.id),
            vod: vod,
            scale: widget.vodScale,
            theme: widget.theme,
            onPlay: () => widget.onPlay(vod),
            formatNumber: _formatNumberString,
            fontSize: widget.vodTitleFontSize,
            isPlaying: widget.isPlaying(vod.id),
            pulseController: widget.pulseController,
            showGamesOnThumbnails: widget.showGamesOnThumbnails,
            watchedThreshold: widget.watchedThreshold,
            activeProgressColor: widget.activeProgressColor,
            watchedProgressColor: widget.watchedProgressColor,
            isMultiSelectMode: widget.isMultiSelectMode,
            isSelected: widget.selectedVodIds.contains(vod.id),
            onSelected: (isSelected) => widget.onVodSelectedChange(vod.id, isSelected ?? false),
            downloadStatus: widget.getDownloadStatus(vod.id),
            downloadProgress: widget.getDownloadProgress(vod.id),
            isDownloaded: widget.isDownloaded(vod.id),
            onDownload: () => widget.onDownload(vod),
            onDeleteDownload: () => widget.onDeleteDownload(vod.id),
            onCancel: () => widget.onCancelDownload(vod.id),
            onOpenFolder:
                widget.onOpenFolder == null ? null : () => widget.onOpenFolder!(vod),
          );
        },
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: buildGameChips()),
        contentSliver,
      ],
    );
  }
}
