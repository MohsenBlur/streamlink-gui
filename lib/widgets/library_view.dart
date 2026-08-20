import 'package:flutter/material.dart';

import '../state/library_entries.dart';
import '../theme/neu_theme.dart';
import '../theme/theme_notifier.dart';
import 'neumorphic/neu_button.dart';
import 'neumorphic/neu_text_field.dart';

enum LibrarySort { newest, largest, progress }

/// The Library: every VOD the app knows about as a dense, file-management
/// oriented row list - downloaded files (size, open-folder, delete) and
/// streamed watch history. Deliberately NOT the thumbnail card grid: registry
/// -only entries have no artwork or duration, and the jobs here are "find it,
/// play it, free the disk space".
class LibraryView extends StatefulWidget {
  const LibraryView({
    Key? key,
    required this.entries,
    required this.onRefresh,
    required this.onPlay,
    required this.onOpenFolder,
    required this.onDelete,
    required this.onRemoveFromHistory,
  }) : super(key: key);

  final List<LibraryEntry> entries;
  final VoidCallback onRefresh;
  final void Function(LibraryEntry) onPlay;
  final void Function(LibraryEntry) onOpenFolder;
  final void Function(LibraryEntry) onDelete;
  final void Function(LibraryEntry) onRemoveFromHistory;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final TextEditingController _search = TextEditingController();
  String? _channelFilter;
  LibrarySort _sort = LibrarySort.newest;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<LibraryEntry> get _visible {
    var list = filterLibraryEntries(widget.entries, _search.text);
    if (_channelFilter != null) {
      list = list.where((e) => e.channel == _channelFilter).toList();
    }
    switch (_sort) {
      case LibrarySort.newest:
        break; // buildLibraryEntries already sorts newest-first
      case LibrarySort.largest:
        list = [...list]..sort((a, b) =>
            (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1));
      case LibrarySort.progress:
        list = [...list]..sort((a, b) =>
            (b.watchProgress ?? -1).compareTo(a.watchProgress ?? -1));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = themeNotifier.isDarkTheme;
    final downloaded = widget.entries.where((e) => e.isDownloaded).toList();
    final totalBytes =
        downloaded.fold<int>(0, (sum, e) => sum + (e.sizeBytes ?? 0));
    final channels = widget.entries.map((e) => e.channel).toSet().toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final visible = _visible;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Row(
            children: [
              Icon(Icons.video_library, color: theme.primaryColor, size: 22),
              const SizedBox(width: 10),
              Text('Library', style: NeuTheme.titleStyle(isDark, fontSize: 18)),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: NeuTheme.sunkenDecoration(isDark, radius: 8),
                child: Text(
                  '${downloaded.length} download${downloaded.length == 1 ? '' : 's'} · ${formatBytes(totalBytes)}',
                  style: NeuTheme.subtextStyle(isDark, fontSize: 11),
                ),
              ),
              const Spacer(),
              _sortButton(theme, LibrarySort.newest, 'Newest'),
              const SizedBox(width: 6),
              _sortButton(theme, LibrarySort.largest, 'Largest'),
              const SizedBox(width: 6),
              _sortButton(theme, LibrarySort.progress, 'Progress'),
              const SizedBox(width: 12),
              NeuButton(
                padding: const EdgeInsets.all(8),
                borderRadius: BorderRadius.circular(8),
                tooltip: 'Rescan the download folder',
                onPressed: widget.onRefresh,
                child: Icon(Icons.refresh,
                    size: 16, color: NeuTheme.text(isDark)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
          child: Row(
            children: [
              SizedBox(
                width: 280,
                child: NeuTextField(
                  controller: _search,
                  hintText: 'Search library...',
                  prefixIcon: Icons.search,
                  onChanged: (_) => setState(() {}),
                  onClear: () => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      _channelChip(theme, null, 'All'),
                      for (final ch in channels) _channelChip(theme, ch, ch),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    widget.entries.isEmpty
                        ? 'Nothing here yet. Downloaded VODs and your watch history will appear in the Library.'
                        : 'No entries match the current search or filter.',
                    style: NeuTheme.subtextStyle(isDark, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  itemCount: visible.length,
                  itemBuilder: (context, index) =>
                      _LibraryRow(
                        key: ValueKey('lib_${visible[index].vodId}'),
                        entry: visible[index],
                        onPlay: widget.onPlay,
                        onOpenFolder: widget.onOpenFolder,
                        onDelete: widget.onDelete,
                        onRemoveFromHistory: widget.onRemoveFromHistory,
                      ),
                ),
        ),
      ],
    );
  }

  Widget _sortButton(ThemeData theme, LibrarySort sort, String label) {
    return NeuButton(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      borderRadius: BorderRadius.circular(8),
      isSelected: _sort == sort,
      onPressed: () => setState(() => _sort = sort),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }

  Widget _channelChip(ThemeData theme, String? channel, String label) {
    final isSelected = _channelFilter == channel;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: NeuButton(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        borderRadius: BorderRadius.circular(16),
        isSelected: isSelected,
        onPressed: () => setState(() => _channelFilter = channel),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      ),
    );
  }
}

class _LibraryRow extends StatefulWidget {
  const _LibraryRow({
    Key? key,
    required this.entry,
    required this.onPlay,
    required this.onOpenFolder,
    required this.onDelete,
    required this.onRemoveFromHistory,
  }) : super(key: key);

  final LibraryEntry entry;
  final void Function(LibraryEntry) onPlay;
  final void Function(LibraryEntry) onOpenFolder;
  final void Function(LibraryEntry) onDelete;
  final void Function(LibraryEntry) onRemoveFromHistory;

  @override
  State<_LibraryRow> createState() => _LibraryRowState();
}

class _LibraryRowState extends State<_LibraryRow> {
  bool _hovered = false;

  String _dateLabel(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = themeNotifier.isDarkTheme;
    final entry = widget.entry;
    final progress = entry.watchProgress;

    final thumbUrl = entry.video != null && entry.video!.thumbnailUrl.isNotEmpty
        ? entry.video!.thumbnailUrl
            .replaceAll('%{width}', '160')
            .replaceAll('%{height}', '90')
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: NeuTheme.raisedDecoration(
          isDark,
          radius: 10,
          border: _hovered
              ? Border.all(color: theme.primaryColor.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 72,
                height: 40,
                child: thumbUrl != null
                    ? Image.network(
                        thumbUrl,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stack) =>
                            _thumbFallback(isDark),
                      )
                    : _thumbFallback(isDark),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    style: NeuTheme.bodyStyle(isDark, fontSize: 13,
                        fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      entry.channel,
                      if (entry.sortDate != null) _dateLabel(entry.sortDate!),
                      if (entry.sizeBytes != null) formatBytes(entry.sizeBytes!),
                    ].join(' · '),
                    style: NeuTheme.subtextStyle(isDark, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (progress != null) ...[
              SizedBox(
                width: 90,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('${(progress * 100).round()}% watched',
                        style: NeuTheme.subtextStyle(isDark, fontSize: 10)),
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 3,
                        backgroundColor: NeuTheme.border(isDark),
                        valueColor:
                            AlwaysStoppedAnimation<Color>(theme.primaryColor),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
            ],
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: entry.isDownloaded
                    ? NeuTheme.live.withValues(alpha: 0.12)
                    : NeuTheme.subtext(isDark).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: entry.isDownloaded
                      ? NeuTheme.live.withValues(alpha: 0.4)
                      : NeuTheme.subtext(isDark).withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                entry.isDownloaded ? 'DOWNLOADED' : 'STREAMED',
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  color: entry.isDownloaded
                      ? NeuTheme.liveText(isDark)
                      : NeuTheme.subtext(isDark),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _actionButton(
              icon: Icons.play_arrow,
              tooltip:
                  entry.isDownloaded ? 'Play local file' : 'Stream from Twitch',
              color: theme.primaryColor,
              onPressed: () => widget.onPlay(entry),
            ),
            if (entry.isDownloaded) ...[
              const SizedBox(width: 6),
              _actionButton(
                icon: Icons.folder_open,
                tooltip: 'Show in Explorer',
                color: NeuTheme.text(isDark),
                onPressed: () => widget.onOpenFolder(entry),
              ),
              const SizedBox(width: 6),
              _actionButton(
                icon: Icons.delete_outline,
                tooltip: 'Delete download',
                color: NeuTheme.dangerText(isDark),
                onPressed: () => widget.onDelete(entry),
              ),
            ] else ...[
              const SizedBox(width: 6),
              _actionButton(
                icon: Icons.history_toggle_off,
                tooltip: 'Remove from watch history',
                color: NeuTheme.dangerText(isDark),
                onPressed: () => widget.onRemoveFromHistory(entry),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _thumbFallback(bool isDark) {
    return Container(
      color: NeuTheme.wellSurface(isDark),
      child: Icon(
        widget.entry.isDownloaded ? Icons.movie : Icons.history,
        size: 18,
        color: NeuTheme.subtext(isDark),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 30,
          height: 30,
          decoration:
              NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 8),
          child: Icon(icon, size: 15, color: color),
        ),
      ),
    );
  }
}
