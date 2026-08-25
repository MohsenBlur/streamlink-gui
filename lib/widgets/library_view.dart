import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../state/activity_state.dart';

import '../state/library_entries.dart';
import '../theme/neu_theme.dart';
import 'horizontal_mouse_scrollable.dart';
import 'neumorphic/neu_progress.dart';
import 'neumorphic/neu_badge.dart';
import 'neumorphic/neu_icon_action.dart';
import 'shell/section_header.dart';
import 'shell/empty_state.dart';
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
    this.activity,
    this.onStopActivity,
    this.onBack,
    this.backLabel,
  }) : super(key: key);

  final List<LibraryEntry> entries;
  final VoidCallback onRefresh;
  final void Function(LibraryEntry) onPlay;
  final void Function(LibraryEntry) onOpenFolder;
  final void Function(LibraryEntry) onDelete;
  final void Function(LibraryEntry) onRemoveFromHistory;

  /// In-flight downloads, rendered as a pinned section above the cached rows.
  ///
  /// Deliberately separate from [entries]: those are built from disk state and
  /// rebuilt with a stat pass, which must not happen on every progress tick.
  /// Nullable so existing call sites and tests keep working.
  final ValueListenable<ActivitySnapshot>? activity;
  final void Function(ActivityItem)? onStopActivity;

  /// Leaves the Library and returns to whatever was showing before it.
  ///
  /// Until this existed the Library was a dead end: nothing in this file was a
  /// back control, and the flag that shows it was cleared only by picking a
  /// channel or clicking the sidebar's app title - so the way out was to go
  /// somewhere else entirely.
  final VoidCallback? onBack;

  /// What [onBack] returns to, e.g. 'Home' or a channel name. Shown on the
  /// control so it is a destination rather than a bare arrow.
  final String? backLabel;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final TextEditingController _search = TextEditingController();
  String? _channelFilter;

  /// Separate from [_channelFilter] because "no channel" is not a channel
  /// name. It used to be one - entries fell back to the literal 'VOD' or
  /// 'Streamed', which then appeared as chips alongside real channels.
  bool _unknownOnly = false;
  LibrarySort _sort = LibrarySort.newest;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _isFiltered =>
      _search.text.isNotEmpty || _channelFilter != null || _unknownOnly;

  void _clearFilters() => setState(() {
        _search.clear();
        _channelFilter = null;
        _unknownOnly = false;
      });

  List<LibraryEntry> get _visible {
    var list = filterLibraryEntries(widget.entries, _search.text);
    if (_unknownOnly) {
      list = list.where((e) => e.channel == null).toList();
    } else if (_channelFilter != null) {
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
    final visible = _visible;
    // The stats describe what is ON SCREEN. They used to describe the whole
    // library regardless of the filter, so narrowing to one channel left the
    // header claiming 152 GB over a list showing 4 GB.
    final downloaded = visible.where((e) => e.isDownloaded).toList();
    final totalBytes =
        downloaded.fold<int>(0, (sum, e) => sum + (e.sizeBytes ?? 0));
    final channels = widget.entries
        .map((e) => e.channel)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final hasUnknown = widget.entries.any((e) => e.channel == null);

    // Capped and centred. Below 1280 this changes nothing; above it, rows stop
    // stretching to the window's full width, which was leaving 400px of dead
    // space between a title and its own buttons at 1400 and much worse at
    // 2560. Nothing here benefits from being wider than a page of text.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: _body(context, theme, isDark, visible, downloaded, totalBytes,
            channels, hasUnknown),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ThemeData theme,
    bool isDark,
    List<LibraryEntry> visible,
    List<LibraryEntry> downloaded,
    int totalBytes,
    List<String> channels,
    bool hasUnknown,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(NeuSpace.s24, NeuSpace.s20, NeuSpace.s24, 0),
          // A Wrap is no good here: it hands children unbounded width, so a
          // mainAxisSize.min Row inside one reports its intrinsic size and
          // overflows anyway (which is exactly what happened - 248px and 24px
          // over at the 380px minimum). Decide explicitly instead.
          child: LayoutBuilder(builder: (context, constraints) {
            // Measured, not guessed: the leading group needs ~470px with a
            // back label and the stats chip, the sort cluster ~270, plus the
            // gap. Below that the header takes two lines.
            final tight = constraints.maxWidth < 820;

            final leading = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onBack != null) ...[
                  NeuButton(
                    padding: EdgeInsets.symmetric(
                        horizontal: tight ? NeuSpace.s8 : NeuSpace.s12,
                        vertical: NeuSpace.s8),
                    borderRadius: BorderRadius.circular(NeuRadius.r8),
                    tooltip: 'Back to ${widget.backLabel ?? 'where you were'} (Esc)',
                    onPressed: widget.onBack,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_back,
                            size: 15, color: NeuTheme.text(isDark)),
                        // The label is the point of the control - it names the
                        // destination - so it is the last thing dropped.
                        if (widget.backLabel != null && !tight) ...[
                          const SizedBox(width: NeuSpace.s6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 140),
                            child: Text(
                              widget.backLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: NeuType.bodySm(isDark),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: NeuSpace.s12),
                ],
                Icon(Icons.video_library,
                    color: themeNotifier.accentInk, size: 22),
                const SizedBox(width: NeuSpace.s8),
                Text('Library', style: NeuType.headingLg(isDark)),
                // The count/size chip is the first thing to go: it is
                // information, not a control.
                if (!tight) ...[
                  const SizedBox(width: NeuSpace.s12),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: NeuSpace.s12, vertical: NeuSpace.s6),
                      decoration:
                          NeuTheme.sunkenDecoration(isDark, radius: NeuRadius.r8),
                      child: Text(
                        [
                          if (_isFiltered)
                            '${visible.length} of ${widget.entries.length}'
                          else
                            '${visible.length} item${visible.length == 1 ? '' : 's'}',
                          if (downloaded.isNotEmpty)
                            '${formatBytes(totalBytes)} on disk',
                        ].join(' \u00B7 '),
                        style: NeuType.caption(isDark),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ],
            );

            final trailing = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sortButton(LibrarySort.newest, 'Newest'),
                const SizedBox(width: NeuSpace.s6),
                _sortButton(LibrarySort.largest, 'Largest'),
                const SizedBox(width: NeuSpace.s6),
                _sortButton(LibrarySort.progress, 'Progress'),
                const SizedBox(width: NeuSpace.s12),
                NeuButton(
                  padding: const EdgeInsets.all(NeuSpace.s8),
                  borderRadius: BorderRadius.circular(NeuRadius.r8),
                  tooltip: 'Rescan the download folder',
                  onPressed: widget.onRefresh,
                  child: Icon(Icons.refresh,
                      size: 16, color: NeuTheme.text(isDark)),
                ),
              ],
            );

            if (!tight) {
              return Row(
                children: [
                  Flexible(child: leading),
                  const SizedBox(width: NeuSpace.s12),
                  trailing,
                ],
              );
            }

            // Two lines, with the controls scrollable so no combination of
            // sort labels can overflow regardless of how narrow it gets.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading,
                const SizedBox(height: NeuSpace.s8),
                HorizontalMouseScrollable(child: trailing),
              ],
            );
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(NeuSpace.s24, NeuSpace.s12, NeuSpace.s24, 0),
          child: Row(
            children: [
              // A hard 280 plus a 12 gap needs 292px of the 332 available at
              // the 380px minimum window, leaving the channel chips nothing
              // and overflowing the row. Cap it instead of fixing it.
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: NeuTextField(
                    controller: _search,
                    hintText: 'Search library...',
                    prefixIcon: Icons.search,
                    size: NeuFieldSize.md,
                    onChanged: (_) => setState(() {}),
                    onClear: () => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: NeuSpace.s12),
              Expanded(
                child: SizedBox(
                  // Chip height plus the scroller's shadow clearance - the
                  // one definition, not hand numbers (the first fix cut the
                  // halo above while fixing the cast below).
                  height: 28 + NeuShadowRoom.above + NeuShadowRoom.below,
                  child: HorizontalMouseScrollable(
                    child: Row(children: [
                      _channelChip(null, 'All'),
                      for (final ch in channels) _channelChip(ch, ch),
                      // Only offered when there is something behind it, and
                      // named for what it is rather than pretending to be a
                      // channel called 'Streamed'.
                      if (hasUnknown) _unknownChip(),
                    ]),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.activity != null)
          ValueListenableBuilder<ActivitySnapshot>(
            valueListenable: widget.activity!,
            builder: (context, snapshot, _) {
              final live = [...snapshot.downloading, ...snapshot.queued];
              if (live.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(NeuSpace.s24, NeuSpace.s12, NeuSpace.s24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeader(
                      title: 'In progress',
                      density: SectionDensity.inline,
                    ),
                    const SizedBox(height: NeuSpace.s6),
                    for (final item in live) _liveRow(item, theme, isDark),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: NeuSpace.s12),
        Expanded(
          child: visible.isEmpty
              ? (widget.entries.isEmpty
                  ? EmptyState(
                      icon: Icons.video_library_outlined,
                      title: 'Nothing here yet',
                      message: 'VODs you download and broadcasts you watch will '
                          'appear here.',
                    )
                  : EmptyState(
                      icon: Icons.search_off,
                      title: 'No matches',
                      message: 'Nothing in the Library matches the current '
                          'search or filter.',
                      action: NeuButton(
                        onPressed: _clearFilters,
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                        borderRadius: BorderRadius.circular(NeuRadius.r8),
                        child: const Text('Clear filters',
                            style: NeuType.bodySmMetrics),
                      ),
                    ))
              : ListView.builder(
                  // Shadow room from the shared definition; the hand-tuned
                  // s8 top covered Rack's halo and cut Soft's diagonal glow.
                  padding: const EdgeInsets.fromLTRB(NeuSpace.s24,
                      NeuShadowRoom.above, NeuSpace.s24, NeuShadowRoom.below),
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

  /// A download that is running or queued. Intentionally NOT passed through
  /// the search/sort/channel filters - an active download must never be hidden
  /// by a filter the user forgot they set.
  Widget _liveRow(ActivityItem item, ThemeData theme, bool isDark) {
    final queued = item.kind == ActivityKind.queued;
    return Container(
      margin: const EdgeInsets.only(bottom: NeuSpace.s6),
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
      decoration: NeuTheme.raisedDecoration(
        isDark,
        radius: NeuRadius.r12,
        border: Border.all(color: theme.primaryColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(queued ? Icons.schedule : Icons.downloading,
              size: 16, color: themeNotifier.accentInk),
          const SizedBox(width: NeuSpace.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NeuType.bodyStrong(isDark)),
                const SizedBox(height: NeuSpace.s4),
                if (queued)
                  Text('Waiting to start',
                      style: NeuType.caption(isDark))
                else
                  Row(
                    children: [
                      Expanded(
                        child: NeuProgressBar(
                          value: item.progress,
                          size: NeuProgressSize.sm,
                          semanticLabel: item.label,
                        ),
                      ),
                      if (item.status != null) ...[
                        const SizedBox(width: NeuSpace.s8),
                        Text(item.status!,
                            style:
                                NeuType.caption(isDark)),
                      ],
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: NeuSpace.s12),
          StatusBadge(
            label: queued ? 'Queued' : 'Downloading',
            tone: BadgeTone.accent,
          ),
          if (widget.onStopActivity != null) ...[
            const SizedBox(width: NeuSpace.s8),
            // The same action the activity popover renders - and now the
            // same control, instead of a hand-rolled 30px InkWell beside the
            // popover's 40px NeuIconAction.
            NeuIconAction(
              icon: Icons.close,
              tooltip: 'Cancel download',
              tone: NeuActionTone.danger,
              size: NeuActionSize.sm,
              onPressed: () => widget.onStopActivity!(item),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sortButton(LibrarySort sort, String label) {
    return NeuButton(
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      isSelected: _sort == sort,
      onPressed: () => setState(() => _sort = sort),
      child: Text(label, style: NeuType.captionMetrics),
    );
  }

  Widget _channelChip(String? channel, String label) {
    final isSelected = !_unknownOnly && _channelFilter == channel;
    return Padding(
      padding: const EdgeInsets.only(right: NeuSpace.s6),
      child: NeuButton(
        padding: const EdgeInsets.symmetric(
            horizontal: NeuSpace.s12, vertical: NeuSpace.s6),
        borderRadius: BorderRadius.circular(NeuRadius.pill),
        isSelected: isSelected,
        onPressed: () => setState(() {
          _channelFilter = channel;
          _unknownOnly = false;
        }),
        child: Text(label, style: NeuType.captionMetrics),
      ),
    );
  }

  Widget _unknownChip() {
    return Padding(
      padding: const EdgeInsets.only(right: NeuSpace.s6),
      child: NeuButton(
        padding: const EdgeInsets.symmetric(
            horizontal: NeuSpace.s12, vertical: NeuSpace.s6),
        borderRadius: BorderRadius.circular(NeuRadius.pill),
        isSelected: _unknownOnly,
        tooltip: 'Watched or downloaded without a channel on record',
        onPressed: () => setState(() {
          _unknownOnly = !_unknownOnly;
          _channelFilter = null;
        }),
        child: const Text('No channel', style: NeuType.captionMetrics),
      ),
    );
  }
}

/// Laid-out width of a [NeuIconAction] - its face is 28px at [NeuActionSize.sm]
/// but the hit target is always 40, and it is the hit target that takes space.
const double _actionSlot = 40;

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
    final isDark = themeNotifier.isDarkTheme;
    final entry = widget.entry;
    final progress = entry.watchProgress;

    final thumbUrl = entry.video != null && entry.video!.thumbnailUrl.isNotEmpty
        ? entry.video!.thumbnailUrl
            .replaceAll('%{width}', '160')
            .replaceAll('%{height}', '90')
        : null;

    final sizeLabel =
        entry.sizeBytes != null ? formatBytes(entry.sizeBytes!) : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        // 12, not 8: the watched bar runs along this row's bottom edge, so an
        // 8px gap put it exactly as far from its own content as from the next
        // row and it read as a divider between the two.
        margin: const EdgeInsets.only(bottom: NeuSpace.s12),
        // List rows raise on hover; they do not ring. The ring is the CARD
        // grammar - two grammars in one window made near-identical surfaces
        // light up differently.
        decoration: NeuTheme.raised(
          isDark,
          radius: NeuRadius.r12,
          depth: _hovered ? NeuElevation.d3 : NeuElevation.d2,
        ),
        // clipBehavior so the watched bar can reach the row's rounded corners
        // instead of floating in a 90px column of its own mid-row.
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Measured against the ROW's width, not the window's: the same row
            // is 1232px wide on the capped desktop list and 309 at the app's
            // 380px minimum. At 309 the thumbnail, the size column and three
            // 40px buttons wanted 316 between them, so the title's Expanded
            // collapsed to zero and every row rendered as artwork, a file size
            // and some buttons, with no title at all.
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              final showThumb = width >= 460;
              final showSizeColumn = width >= 560;
              final showFolder = width >= 400;

              return Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                child: Row(
                  children: [
                    if (showThumb) ...[
                      ClipRRect(
                        // Concentric with the row: inner = outer - inset, and
                        // the governing inset is the row's s8 vertical
                        // padding. At inner(r12, s4) = 8 the thumbnail's arc
                        // was not parallel with the row's - corners read
                        // subtly wrong on every downloaded row.
                        borderRadius: BorderRadius.circular(
                            NeuRadius.inner(NeuRadius.r12, NeuSpace.s8)),
                        // 16:9. The old 72x40 was 1.8:1, so every real
                        // thumbnail was cropped top and bottom.
                        child: SizedBox(
                          width: 96,
                          height: 54,
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
                      const SizedBox(width: NeuSpace.s12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            entry.title,
                            style: NeuType.bodyStrong(isDark),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: NeuSpace.s4),
                          Row(
                            children: [
                              // Replaces a "DOWNLOADED" badge that sat on nine
                              // rows out of eleven. A badge carried by almost
                              // everything says nothing, and it claimed a
                              // column to say it.
                              Icon(
                                entry.isDownloaded
                                    ? Icons.save_alt
                                    : Icons.history,
                                size: 12,
                                color: entry.isDownloaded
                                    ? NeuTheme.liveText(isDark)
                                    : NeuTheme.subtext(isDark),
                              ),
                              const SizedBox(width: NeuSpace.s6),
                              Expanded(
                                child: Text(
                                  [
                                    entry.channel ?? 'No channel',
                                    if (entry.sortDate != null)
                                      _dateLabel(entry.sortDate!),
                                    // Folded back into the line when there is
                                    // no room for a column of its own.
                                    if (!showSizeColumn && sizeLabel != null)
                                      sizeLabel,
                                    if (progress != null)
                                      '${(progress * 100).round()}% watched',
                                  ].join(' \u00B7 '),
                                  style: NeuType.caption(isDark),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // A fixed column, not merely right-aligned text: sizes
                    // scan as a column only if 9.7 GB and 20.1 GB start at the
                    // same x. Reserved even when empty so the buttons do not
                    // shift between downloaded and streamed rows.
                    if (showSizeColumn) ...[
                      const SizedBox(width: NeuSpace.s12),
                      SizedBox(
                        width: 64,
                        child: Text(
                          sizeLabel ?? '',
                          textAlign: TextAlign.right,
                          // The treatment this comment described by hand,
                          // now the named one. Same size, same weight, same
                          // face - only the figures change width.
                          style: NeuType.readout(NeuType.caption(isDark)),
                        ),
                      ),
                    ],
                    const SizedBox(width: NeuSpace.s12),
                    _actionButton(
                      icon: Icons.play_arrow,
                      tooltip: entry.isDownloaded
                          ? 'Play local file'
                          : 'Stream from Twitch',
                      tone: NeuActionTone.accent,
                      onPressed: () => widget.onPlay(entry),
                    ),
                    if (entry.isDownloaded) ...[
                      if (showFolder) ...[
                        const SizedBox(width: NeuSpace.s6),
                        _actionButton(
                          icon: Icons.folder_open,
                          tooltip: 'Show in Explorer',
                          tone: NeuActionTone.neutral,
                          onPressed: () => widget.onOpenFolder(entry),
                        ),
                      ],
                      const SizedBox(width: NeuSpace.s6),
                      _actionButton(
                        icon: Icons.delete_outline,
                        tooltip: 'Delete download',
                        tone: NeuActionTone.danger,
                        onPressed: () => widget.onDelete(entry),
                      ),
                    ] else ...[
                      // Streamed rows have no folder to open, but the slot is
                      // held anyway so Play and the destructive action stay in
                      // the same two columns down the whole list instead of
                      // sliding 46px right on every streamed row.
                      if (showFolder)
                        const SizedBox(width: NeuSpace.s6 + _actionSlot),
                      const SizedBox(width: NeuSpace.s6),
                      _actionButton(
                        icon: Icons.history_toggle_off,
                        tooltip: 'Remove from watch history',
                        tone: NeuActionTone.danger,
                        onPressed: () => widget.onRemoveFromHistory(entry),
                      ),
                    ],
                  ],
                ),
              );
            }),
            if (progress != null)
              // Along the row's own bottom edge, the way the VOD cards do it.
              SizedBox(
                height: 3,
                child: NeuProgressBar(
                  value: progress.clamp(0.0, 1.0),
                  size: NeuProgressSize.sm,
                  semanticLabel: 'Watched',
                ),
              ),
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
    required NeuActionTone tone,
    required VoidCallback onPressed,
  }) {
    return NeuIconAction(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      size: NeuActionSize.sm,
      tone: tone,
    );
  }
}
