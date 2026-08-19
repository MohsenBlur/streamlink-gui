import 'dart:async';

import 'package:flutter/material.dart';

import '../models/twitch_channel.dart';
import '../theme/neu_theme.dart';
import '../theme/theme_notifier.dart';

/// Hover preview card for a live channel: thumbnail, title, game, viewers.
///
/// This was previously duplicated verbatim in main.dart and
/// dashboard_header.dart (the copies had already diverged on the game-text
/// color), and both derived a cache-busted thumbnail URL from the current
/// time bucketed to 10 seconds. HoverOverlayMenu rebuilds its overlay on every
/// mouse move, so crossing a bucket boundary while hovering minted a new URL
/// and the image flashed blank while it reloaded.
///
/// As a StatefulWidget the URL is minted once on open and refreshed by a
/// timer, with gapless playback so a refresh never blanks the card.
class LivePreviewPopup extends StatefulWidget {
  const LivePreviewPopup({Key? key, required this.channel}) : super(key: key);

  final TwitchChannel channel;

  /// The flip-avoidance estimate HoverOverlayMenu needs for this card.
  static const Size estimatedSize = Size(260, 220);

  @override
  State<LivePreviewPopup> createState() => _LivePreviewPopupState();
}

class _LivePreviewPopupState extends State<LivePreviewPopup> {
  late String _thumbUrl;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _thumbUrl = _buildUrl();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _thumbUrl = _buildUrl());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  String _buildUrl() {
    final cleanName = widget.channel.username.toLowerCase().trim();
    final buster = DateTime.now().millisecondsSinceEpoch;
    return 'https://static-cdn.jtvnw.net/previews-ttv/live_user_$cleanName-320x180.jpg?t=$buster';
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final isDark = themeNotifier.isDarkTheme;

    return Container(
      width: LivePreviewPopup.estimatedSize.width,
      decoration: NeuTheme.raisedDecoration(isDark, radius: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                _thumbUrl,
                fit: BoxFit.cover,
                // Keep the previous frame while a refreshed URL loads.
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    color: NeuTheme.surface(isDark),
                    child: Center(
                      child: Icon(Icons.live_tv,
                          color: NeuTheme.subtext(isDark), size: 36),
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
                        color: NeuTheme.live,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        channel.username,
                        style: NeuTheme.titleStyle(isDark, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (channel.viewerCount != null &&
                        channel.viewerCount != '0') ...[
                      Icon(Icons.remove_red_eye,
                          color: NeuTheme.subtext(isDark), size: 12),
                      const SizedBox(width: 4),
                      Text(
                        channel.viewerCount!,
                        style: NeuTheme.subtextStyle(isDark, fontSize: 11),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  channel.streamTitle ?? 'Streaming Live!',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NeuTheme.bodyStyle(isDark, fontSize: 12),
                ),
                if (channel.game != null && channel.game != 'Offline') ...[
                  const SizedBox(height: 6),
                  Text(
                    channel.game!,
                    style: TextStyle(
                      color: themeNotifier.primaryColor,
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
}
