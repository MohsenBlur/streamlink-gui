import 'package:flutter/material.dart';
import '../models/twitch_channel.dart';
import 'hover_overlay_menu.dart';
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

  Widget _buildLivePreviewPopup(TwitchChannel channel) {
    final cleanName = channel.username.toLowerCase().trim();
    final cacheBuster = DateTime.now().millisecondsSinceEpoch ~/ 10000;
    final thumbUrl = 'https://static-cdn.jtvnw.net/previews-ttv/live_user_$cleanName-320x180.jpg?t=$cacheBuster';
    
    return Container(
      width: 260,
      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                thumbUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: NeuTheme.surface(themeNotifier.isDarkTheme),
                    child: Center(
                      child: Icon(Icons.live_tv, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 36),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        channel.username,
                        style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (channel.viewerCount != null && channel.viewerCount != '0') ...[
                      Icon(Icons.remove_red_eye, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 12),
                      const SizedBox(width: 4),
                      Text(
                        channel.viewerCount!,
                        style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  channel.streamTitle ?? 'Streaming Live!',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                ),
                if (channel.game != null && channel.game != 'Offline') ...[
                  const SizedBox(height: 6),
                  Text(
                    channel.game!,
                    style: const TextStyle(
                      color: Color(0xFF9146FF),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
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
          color: Colors.redAccent,
          label: '${widget.channel.viewerCount ?? "0"} viewers',
        ),
        _buildHeaderChip(
          icon: Icons.schedule,
          color: Colors.orangeAccent,
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
            ? 'Updated: ${_timeAgo(widget.channel.lastUpdated!)}'
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
                widget.channel.isLive
                    ? HoverOverlayMenu(
                        trigger: _buildAvatar(radius: 18, strokeWidth: 2.0),
                        menu: _buildLivePreviewPopup(widget.channel),
                      )
                    : _buildAvatar(radius: 18, strokeWidth: 2.0),
                const SizedBox(width: 10),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.channel.username,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (widget.channel.isLive)
                        AnimatedBuilder(
                          animation: widget.pulseController,
                          builder: (context, child) {
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.15 + 0.1 * widget.pulseController.value),
                                border: Border.all(
                                  color: Colors.redAccent.withOpacity(0.4 + 0.6 * widget.pulseController.value),
                                  width: 1,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text(
                                'LIVE',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            );
                          },
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.grey.withOpacity(0.15),
                            border: Border.all(
                              color: Colors.grey,
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'OFFLINE',
                            style: TextStyle(
                              color: Colors.grey,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
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
                    widget.channel.isLive
                        ? HoverOverlayMenu(
                            trigger: SizedBox(
                              height: 28,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.isPlaying
                                      ? NeuTheme.surface(themeNotifier.isDarkTheme)
                                      : (widget.channel.isLive ? theme.primaryColor : NeuTheme.surface(themeNotifier.isDarkTheme)),
                                  foregroundColor: widget.channel.isLive && !widget.isPlaying
                                      ? Colors.white
                                      : NeuTheme.subtext(themeNotifier.isDarkTheme),
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                  elevation: (widget.channel.isLive && !widget.isPlaying) ? 2 : 0,
                                ),
                                onPressed: (widget.isPlaying || !widget.channel.isLive) ? null : widget.onPlay,
                                child: widget.isPlaying
                                    ? const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 10,
                                            height: 10,
                                            child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white60),
                                          ),
                                          SizedBox(width: 4),
                                          Text('OPEN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white54)),
                                        ],
                                      )
                                    : (!widget.channel.isLive
                                        ? const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.videocam_off, size: 12, color: Colors.white30),
                                              SizedBox(width: 4),
                                              Text('OFFLINE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white30)),
                                            ],
                                          )
                                        : const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.play_arrow, size: 14),
                                              SizedBox(width: 2),
                                              Text('PLAY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                            ],
                                          )),
                              ),
                            ),
                            menu: _buildLivePreviewPopup(widget.channel),
                          )
                        : SizedBox(
                            height: 28,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: widget.isPlaying
                                    ? NeuTheme.surface(themeNotifier.isDarkTheme)
                                    : (widget.channel.isLive ? theme.primaryColor : NeuTheme.surface(themeNotifier.isDarkTheme)),
                                foregroundColor: widget.channel.isLive && !widget.isPlaying
                                    ? Colors.white
                                    : NeuTheme.subtext(themeNotifier.isDarkTheme),
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                elevation: (widget.channel.isLive && !widget.isPlaying) ? 2 : 0,
                              ),
                              onPressed: (widget.isPlaying || !widget.channel.isLive) ? null : widget.onPlay,
                              child: widget.isPlaying
                                  ? const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: 10,
                                          height: 10,
                                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white60),
                                        ),
                                        SizedBox(width: 4),
                                        Text('OPEN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white54)),
                                      ],
                                    )
                                  : (!widget.channel.isLive
                                      ? const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.videocam_off, size: 12, color: Colors.white30),
                                            SizedBox(width: 4),
                                            Text('OFFLINE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white30)),
                                          ],
                                        )
                                      : const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.play_arrow, size: 14),
                                            SizedBox(width: 2),
                                            Text('PLAY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                          ],
                                        )),
                            ),
                          ),
                  ],
                ),
              ],
            ),
            if (widget.channel.isLive && widget.channel.streamTitle != null) ...[
              const SizedBox(height: 6),
              HoverOverlayMenu(
                trigger: Text(
                  '${widget.channel.streamTitle!} • ${widget.channel.game ?? "Unknown Game"}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                menu: _buildLivePreviewPopup(widget.channel),
              ),
            ],
            if (widget.channel.errorMessage != null) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 12, color: Colors.redAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.channel.errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 10),
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
                  style: theme.textTheme.titleLarge?.copyWith(fontSize: 22),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(width: 10),
                if (widget.channel.isLive)
                  AnimatedBuilder(
                    animation: widget.pulseController,
                    builder: (context, child) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.15 + 0.1 * widget.pulseController.value),
                          border: Border.all(
                            color: Colors.redAccent.withOpacity(0.4 + 0.6 * widget.pulseController.value),
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'LIVE',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      );
                    },
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.15),
                      border: Border.all(
                        color: Colors.grey,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'OFFLINE',
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
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

    final playButton = ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: widget.isPlaying
            ? NeuTheme.surface(themeNotifier.isDarkTheme)
            : (widget.channel.isLive ? theme.primaryColor : NeuTheme.surface(themeNotifier.isDarkTheme)),
        foregroundColor: widget.channel.isLive && !widget.isPlaying
            ? Colors.white
            : NeuTheme.disabledText(themeNotifier.isDarkTheme),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        elevation: (widget.channel.isLive && !widget.isPlaying) ? 4 : 0,
      ),
      onPressed: (widget.isPlaying || !widget.channel.isLive) ? null : widget.onPlay,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: widget.isPlaying
            ? const [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white60),
                ),
                SizedBox(width: 6),
                Text('OPEN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white54)),
              ]
            : (!widget.channel.isLive
                ? const [
                    Icon(Icons.videocam_off, size: 14, color: Colors.white30),
                    SizedBox(width: 4),
                    Text('OFFLINE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white30)),
                  ]
                : const [
                    Icon(Icons.play_arrow, size: 16),
                    SizedBox(width: 4),
                    Text('PLAY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  ]),
      ),
    );

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
                      child: widget.channel.isLive
                          ? HoverOverlayMenu(
                              trigger: avatarContainer,
                              menu: _buildLivePreviewPopup(widget.channel),
                            )
                          : avatarContainer,
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: widget.channel.isLive
                        ? HoverOverlayMenu(
                            trigger: profileDetails,
                            menu: _buildLivePreviewPopup(widget.channel),
                          )
                        : profileDetails,
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
                    child: widget.channel.isLive
                        ? HoverOverlayMenu(
                            trigger: playButton,
                            menu: _buildLivePreviewPopup(widget.channel),
                          )
                        : playButton,
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
                          color: Colors.redAccent.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.redAccent.withOpacity(0.2)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.error_outline, size: 14, color: Colors.redAccent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                widget.channel.errorMessage!,
                                style: const TextStyle(color: Colors.redAccent, fontSize: 11),
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
