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
///
/// The buster is bucketed again, to [refreshInterval], and the reason is the
/// opposite end of the same problem. HoverOverlayMenu removes its overlay on
/// exit, so every re-hover is a fresh State; with a millisecond buster every
/// re-hover was a never-seen URL - a new CDN request, a new ImageCache entry
/// and a blank card while it loaded, for a preview Twitch itself refreshes
/// only every few minutes. Minted once per open AND bucketed, a re-hover
/// within the interval reuses the image already decoded.
class LivePreviewPopup extends StatefulWidget {
  const LivePreviewPopup({Key? key, required this.channel}) : super(key: key);

  final TwitchChannel channel;

  /// The flip-avoidance estimate HoverOverlayMenu needs for this card.
  static const Size estimatedSize = Size(260, 220);

  /// How long one preview URL stays current: the open card's refresh timer
  /// and the cache-buster's bucket are the same interval.
  static const Duration refreshInterval = Duration(seconds: 30);

  /// The preview image URL for [username] as of [now].
  static String previewUrl(String username, DateTime now) {
    final cleanName = username.toLowerCase().trim();
    final bucket =
        now.millisecondsSinceEpoch ~/ refreshInterval.inMilliseconds;
    return 'https://static-cdn.jtvnw.net/previews-ttv/live_user_$cleanName-320x180.jpg?t=$bucket';
  }

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
    _refreshTimer =
        Timer.periodic(LivePreviewPopup.refreshInterval, (_) {
      if (mounted) setState(() => _thumbUrl = _buildUrl());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  String _buildUrl() =>
      LivePreviewPopup.previewUrl(widget.channel.username, DateTime.now());

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final isDark = themeNotifier.isDarkTheme;

    return Container(
      width: LivePreviewPopup.estimatedSize.width,
      decoration: NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            // Concentric with the r12 container it sits flush inside -
            // 11 was the exact off-by-one NeuRadius.inner's doc warns about.
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(NeuRadius.r12)),
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
            padding: const EdgeInsets.all(NeuSpace.s12),
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
                    const SizedBox(width: NeuSpace.s6),
                    Expanded(
                      child: Text(
                        channel.username,
                        style: NeuType.headingSm(isDark),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (channel.viewerCount != null &&
                        channel.viewerCount != '0') ...[
                      Icon(Icons.remove_red_eye,
                          color: NeuTheme.subtext(isDark), size: 12),
                      const SizedBox(width: NeuSpace.s4),
                      Text(
                        channel.viewerCount!,
                        style: NeuType.caption(isDark),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: NeuSpace.s6),
                Text(
                  channel.streamTitle ?? 'Streaming Live!',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: NeuType.bodySm(isDark),
                ),
                if (channel.game != null && channel.game != 'Offline') ...[
                  const SizedBox(height: NeuSpace.s6),
                  Text(
                    channel.game!,
                    style: NeuType.captionStrong(isDark, color: themeNotifier.accentInk),
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
