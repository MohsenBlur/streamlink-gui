import 'package:flutter/material.dart';
import '../models/twitch_channel.dart';
import 'hover_overlay_menu.dart';

class DashboardHeader extends StatefulWidget {
  final TwitchChannel channel;
  final AnimationController pulseController;
  final VoidCallback onPlay;
  final VoidCallback onRefresh;
  final void Function(String) openExternalLink;

  const DashboardHeader({
    Key? key,
    required this.channel,
    required this.pulseController,
    required this.onPlay,
    required this.onRefresh,
    required this.openExternalLink,
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
      decoration: BoxDecoration(
        color: const Color(0xFF161B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E2433)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 15,
            spreadRadius: 2,
          )
        ],
      ),
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
                    color: const Color(0xFF1F2937),
                    child: const Center(
                      child: Icon(Icons.live_tv, color: Colors.white24, size: 36),
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (channel.viewerCount != null && channel.viewerCount != '0') ...[
                      const Icon(Icons.remove_red_eye, color: Colors.white54, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        channel.viewerCount!,
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  channel.streamTitle ?? 'Streaming Live!',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.3,
                  ),
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
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 14, color: Colors.white70),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildMiniActionBtn({required IconData icon, required String tooltip, required VoidCallback? onPressed}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF374151)),
      ),
      child: IconButton(
        icon: Icon(icon, size: 14, color: Colors.white70),
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
      decoration: BoxDecoration(
        color: const Color(0xFF0C0F17),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSmall = MediaQuery.of(context).size.width < 1180;
    
    final cardWidget = GestureDetector(
      onTap: widget.channel.isLive ? widget.onPlay : null,
      child: MouseRegion(
        cursor: widget.channel.isLive ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF161B26),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1E2433)),
            boxShadow: [
              BoxShadow(
                color: (widget.channel.isLive ? Colors.green : Colors.grey).withOpacity(0.03),
                blurRadius: 20,
                spreadRadius: 2,
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row 1: Profile Avatar & Info
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 90,
                    child: Center(
                      child: AnimatedBuilder(
                        animation: widget.pulseController,
                        builder: (context, child) {
                          final pulseVal = widget.pulseController.value;
                          return Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: widget.channel.isLive
                                    ? Colors.redAccent.withOpacity(0.5 + pulseVal * 0.5)
                                    : Colors.white24,
                                width: 2.5,
                              ),
                              boxShadow: widget.channel.isLive
                                  ? [
                                      BoxShadow(
                                        color: Colors.redAccent.withOpacity(0.2 * pulseVal),
                                        blurRadius: 8 + 8 * pulseVal,
                                        spreadRadius: 1 + 2 * pulseVal,
                                      )
                                    ]
                                  : null,
                            ),
                            child: CircleAvatar(
                              radius: 36,
                              backgroundColor: const Color(0xFF1F2937),
                              backgroundImage: widget.channel.avatarUrl != null ? NetworkImage(widget.channel.avatarUrl!) : null,
                              child: widget.channel.avatarUrl == null
                                  ? const Icon(Icons.person, size: 36, color: Colors.white70)
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Text(
                                  widget.channel.username,
                                  style: theme.textTheme.titleLarge?.copyWith(fontSize: 22),
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
                                ? HoverOverlayMenu(
                                    trigger: MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1E2433),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: Colors.white10),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.more_vert, color: Colors.white70, size: 16),
                                            SizedBox(width: 4),
                                            Text('Actions', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ),
                                    ),
                                    menu: Container(
                                      width: 160,
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF161B26),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: const Color(0xFF1E2433)),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.5),
                                            blurRadius: 10,
                                          )
                                        ],
                                      ),
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
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, height: 1.3),
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
                            color: widget.channel.isLive ? Colors.white70 : Colors.white38,
                            fontWeight: widget.channel.isLive ? FontWeight.w500 : FontWeight.normal
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 14),
              
              // Row 2: PLAY Button & Stats Chips
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 90,
                    height: 32,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.primaryColor,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        elevation: 4,
                      ),
                      onPressed: widget.onPlay,
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_arrow, size: 16),
                          SizedBox(width: 4),
                          Text('PLAY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
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
                          color: Colors.white38,
                          label: widget.channel.lastUpdated != null
                              ? 'Updated: ${_timeAgo(widget.channel.lastUpdated!)}'
                              : 'Not updated',
                        ),
                      ],
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
                                'Error: ${widget.channel.errorMessage}',
                                style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
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

    return widget.channel.isLive
        ? HoverOverlayMenu(
            trigger: cardWidget,
            menu: _buildLivePreviewPopup(widget.channel),
          )
        : cardWidget;
  }
}
