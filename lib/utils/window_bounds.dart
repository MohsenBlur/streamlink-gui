import 'dart:ui';

/// Pure window-geometry sanity: given saved bounds and the current display
/// rectangles, return bounds that are guaranteed usable.
///
/// Saved geometry can go bad in two ways: hand-edited/corrupt values (NaN,
/// negative sizes) and displays that no longer exist (a laptop undocked from
/// the monitor the window lived on). Restoring either strands the window
/// off-screen with no way to grab it.
Rect sanitizeWindowBounds({
  required double? x,
  required double? y,
  required double width,
  required double height,
  required List<Rect> displays,
  Size minSize = const Size(380, 500),
  Size fallbackSize = const Size(1280, 720),
}) {
  // Repair the size first.
  var w = width;
  var h = height;
  if (!w.isFinite || w < minSize.width) w = fallbackSize.width;
  if (!h.isFinite || h < minSize.height) h = fallbackSize.height;

  final primary = displays.isNotEmpty
      ? displays.first
      : Rect.fromLTWH(0, 0, fallbackSize.width, fallbackSize.height);

  // Never restore larger than the primary display (a saved 4K-monitor size
  // on a laptop screen would bury the window edges).
  if (w > primary.width && primary.width >= minSize.width) w = primary.width;
  if (h > primary.height && primary.height >= minSize.height) h = primary.height;

  Rect centered() => Rect.fromLTWH(
        primary.left + (primary.width - w) / 2,
        primary.top + (primary.height - h) / 2,
        w,
        h,
      );

  if (x == null || y == null || !x.isFinite || !y.isFinite) {
    return centered();
  }

  final candidate = Rect.fromLTWH(x, y, w, h);

  // Enough of the window (including its title bar) must be on SOME display
  // to grab it with the mouse.
  const minVisible = 50.0;
  for (final display in displays) {
    final overlap = candidate.intersect(display);
    if (overlap.width >= minVisible && overlap.height >= minVisible) {
      return candidate;
    }
  }
  return centered();
}
