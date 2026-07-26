import 'package:flutter/material.dart';
import 'neu_container.dart';
import 'neu_led_indicator.dart';

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
              padding: const EdgeInsets.all(3.0),
              child: // Inner Sunken Aperture Well
                  NeuContainer(
                isCircle: true,
                style: NeuStyle.sunken,
                depth: 3.0,
                padding: const EdgeInsets.all(2.0),
                child: ClipOval(
                  child: imageUrl != null && imageUrl!.isNotEmpty
                      ? Image.network(
                          imageUrl!,
                          width: size - 10,
                          height: size - 10,
                          fit: BoxFit.cover,
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
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF181A20) : const Color(0xFFE6ECEF),
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 4,
                      )
                    ],
                  ),
                  child: const NeuLedIndicator(
                    size: 14.0,
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
      color: theme.primaryColor.withOpacity(0.2),
      child: Center(
        child: Text(
          fallbackText.isNotEmpty ? fallbackText[0].toUpperCase() : '?',
          style: TextStyle(
            color: theme.primaryColor,
            fontWeight: FontWeight.bold,
            fontSize: size * 0.4,
          ),
        ),
      ),
    );
  }
}
