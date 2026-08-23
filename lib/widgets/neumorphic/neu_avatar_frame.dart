import 'package:flutter/material.dart';
import '../../theme/theme_notifier.dart';
import 'neu_container.dart';
import 'neu_led_indicator.dart';
import '../../theme/neu_theme.dart';

class NeuAvatarFrame extends StatelessWidget {
  final String? imageUrl;
  final double size;
  final bool isLive;
  final VoidCallback? onTap;
  final String fallbackText;

  const NeuAvatarFrame({
    Key? key,
    this.imageUrl,
    this.size = 56.0,
    this.isLive = false,
    this.onTap,
    this.fallbackText = '?',
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget avatarCore = GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Outer 3D Vinyl / Lens Outer Bevel Ring
            NeuContainer(
              width: size,
              height: size,
              isCircle: true,
              style: NeuStyle.raised,
              depth: 4.0,
              // Intentional: sub-grid. These are the two concentric ring widths of
              // the avatar frame, not spacing between things.
              padding: const EdgeInsets.all(3.0),
              child: // Inner Sunken Aperture Well
                  NeuContainer(
                isCircle: true,
                style: NeuStyle.sunken,
                depth: 3.0,
                padding: const EdgeInsets.all(2.0), // Intentional: inner ring width
                child: ClipOval(
                  child: imageUrl != null && imageUrl!.isNotEmpty
                      ? Image.network(
                          imageUrl!,
                          width: size - 10,
                          height: size - 10,
                          fit: BoxFit.cover,
                          // Twitch avatars are often 300x300+; decode at the
                          // displayed size instead of full resolution.
                          cacheWidth: ((size - 10) *
                                  MediaQuery.devicePixelRatioOf(context))
                              .ceil(),
                          errorBuilder: (context, error, stackTrace) =>
                              _buildFallback(theme),
                        )
                      : _buildFallback(theme),
                ),
              ),
            ),

            // Optional Live Glowing LED Badge overlay
            if (isLive)
              Positioned(
                bottom: -2,
                right: -2,
                child: Container(
                  padding: const EdgeInsets.all(NeuSpace.s2),
                  decoration: BoxDecoration(
                    color: NeuTheme.surface(isDark),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: NeuTheme.shadow(isDark).withValues(alpha: 0.5),
                        blurRadius: 4,
                      )
                    ],
                  ),
                  child: NeuLedIndicator(
                    // Scale with the avatar instead of a fixed 14px badge.
                    size: (size * 0.25).clamp(10.0, 16.0),
                    isLive: true,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return avatarCore;
  }

  Widget _buildFallback(ThemeData theme) {
    return Container(
      color: theme.primaryColor.withValues(alpha: 0.2),
      child: Center(
        child: Text(
          fallbackText.isNotEmpty ? fallbackText[0].toUpperCase() : '?',
          style: TextStyle(
            color: themeNotifier.accentInk,
            fontWeight: FontWeight.bold,
            // Intentional: proportional. Initials fill a circle whose
            // diameter the caller chooses, so a fixed step would overflow the
            // small frames and swim in the large ones.
            fontSize: size * 0.4,
          ),
        ),
      ),
    );
  }
}
