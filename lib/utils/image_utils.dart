import 'package:flutter/painting.dart';

/// Avatar provider decoded at a small fixed size.
///
/// Twitch profile images arrive at 300x300; decoding them full-size for the
/// 16-46px circles used across the sidebar, popovers and dialogs multiplies
/// image-cache memory by ~40x per avatar. 96px covers every avatar slot in
/// the app at high-DPI.
ImageProvider resizedAvatar(String url, {int width = 96}) {
  return ResizeImage(NetworkImage(url), width: width);
}
