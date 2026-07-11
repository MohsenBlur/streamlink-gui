import 'package:flutter/material.dart';
import '../models/twitch_video.dart';
import 'twitch_video_card.dart';
import 'hover_overlay_menu.dart';

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
  }) : super(key: key);

  @override
  State<VodsGrid> createState() => _VodsGridState();
}

class _VodsGridState extends State<VodsGrid> {
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

    if (filteredVods.isEmpty) {
      return Padding(
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
    }

    final childAspectRatio = 1.0 + ((widget.vodScale - 200) / 400.0) * 0.25;

    return GridView.builder(
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
}
