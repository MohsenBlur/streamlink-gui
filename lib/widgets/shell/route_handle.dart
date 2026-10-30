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

  // A close that came before the dialog's first build. The route is only
  // known from its builder, which runs on the next frame, and the work the
  // dialog covers starts at once: an update whose download fails inside
  // that frame asked to close a dialog the handle had not seen yet, and the
  // "Updating" dialog then built and stayed for good.
  bool _closeRequested = false;

  /// Records the route [routeContext] belongs to. Call it from the dialog's
  /// own builder; the first call wins, so rebuilds are harmless.
  ///
  /// When [close] was asked for before this, the route is closed straight
  /// after the frame that built it: a navigator cannot pop mid-build.
  void attach(BuildContext routeContext) {
    if (_route != null) return;
    _route = ModalRoute.of(routeContext);
    if (_closeRequested && _route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => close());
    }
  }

  /// Whether the route is still on the navigator.
  bool get isOpen => _route?.isActive ?? false;

  /// Closes the route if it is still open, and returns whether it was.
  ///
  /// Popped normally (with its exit transition) when it is on top; removed
  /// in place when something covers it, which leaves the covering route
  /// exactly as it was. Before the route has built (no [attach] yet) this
  /// returns false and the close is kept: [attach] carries it out.
  bool close() {
    final route = _route;
    if (route == null) {
      _closeRequested = true;
      return false;
    }
    final navigator = route.navigator;
    if (navigator == null || !route.isActive) return false;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
    return true;
  }
}
