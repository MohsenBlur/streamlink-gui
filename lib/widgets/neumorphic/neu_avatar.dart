import 'package:flutter/material.dart';
import '../../theme/neu_theme.dart';
import '../../utils/image_utils.dart';

/// A plain circular channel avatar that survives a broken image URL.
///
/// The nine places that showed one all used `CircleAvatar` with
/// `backgroundImage` and a `child` fallback chosen on `url == null`. That
/// covers "no avatar known" but not "the avatar failed to load", which is the
/// common case: Twitch's CDN URLs expire, and `backgroundImage` has no error
/// path - `onBackgroundImageError` only swallows the exception, leaving an
/// empty coloured circle with no way to draw anything in its place.
///
/// Using an `Image` inside a clipped circle instead means `errorBuilder` can
/// paint the same fallback the null case gets. The fault self-heals when the
/// next poll refreshes the URL, so this is about not looking broken for the
/// minute in between.
///
/// [NeuAvatarFrame] is the elaborate bevelled version for the dashboard
/// header; this is the small one for lists, popovers and dialogs.
class NeuAvatar extends StatelessWidget {
  const NeuAvatar({
    Key? key,
    required this.url,
    required this.radius,
    required this.isDark,
    this.backgroundColor,
    this.iconColor,
  }) : super(key: key);

  final String? url;
  final double radius;
  final bool isDark;

  /// Defaults to the surface colour, as every call site passed.
  final Color? backgroundColor;

  /// Defaults to the subtext colour, as every call site passed.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final trimmed = url?.trim() ?? '';

    // Icon size tracks the radius, which is what all nine call sites used.
    final fallback = Icon(
      Icons.person,
      size: radius,
      color: iconColor ?? NeuTheme.subtext(isDark),
    );

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: backgroundColor ?? NeuTheme.surface(isDark),
        shape: BoxShape.circle,
      ),
      child: trimmed.isEmpty
          ? fallback
          : Image(
              image: resizedAvatar(trimmed),
              width: size,
              height: size,
              fit: BoxFit.cover,
              // Keep the old frame while a refreshed URL decodes, so a routine
              // avatar-URL refresh does not flash the fallback.
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => fallback,
            ),
    );
  }
}
