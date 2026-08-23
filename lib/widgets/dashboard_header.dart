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
import 'shell/app_layout.dart';
import 'shell/motion.dart';
import 'neumorphic/neu_progress.dart';
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
    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4)
        : const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4);
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
          style: NeuType.micro(isDark, color: subtext),
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
        style: NeuType.micro(isDark, color: NeuTheme.liveText(isDark)),
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
          child: NeuProgressRing(size: NeuProgressRingSize.xs, color: subtext, semanticLabel: 'Refreshing'),
        ),
        SizedBox(width: compact ? 4 : 6),
        Text(
          'OPEN',
          style: NeuType.micro(isDark, color: subtext),
        ),
      ];
    } else if (!live) {
      final disabled = NeuTheme.disabledText(isDark);
      content = [
        Icon(Icons.videocam_off, size: compact ? 12 : 14, color: disabled),
        const SizedBox(width: NeuSpace.s4),
        Text(
          'OFFLINE',
          style: NeuType.micro(isDark, color: disabled),
        ),
      ];
    } else {
      content = [
        Icon(Icons.play_arrow, size: compact ? 14 : 16),
        SizedBox(width: compact ? 2 : 4),
        Text(
          'PLAY',
          // No ink: ElevatedButton supplies the foreground, including its
          // disabled and hover states.
          style: NeuType.microMetrics,
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
            ? const EdgeInsets.symmetric(horizontal: NeuSpace.s8)
            : EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r6)),
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
          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r4)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 14, color: NeuTheme.text(themeNotifier.isDarkTheme)),
        label: Text(label, style: NeuType.bodySm(themeNotifier.isDarkTheme)),
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
      // Its own forward-only controller. It used to read the shared pulse,
      // which runs `repeat(reverse: true)` - so the refresh icon spun forwards
      // for a second and then spun BACKWARDS for a second, forever.
      iconWidget = _SpinningIcon(child: iconWidget);
    }

    return Container(
      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r6),
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
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s6),
      decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: NeuSpace.s6),
          Text(
            label,
            style: NeuType.caption(themeNotifier.isDarkTheme),
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
    // Was a byte-identical copy of the two lines in main.dart's dashboard
    // build, with nothing keeping them in step.
    final layout = AppLayout.maybeOf(context);
    final isSmall = !layout.hasWideControls;
    final isCompact = layout.isRail;

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
        padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
        borderRadius: BorderRadius.circular(NeuRadius.r16),
        style: NeuStyle.raised,
        color: themeNotifier.surfaceColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _withLivePreview(_buildAvatar(radius: 18, strokeWidth: 2.0)),
                const SizedBox(width: NeuSpace.s8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.channel.username,
                          style: NeuType.headingMd(themeNotifier.isDarkTheme),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: NeuSpace.s8),
                      _buildStatusBadge(compact: true),
                    ],
                  ),
                ),
                const SizedBox(width: NeuSpace.s8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMiniActionBtn(
                      icon: Icons.open_in_new,
                      tooltip: 'Open Twitch channel',
                      onPressed: () => widget.openExternalLink('https://twitch.tv/${widget.channel.username}'),
                    ),
                    const SizedBox(width: NeuSpace.s6),
                    _buildMiniActionBtn(
                      icon: Icons.chat_bubble_outline,
                      tooltip: 'Open Twitch chat popout',
                      onPressed: () => widget.openExternalLink('https://twitch.tv/${widget.channel.username}/chat'),
                    ),
                    const SizedBox(width: NeuSpace.s6),
                    _buildMiniActionBtn(
                      icon: Icons.refresh,
                      tooltip: 'Refresh statistics',
                      isLoading: widget.channel.isLoading,
                      onPressed: widget.channel.isLoading ? null : widget.onRefresh,
                    ),
                    const SizedBox(width: NeuSpace.s6),
                    InteractivePopover(
                      targetAnchor: Alignment.bottomRight,
                      followerAnchor: Alignment.topRight,
                      offset: const Offset(0, 6),
                      popover: Container(
                        width: 200,
                        padding: const EdgeInsets.all(NeuSpace.s8),
                        decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: statsChips.map((chip) => Padding(
                            padding: const EdgeInsets.only(bottom: NeuSpace.s6),
                            child: chip,
                          )).toList(),
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4),
                        decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.analytics_outlined, size: 12, color: themeNotifier.accentInk),
                            const SizedBox(width: NeuSpace.s4),
                            Text('Stats', style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme))),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(width: NeuSpace.s6),
                    _withLivePreview(SizedBox(
                      height: 28,
                      child: _buildPlayButton(compact: true),
                    )),
                  ],
                ),
              ],
            ),
            if (widget.channel.isLive && widget.channel.streamTitle != null) ...[
              const SizedBox(height: NeuSpace.s6),
              _withLivePreview(Text(
                '${widget.channel.streamTitle!} • ${widget.channel.game ?? "Unknown Game"}',
                style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )),
            ],
            if (widget.channel.errorMessage != null) ...[
              const SizedBox(height: NeuSpace.s6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4),
                decoration: BoxDecoration(
                  color: NeuTheme.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(NeuRadius.r6),
                  border: Border.all(color: NeuTheme.danger.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 12, color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                    const SizedBox(width: NeuSpace.s6),
                    Expanded(
                      child: Text(
                        widget.channel.errorMessage!,
                        style: NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
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
            // Flexible for the same reason the compact branch above already
            // had it: at 22px a long username in an unbounded Row reports its
            // full intrinsic width, so the ellipsis never engages and the Row
            // overflows instead. The two branches disagreed about this.
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.channel.username,
                      style: NeuType.display(themeNotifier.isDarkTheme),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: NeuSpace.s8),
                  _buildStatusBadge(compact: false),
                ],
              ),
            ),
            isSmall
                ? InteractivePopover(
                    targetAnchor: Alignment.bottomRight,
                    followerAnchor: Alignment.topRight,
                    offset: const Offset(0, 6),
                    popover: Container(
                      width: 160,
                      padding: const EdgeInsets.all(NeuSpace.s8),
                      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r8),
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
                          const SizedBox(height: NeuSpace.s4),
                          _buildOverlayActionItem(
                            icon: Icons.chat_bubble_outline,
                            label: 'Open Chat',
                            onPressed: () {
                              widget.openExternalLink('https://twitch.tv/${widget.channel.username}/chat');
                            },
                          ),
                          const SizedBox(height: NeuSpace.s4),
                          _buildOverlayActionItem(
                            icon: Icons.refresh,
                            label: 'Refresh Stats',
                            onPressed: widget.channel.isLoading ? null : widget.onRefresh,
                          ),
                        ],
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s6),
                      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.more_vert, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 16),
                          const SizedBox(width: NeuSpace.s4),
                          Text('Actions', style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme))),
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
                      const SizedBox(width: NeuSpace.s8),
                      _buildMiniActionBtn(
                        icon: Icons.chat_bubble_outline,
                        tooltip: 'Open Twitch chat popout',
                        onPressed: () => widget.openExternalLink('https://twitch.tv/${widget.channel.username}/chat'),
                      ),
                      const SizedBox(width: NeuSpace.s8),
                      _buildMiniActionBtn(
                        icon: Icons.refresh,
                        tooltip: 'Refresh statistics',
                        onPressed: widget.channel.isLoading ? null : widget.onRefresh,
                      ),
                    ],
                  ),
          ],
        ),
        const SizedBox(height: NeuSpace.s8),
        if (widget.channel.isLive && widget.channel.streamTitle != null) ...[
          Text(
            widget.channel.streamTitle!,
            style: NeuType.headingSm(themeNotifier.isDarkTheme),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: NeuSpace.s6),
        ],
        Text(
          widget.channel.isLive
              ? 'Streaming: ${widget.channel.game ?? "Unknown Game"}'
              : 'Channel is currently offline',
          // Both branches were w500 and normal, which Segoe renders
          // identically - the distinction was colour all along.
          style: NeuType.body(
            themeNotifier.isDarkTheme,
            color: widget.channel.isLive
                ? NeuTheme.text(themeNotifier.isDarkTheme)
                : NeuTheme.subtext(themeNotifier.isDarkTheme),
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
          padding: const EdgeInsets.all(NeuSpace.s20),
          borderRadius: BorderRadius.circular(NeuRadius.r20),
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
                  const SizedBox(width: NeuSpace.s20),
                  Expanded(
                    child: _withLivePreview(profileDetails),
                  ),
                ],
              ),
              const SizedBox(height: NeuSpace.s12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 90,
                    height: 32,
                    child: _withLivePreview(playButton),
                  ),
                  const SizedBox(width: NeuSpace.s20),
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
                const SizedBox(height: NeuSpace.s12),
                Row(
                  children: [
                    // Intentional: 90px reserves the width of the action cluster so the
                    // two header layouts keep their titles on the same x.
                    const SizedBox(width: 90),
                    const SizedBox(width: NeuSpace.s20),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                        decoration: BoxDecoration(
                          color: NeuTheme.danger.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(NeuRadius.r6),
                          border: Border.all(color: NeuTheme.danger.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline, size: 14, color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                            const SizedBox(width: NeuSpace.s8),
                            Expanded(
                              child: Text(
                                widget.channel.errorMessage!,
                                style: NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
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

/// A forward-only rotation, for "working" indicators.
class _SpinningIcon extends StatefulWidget {
  const _SpinningIcon({required this.child});
  final Widget child;

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // NOT initState: reading MediaQuery there throws, and in a RELEASE build a
    // thrown exception during build renders as a blank grey rectangle rather
    // than the red error box - so this failed silently and looked like a
    // crash. Exactly the same mistake as the LED indicator, made twice.
    if (NeuMotion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (NeuMotion.reduced(context)) return widget.child;
    return RotationTransition(turns: _controller, child: widget.child);
  }
}
