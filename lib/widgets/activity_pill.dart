import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../state/activity_state.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_progress.dart';
import 'neumorphic/neu_icon_action.dart';
import '../theme/theme_notifier.dart';
import 'interactive_popover.dart';

/// Ambient "something is happening" indicator for the title bar.
///
/// Replaces the permanent console drawer: it renders nothing at all when the
/// app is idle, and opens a popover listing every download and player with the
/// control to stop it.
///
/// Deliberately uses the ACCENT colour rather than the mint used by the
/// title bar's live-favourites badge — that mint means "live on Twitch", this
/// means "running on your machine", and two mint chips side by side with
/// different meanings would be its own small mess.
class ActivityPill extends StatelessWidget {
  const ActivityPill({
    Key? key,
    required this.activity,
    required this.onStop,
    this.compact = false,
  }) : super(key: key);

  final ValueListenable<ActivitySnapshot> activity;
  final void Function(ActivityItem) onStop;

  /// Narrow windows show only an icon and a count.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActivitySnapshot>(
      valueListenable: activity,
      builder: (context, snapshot, _) {
        if (snapshot.isIdle) return const SizedBox.shrink();
        return InteractivePopover(
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 6),
          popoverBuilder: (context, close) => ActivityPopover(
            snapshot: snapshot,
            onStop: (item) {
              // Close first: the popover installs a full-screen barrier that
              // would otherwise sit over the confirm dialog.
              close();
              onStop(item);
            },
          ),
          child: _pill(context, snapshot),
        );
      },
    );
  }

  String _summary(ActivitySnapshot s) {
    final parts = <String>[
      if (s.downloading.isNotEmpty) '${s.downloading.length} downloading',
      if (s.queued.isNotEmpty) '${s.queued.length} queued',
      if (s.playing.isNotEmpty) '${s.playing.length} playing',
    ];
    return parts.join(' · ');
  }

  /// The single-item case names the thing; multiples fall back to counts.
  String _label(ActivitySnapshot s) {
    if (s.total == 1) {
      final item = s.all.single;
      switch (item.kind) {
        case ActivityKind.downloading:
          final pct = item.progress == null
              ? null
              : '${(item.progress! * 100).round()}%';
          return pct == null ? item.label : '$pct · ${item.label}';
        case ActivityKind.queued:
          return '1 queued';
        case ActivityKind.liveStream:
        case ActivityKind.playingVod:
          return item.label;
      }
    }
    return _summary(s);
  }

  IconData _icon(ActivitySnapshot s) {
    if (s.downloading.isNotEmpty || s.queued.isNotEmpty) {
      return Icons.downloading;
    }
    return Icons.play_circle_outline;
  }

  Widget _pill(BuildContext context, ActivitySnapshot s) {
    final theme = Theme.of(context);
    final progress = s.meanDownloadProgress;

    return Tooltip(
      message: _summary(s),
      child: Container(
        constraints: BoxConstraints(maxWidth: compact ? 88 : 260),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.primaryColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: theme.primaryColor.withValues(alpha: 0.4), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_icon(s), size: 12, color: themeNotifier.accentInk),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    compact ? '${s.total}' : _label(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NeuType.micro(themeNotifier.isDarkTheme,
                        color: themeNotifier.accentInk),
                  ),
                ),
              ],
            ),
            if (!compact && progress != null) ...[
              const SizedBox(height: 3),
              NeuProgressBar(
                value: progress,
                size: NeuProgressSize.xs,
                width: 90,
                semanticLabel: 'Overall progress',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The panel behind the pill: everything running, each with a way to stop it.
class ActivityPopover extends StatelessWidget {
  const ActivityPopover({
    Key? key,
    required this.snapshot,
    required this.onStop,
  }) : super(key: key);

  final ActivitySnapshot snapshot;
  final void Function(ActivityItem) onStop;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    return Container(
      width: 340,
      constraints: const BoxConstraints(maxHeight: 420),
      padding: const EdgeInsets.all(12),
      decoration: NeuTheme.raisedDecoration(isDark, radius: 12),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot.downloading.isNotEmpty)
              ..._section(context, 'Downloading', snapshot.downloading, isDark),
            if (snapshot.queued.isNotEmpty)
              ..._section(context, 'Queued', snapshot.queued, isDark),
            if (snapshot.playing.isNotEmpty)
              ..._section(context, 'Playing', snapshot.playing, isDark),
          ],
        ),
      ),
    );
  }

  List<Widget> _section(BuildContext context, String title,
      List<ActivityItem> items, bool isDark) {
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 2),
        child: Text(
          title.toUpperCase(),
          style: NeuType.micro(isDark, color: NeuTheme.subtext(isDark)),
        ),
      ),
      for (final item in items) _row(context, item, isDark),
      const SizedBox(height: 10),
    ];
  }

  Widget _row(BuildContext context, ActivityItem item, bool isDark) {
    final isDownload = item.isDownload;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: NeuTheme.sunkenDecoration(isDark, radius: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NeuType.bodySm(isDark),
                ),
                if (item.kind == ActivityKind.downloading) ...[
                  const SizedBox(height: 5),
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
                        const SizedBox(width: 8),
                        Text(item.status!,
                            style: NeuType.caption(isDark)),
                      ],
                    ],
                  ),
                ] else if (item.status != null) ...[
                  const SizedBox(height: 2),
                  Text(item.status!,
                      style: NeuType.caption(isDark)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          NeuIconAction(
            icon: isDownload ? Icons.close : Icons.stop_rounded,
            tooltip: isDownload ? 'Cancel download' : 'Stop playback',
            onPressed: () => onStop(item),
            size: NeuActionSize.sm,
            tone: NeuActionTone.danger,
          ),
        ],
      ),
    );
  }
}
