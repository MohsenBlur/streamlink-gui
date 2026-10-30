import 'package:flutter/services.dart';

import '../utils/window_bounds.dart';

/// The runner's own window channel (windows/runner/flutter_window.cpp).
///
/// window_manager still owns everything else about the window - the hidden
/// title bar, close interception, the minimum size, events - but geometry
/// goes through here, in physical pixels, because window_manager converts
/// every position and size with whatever devicePixelRatio the window has at
/// that instant, which during startup across mixed-DPI monitors is a race.
abstract final class NativeWindow {
  static const MethodChannel _channel = MethodChannel('streamlink_gui/window');

  /// Every monitor, physical pixels. Empty when the runner cannot say (a
  /// platform without this channel), in which case nothing is moved.
  static Future<List<MonitorInfo>> monitors() async {
    final raw = await _channel.invokeListMethod<Object?>('getMonitors');
    return [
      for (final entry in raw ?? const <Object?>[])
        ?MonitorInfo.fromMap(entry),
    ];
  }

  /// The window's restorable state, or null when the runner cannot say.
  static Future<WindowState?> state() async =>
      WindowState.fromMap(await _channel.invokeMethod<Object?>('getPlacement'));

  /// Tells the runner whether the app keeps this launch hidden ([hidden]:
  /// Start minimized), before anything else touches the window, and returns
  /// whether the launch stays hidden. Null when the runner cannot say.
  ///
  /// The runner reads --start-minimized itself, before the window exists,
  /// and from then until the first frame keeps the hidden window from taking
  /// the foreground. The setting reached it only with the initial placement,
  /// and that was too late: window_manager's title bar setup had activated
  /// the hidden frame by then, and on a launch from Explorer or the Start
  /// menu that took the foreground from the user's app, keyboard included.
  ///
  /// The answer is the runner's, and can be yes when [hidden] is no: it also
  /// keeps a launch hidden whose launcher asked for no window at all
  /// (STARTUPINFO's SW_HIDE), which nothing on this side can see.
  static Future<bool?> startsHidden({required bool hidden}) =>
      _channel.invokeMethod<bool>('startsHidden', {'hidden': hidden});

  /// Places the still-hidden window at [bounds] (physical; null leaves it
  /// where it is) and records how the first show presents it: maximized or
  /// not, and whether it stays hidden (Start minimized).
  ///
  /// Must run before the first frame. The runner shows the window from its
  /// first-frame callback, so a move made now happens where nobody can see
  /// it, and that first frame is already laid out at the final size and DPI:
  /// no jump from the creation position, and no frame at a stale size after
  /// the DPI change.
  static Future<WindowState?> setInitialPlacement(
    Rect? bounds, {
    required bool maximized,
    required bool hidden,
  }) async {
    final raw = await _channel.invokeMethod<Object?>('setInitialPlacement', {
      if (bounds != null) ...{
        'left': bounds.left.round(),
        'top': bounds.top.round(),
        'width': bounds.width.round(),
        'height': bounds.height.round(),
      },
      'maximized': maximized,
      'hidden': hidden,
    });
    return WindowState.fromMap(raw);
  }

  /// Shows and focuses the window the way it should come back: the planned
  /// first show (maximized included) if it has never been on screen, restore
  /// if minimized, show if hidden. Also re-asserts the content view.
  static Future<void> show() => _channel.invokeMethod<void>('show');
}
