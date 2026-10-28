import 'package:flutter/widgets.dart';

/// A hold on one route, so the code that opened a dialog can close exactly
/// that dialog later - whatever has been pushed on top of it in between.
///
/// `Navigator.pop(context)` pops the TOP route, which is only the dialog you
/// mean while nothing else has opened. The update flow learned this the hard
/// way: its failure handler popped whatever was on top (a dialog the tray's
/// Exit had opened over the progress dialog) and left the "Updating" dialog,
/// which has no buttons and cannot be dismissed, on screen for good.
class RouteHandle {
  ModalRoute<Object?>? _route;

  /// Records the route [routeContext] belongs to. Call it from the dialog's
  /// own builder; the first call wins, so rebuilds are harmless.
  void attach(BuildContext routeContext) {
    _route ??= ModalRoute.of(routeContext);
  }

  /// Whether the route is still on the navigator.
  bool get isOpen => _route?.isActive ?? false;

  /// Closes the route if it is still open, and returns whether it was.
  ///
  /// Popped normally (with its exit transition) when it is on top; removed
  /// in place when something covers it, which leaves the covering route
  /// exactly as it was.
  bool close() {
    final route = _route;
    final navigator = route?.navigator;
    if (route == null || navigator == null || !route.isActive) return false;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
    return true;
  }
}
