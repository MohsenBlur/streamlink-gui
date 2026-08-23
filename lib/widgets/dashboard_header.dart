import 'package:flutter/material.dart';
import '../models/twitch_channel.dart';
import '../utils/time_utils.dart';
import 'hover_overlay_menu.dart';
import 'live_preview_popup.dart';
import 'interactive_popover.dart';
import 'neumorphic/neu_avatar_frame.dart';
import 'neumorphic/neu_container.dart';
import 'neumorphic/neu_card.dart';
import '../theme/neu_theme.dart';
import '../theme/theme_notifier.dart';

class DashboardHeader extends StatefulWidget {
  final TwitchChannel channel;
  final AnimationController pulseController;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final void Function(String) openExternalLink;
  final bool isPlaying;

  const DashboardHeader({
    Key? key,
    required this.channel,
    required this.pulseController,
    required this.onPlay,
    required this.onRefresh,
    required this.openExternalLink,
    required this.isPlaying,
  }) : super(key: key);

  @override
  State<DashboardHeader> createState() => _DashboardHeaderState();
}

class _DashboardHeaderState extends State<DashboardHeader> {

  /// Wraps [child] with the hover live-preview card when the channel is live.
  Widget _withLivePreview(Widget child) {
    if (!widget.channel.isLive) return child;
    return HoverOverlayMenu(
      estimatedMenuSize: LivePreviewPopup.estimatedSize,
      trigger: child,
      menu: LivePreviewPopup(channel: widget.channel),
    );
  }

  /// LIVE (pulsing) / OFFLINE status pill, shared by both header layouts.
  Widget _buildStatusBadge({required bool compact}) {
    final fontSize = compact ? 9.0 : 10.0;
    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 4);
    final radius = BorderRadius.circular(compact ? 10 : 12);
    final isDark = themeNotifier.isDarkTheme;

    if (!widget.channel.isLive) {
      final subtext = NeuTheme.subtext(isDark);
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: subtext.withValues(alpha: 0.12),
          border: Border.all(color: subtext, width: 1),
          borderRadius: radius,
        ),
        child: Text(
          'OFFLINE',
          style: TextStyle(
            color: subtext,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      );
    }

    return AnimatedBuilder(
      animation: widget.pulseController,
      builder: (context, child) {
        return Container(
          padding: padding,
          decoration: BoxDecoration(
            color: NeuTheme.live
                .withValues(alpha: 0.10 + 0.08 * widget.pulseController.value),
            border: Border.all(
              color: NeuTheme.live
                  .withValues(alpha: 0.4 + 0.6 * widget.pulseController.value),
              width: 1,
            ),
            borderRadius: radius,
          ),
          child: child,
        );
      },
      child: Text(
        'LIVE',
        style: TextStyle(
          color: NeuTheme.liveText(isDark),
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  /// The 3-state PLAY / OPEN / OFFLINE launch button (was three diverged
  /// copies with hardcoded whites that vanished on the light theme).
  Widget _buildPlayButton({required bool compact}) {
    final isDark = themeNotifier.isDarkTheme;
    final live = widget.channel.isLive;
    final playing = widget.isPlaying;
    final subtext = NeuTheme.subtext(isDark);

    final List<Widget> content;
    if (playing) {
      content = [
        SizedBox(
          width: compact ? 10 : 12,
          height: compact ? 10 : 12,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: subtext),
        ),
        SizedBox(width: compact ? 4 : 6),
        Text(
          'OPEN',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: compact ? 10 : 11,
            color: subtext,
          ),
        ),
      ];
    } else if (!live) {
      final disabled = NeuTheme.disabledText(isDark);
      content = [
        Icon(Icons.videocam_off, size: compact ? 12 : 14, color: disabled),
        const SizedBox(width: 4),
        Text(
          'OFFLINE',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: compact ? 10 : 11,
            color: disabled,
          ),
        ),
      ];
    } else {
      content = [
        Icon(Icons.play_arrow, size: compact ? 14 : 16),
        SizedBox(width: compact ? 2 : 4),
        Text(
          'PLAY',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: compact ? 11 : 12,
          ),
        ),
      ];
    }

    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: (live && !playing)
            ? Theme.of(context).primaryColor
            : NeuTheme.surface(isDark),
        disabledBackgroundColor: NeuTheme.surface(isDark),
        // Computed ink/white so PLAY stays readable on bright accents.
        foregroundColor:
            (live && !playing) ? themeNotifier.onPrimaryColor : subtext,
        padding: compact
            ? const EdgeInsets.symmetric(horizontal: 10)
            : EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        elevation: (live && !playing) ? (compact ? 2 : 4) : 0,
      ),
      onPressed: (playing || !live) ? null : widget.onPlay,
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: content,
      ),
    );
  }

  Widget _buildOverlayActionItem({required IconData icon, required String label, VoidCallback? onPressed}) {
    return SizedBox(
      width: double.infinity,
      height: 32,
      child: TextButton.icon(
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          foregroundColor: NeuTheme.text(themeNotifier.isDarkTheme),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 14, color: NeuTheme.text(themeNotifier.isDarkTheme)),
        label: Text(label, style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
      ),
    );
  }

  Widget _buildMiniActionBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool isLoading = false,
  }) {
    Widget iconWidget = Icon(icon, size: 14, color: NeuTheme.text(themeNotifier.isDarkTheme));
    if (isLoading) {
      iconWidget = AnimatedBuilder(
        animation: widget.pulseController,
        builder: (context, child) {
          return Transform.rotate(
            angle: widget.pulseController.value * 2 * 3.141592653589793,
            child: child,
          );
        },
        child: iconWidget,
      );
    }

    return Container(
      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 6),
      child: IconButton(
        icon: iconWidget,
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        splashRadius: 16,
      ),
    );
  }

  Widget _buildHeaderChip({required IconData icon, required Color color, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar({required double radius, double strokeWidth = 2.5}) {
    return NeuAvatarFrame(
      imageUrl: widget.channel.avatarUrl,
      size: radius * 2.2,
      isLive: widget.channel.isLive,
      fallbackText: widget.channel.username,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSmall = MediaQuery.of(context).size.width < 1180;
    final isCompact = MediaQuery.of(context).size.width < 700 || MediaQuery.of(context).size.height > MediaQuery.of(context).size.width;

    final statsChips = [
      if (widget.channel.isLive) ...[
        _buildHeaderChip(
          icon: Icons.visibility,
          color: NeuTheme.liveText(themeNotifier.isDarkTheme),
          label: '${widget.channel.viewerCount ?? "0"} viewers',
        ),
        _buildHeaderChip(
          icon: Icons.schedule,
          color: NeuTheme.warningText(themeNotifier.isDarkTheme),
          label: widget.channel.uptime ?? 'Live',
        ),
      ],
      _buildHeaderChip(
        icon: Icons.people,
        color: theme.primaryColor,
        label: '${widget.channel.followerCount ?? "N/A"} followers',
      ),
      _buildHeaderChip(
        icon: Icons.update,
        color: NeuTheme.subtext(themeNotifier.isDarkTheme),
        label: widget.channel.lastUpdated != null
            ? 'Updated: ${timeAgo(widget.channel.lastUpdated!)}'
            : 'Not updated',
      ),
    ];

    if (isCompact) {
      return NeuContainer(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        borderRadius: BorderRadius.circular(16),
        style: NeuStyle.raised,
        color: themeNotifier.surfaceColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _withLivePreview(_buildAvatar(radius: 18, strokeWidth: 2.0)),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.channel.username,
                          style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildStatusBadge(compact: true),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMiniActionBtn(
                      icon: Icons.open_in_new,
                      tooltip: 'Open Twitch channel',
                      onPressed: () => widget.openExternalLink('https://twitch.tv/${widget.channel.username}'),
                    ),
                    const SizedBox(width: 6),
                    _buildMiniActionBtn(
                      icon: Icons.chat_bubble_outline,
                      tooltip: 'Open Twitch chat popout',
                      onPressed: () => widget.openExternalLink('https://twitch.tv/${widget.channel.username}/chat'),
                    ),
                    const SizedBox(width: 6),
                    _buildMiniActionBtn(
                      icon: Icons.refresh,
                      tooltip: 'Refresh statistics',
                      isLoading: widget.channel.isLoading,
                      onPressed: widget.channel.isLoading ? null : widget.onRefresh,
                    ),
                    const SizedBox(width: 6),
                    InteractivePopover(
                      targetAnchor: Alignment.bottomRight,
                      followerAnchor: Alignment.topRight,
                      offset: const Offset(0, 6),
                      popover: Container(
                        width: 200,
                        padding: const EdgeInsets.all(10),
                        decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: statsChips.map((chip) => Padding(
                            padding: const EdgeInsets.only(bottom: 6.0),
                            child: chip,
                          )).toList(),
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.analytics_outlined, size: 12, color: theme.primaryColor),
                            const SizedBox(width: 4),
                            Text('Stats', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 10)),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(width: 6),
                    _withLivePreview(SizedBox(
                      height: 28,
                      child: _buildPlayButton(compact: true),
                    )),
                  ],
                ),
              ],
            ),
            if (widget.channel.isLive && widget.channel.streamTitle != null) ...[
              const SizedBox(height: 6),
              _withLivePreview(Text(
                '${widget.channel.streamTitle!} • ${widget.channel.game ?? "Unknown Game"}',
                style: TextStyle(fontSize: 12, color: NeuTheme.subtext(themeNotifier.isDarkTheme), fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )),
            ],
            if (widget.channel.errorMessage != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: NeuTheme.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: NeuTheme.danger.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 12, color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.channel.errorMessage!,
                        style: TextStyle(color: NeuTheme.dangerText(themeNotifier.isDarkTheme), fontSize: 10),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      );
    }

    final avatarContainer = _buildAvatar(radius: 36, strokeWidth: 2.5);

    final profileDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.channel.username,
                  style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 22),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(width: 10),
                _buildStatusBadge(compact: false),
              ],
            ),
            isSmall
                ? InteractivePopover(
                    targetAnchor: Alignment.bottomRight,
                    followerAnchor: Alignment.topRight,
                    offset: const Offset(0, 6),
                    popover: Container(
                      width: 160,
                      padding: const EdgeInsets.all(8),
                      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildOverlayActionItem(
                            icon: Icons.open_in_new,
                            label: 'Open Channel',
                            onPressed: () {
                              widget.openExternalLink('https://twitch.tv/${widget.channel.username}');
                            },
                          ),
                          const SizedBox(height: 4),
                          _buildOverlayActionItem(
                            icon: Icons.chat_bubble_outline,
                            label: 'Open Chat',
                            onPressed: () {
                              widget.openExternalLink('https://twitch.tv/${widget.channel.username}/chat');
                            },
                          ),
                          const SizedBox(height: 4),
                          _buildOverlayActionItem(
                            icon: Icons.refresh,
                            label: 'Refresh Stats',
                            onPressed: widget.channel.isLoading ? null : widget.onRefresh,
                          ),
                        ],
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.more_vert, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 16),
                          const SizedBox(width: 4),
                          Text('Actions', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 11)),
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
                        onPressed: () => widget.openExternalLink('https://twitch.tv/${widget.channel.username}'),
                      ),
                      const SizedBox(width: 8),
                      _buildMiniActionBtn(
                        icon: Icons.chat_bubble_outline,
                        tooltip: 'Open Twitch chat popout',
                        onPressed: () => widget.openExternalLink('https://twitch.tv/${widget.channel.username}/chat'),
                      ),
                      const SizedBox(width: 8),
                      _buildMiniActionBtn(
                        icon: Icons.refresh,
                        tooltip: 'Refresh statistics',
                        onPressed: widget.channel.isLoading ? null : widget.onRefresh,
                      ),
                    ],
                  ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.channel.isLive && widget.channel.streamTitle != null) ...[
          Text(
            widget.channel.streamTitle!,
            style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 14),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
        ],
        Text(
          widget.channel.isLive
              ? 'Streaming: ${widget.channel.game ?? "Unknown Game"}'
              : 'Channel is currently offline',
          style: TextStyle(
            fontSize: 13,
            color: widget.channel.isLive
                ? NeuTheme.text(themeNotifier.isDarkTheme)
                : NeuTheme.subtext(themeNotifier.isDarkTheme),
            fontWeight: widget.channel.isLive ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ],
    );

    final playButton = _buildPlayButton(compact: false);

    final cardWidget = GestureDetector(
      onTap: (widget.channel.isLive && !widget.isPlaying) ? widget.onPlay : null,
      child: MouseRegion(
        cursor: (widget.channel.isLive && !widget.isPlaying) ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: NeuCard(
          padding: const EdgeInsets.all(20),
          borderRadius: BorderRadius.circular(20),
          baseColor: themeNotifier.surfaceColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 90,
                    child: Center(
                      child: _withLivePreview(avatarContainer),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: _withLivePreview(profileDetails),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 90,
                    height: 32,
                    child: _withLivePreview(playButton),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: statsChips,
                    ),
                  ),
                ],
              ),
              if (widget.channel.errorMessage != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(width: 90),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: NeuTheme.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: NeuTheme.danger.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, size: 14, color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.channel.errorMessage!,
                                style: TextStyle(color: NeuTheme.dangerText(themeNotifier.isDarkTheme), fontSize: 11),
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
        ),
      ),
    );

    return cardWidget;
  }
}
