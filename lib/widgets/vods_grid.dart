import 'package:flutter/material.dart';
import '../models/twitch_video.dart';
import 'twitch_video_card.dart';
import 'hover_overlay_menu.dart';
import 'package:flutter/gestures.dart';

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

  final ValueChanged<double> onScaleChanged;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<bool> onShowGamesChanged;
  final ValueChanged<String> onGameFilterSelected;
  final VoidCallback onClearGameFilter;
  final VoidCallback onToggleMultiSelect;
  final VoidCallback onSelectAllVisible;
  final VoidCallback onDeselectAll;
  
  final void Function(TwitchVideo) onPlay;
  final void Function(TwitchVideo) onDownload;
  final void Function(String) onDeleteDownload;
  final void Function(String) onCancelDownload;
  final void Function(String, bool) onVodSelectedChange;
  final VoidCallback? onBulkDownload;
  final VoidCallback? onBulkDelete;

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
    required this.onScaleChanged,
    required this.onFontSizeChanged,
    required this.onShowGamesChanged,
    required this.onGameFilterSelected,
    required this.onClearGameFilter,
    required this.onToggleMultiSelect,
    required this.onSelectAllVisible,
    required this.onDeselectAll,
    required this.onPlay,
    required this.onDownload,
    required this.onDeleteDownload,
    required this.onCancelDownload,
    required this.onVodSelectedChange,
    this.onBulkDownload,
    this.onBulkDelete,
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

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading && widget.vods.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: CircularProgressIndicator(),
        ),
      );
    }
    
    if (widget.vodsError != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: Text(
          'Error loading VODs: ${widget.vodsError}',
          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
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
                child: Listener(
                  onPointerSignal: (pointerSignal) {
                    if (pointerSignal is PointerScrollEvent) {
                      GestureBinding.instance.pointerSignalResolver.register(pointerSignal, (event) {
                        if (event is PointerScrollEvent && _gameScrollController.hasClients) {
                          final delta = event.scrollDelta.dy != 0.0
                              ? event.scrollDelta.dy
                              : event.scrollDelta.dx;
                          if (delta != 0.0) {
                            final newOffset = (_gameScrollController.offset + delta).clamp(
                              0.0,
                              _gameScrollController.position.maxScrollExtent,
                            );
                            _gameScrollController.jumpTo(newOffset);
                          }
                        }
                      });
                    }
                  },
                  child: ListView.builder(
                    controller: _gameScrollController,
                    scrollDirection: Axis.horizontal,
                    itemCount: sortedGames.length + 1,
                    itemBuilder: (context, index) {
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
                        child: FilterChip(
                          selected: isSelected,
                          label: Text(
                            game,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: isSelected ? Colors.white : Colors.white70,
                            ),
                          ),
                          backgroundColor: const Color(0xFF161B26),
                          selectedColor: widget.theme.primaryColor,
                          checkmarkColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: BorderSide(
                              color: isSelected ? Colors.transparent : Colors.white10,
                            ),
                          ),
                          onSelected: (selected) {
                            if (isAll) {
                              widget.onClearGameFilter();
                            } else {
                              widget.onGameFilterSelected(game);
                            }
                          },
                        ),
                      );
                    },
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
                            const Color(0xFF0C0F17),
                            const Color(0xFF0C0F17).withOpacity(0.0),
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
                            const Color(0xFF0C0F17).withOpacity(0.0),
                            const Color(0xFF0C0F17),
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

    Widget contentWidget;
    if (filteredVods.isEmpty) {
      contentWidget = Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            widget.selectedGamesFilter.isNotEmpty
                ? 'No past broadcasts match game filter "${widget.selectedGamesFilter.join(', ')}".'
                : (searchQuery.isEmpty ? 'No past broadcasts found.' : 'No VODs match "$searchQuery".'),
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    } else {
      contentWidget = GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
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
          );
        },
      );
    }

    final mainColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildGameChips(),
        contentWidget,
      ],
    );

    return Stack(
      alignment: Alignment.bottomCenter,
      clipBehavior: Clip.none,
      children: [
        mainColumn,
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          bottom: widget.isMultiSelectMode ? 16 : -70,
          left: 20,
          right: 20,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: widget.isMultiSelectMode ? 1.0 : 0.0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF161B26).withOpacity(0.85),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: widget.theme.primaryColor.withOpacity(0.3), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_box_outlined, color: widget.theme.primaryColor, size: 20),
                    const SizedBox(width: 10),
                    Text(
                      '${widget.selectedVodIds.length} VODs Selected',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                    ),
                    const SizedBox(width: 20),
                    Container(width: 1, height: 18, color: Colors.white12),
                    const SizedBox(width: 20),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: widget.theme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: widget.selectedVodIds.isEmpty ? null : widget.onBulkDownload,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Bulk Download', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent.withOpacity(0.15),
                        foregroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        side: BorderSide(color: Colors.redAccent.withOpacity(0.4)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: widget.selectedVodIds.isEmpty ? null : widget.onBulkDelete,
                      icon: const Icon(Icons.delete, size: 16),
                      label: const Text('Bulk Delete', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 12),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: Colors.white54),
                      onPressed: widget.onDeselectAll,
                      child: const Text('Deselect All', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
