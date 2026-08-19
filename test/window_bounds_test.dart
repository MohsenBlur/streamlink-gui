import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/window_bounds.dart';

void main() {
  const primary = Rect.fromLTWH(0, 0, 1920, 1080);
  const secondary = Rect.fromLTWH(1920, 0, 1920, 1080);

  group('sanitizeWindowBounds', () {
    test('valid on-screen bounds pass through unchanged', () {
      final r = sanitizeWindowBounds(
          x: 100, y: 100, width: 1280, height: 720, displays: [primary]);
      expect(r, const Rect.fromLTWH(100, 100, 1280, 720));
    });

    test('window on a secondary display stays there', () {
      final r = sanitizeWindowBounds(
          x: 2000, y: 50, width: 1280, height: 720,
          displays: [primary, secondary]);
      expect(r.left, 2000);
    });

    test('far off-screen position is rescued to the primary center', () {
      final r = sanitizeWindowBounds(
          x: -20000, y: -20000, width: 1280, height: 720,
          displays: [primary, secondary]);
      expect(r.left, (1920 - 1280) / 2);
      expect(r.top, (1080 - 720) / 2);
    });

    test('a sliver of overlap below the grab threshold still recenters', () {
      // Only 10px visible on the left edge.
      final r = sanitizeWindowBounds(
          x: -1270, y: 100, width: 1280, height: 720, displays: [primary]);
      expect(r.left, isNot(-1270));
    });

    test('null position centers (first run)', () {
      final r = sanitizeWindowBounds(
          x: null, y: null, width: 1280, height: 720, displays: [primary]);
      expect(r.left, (1920 - 1280) / 2);
    });

    test('NaN and undersized values fall back to defaults', () {
      final r = sanitizeWindowBounds(
          x: double.nan, y: 100, width: 10, height: -5, displays: [primary]);
      expect(r.width, 1280);
      expect(r.height, 720);
      expect(r.left.isFinite, isTrue);
    });

    test('oversized saved bounds clamp to the primary display', () {
      final r = sanitizeWindowBounds(
          x: 0, y: 0, width: 3840, height: 2160, displays: [primary]);
      expect(r.width, 1920);
      expect(r.height, 1080);
    });

    test('no display info at all still yields finite, usable bounds', () {
      final r = sanitizeWindowBounds(
          x: -9999, y: -9999, width: 1280, height: 720, displays: []);
      expect(r.left.isFinite, isTrue);
      expect(r.width, 1280);
    });
  });
}
