import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A click that selects at once, and a double-click that also plays.
///
/// Live rows used to put a `GestureDetector(onDoubleTap:)` around the row's
/// own tap handler, and that held every single click for the full double-tap
/// timeout (about 300ms): the double-tap recognizer keeps the gesture arena
/// open after the first pointer-up to see whether a second press follows, and
/// the row's tap cannot win until it gives up. So the rows users click most -
/// live channels - selected a third of a second late, while offline rows (no
/// double-tap handler) were instant.
///
/// This reads raw pointer events instead, and a Listener never joins the
/// arena, so the row's own tap fires on pointer-up exactly as an offline row's
/// does. [builder] receives the tap handler to install on that recognizer:
/// it is [onTap], except that it ignores the second click of a double - that
/// click already played the channel, and re-selecting a channel selected a
/// moment ago would only clear and refetch its VOD list.
class DoubleClickListener extends StatefulWidget {
  const DoubleClickListener({
    super.key,
    required this.onTap,
    required this.onDoubleTap,
    required this.builder,
  });

  final VoidCallback onTap;

  /// Null for offline channels: every click is then a plain click.
  final VoidCallback? onDoubleTap;

  final Widget Function(VoidCallback onTap) builder;

  @override
  State<DoubleClickListener> createState() => _DoubleClickListenerState();
}

class _DoubleClickListenerState extends State<DoubleClickListener> {
  /// Open from a click's pointer-up for [kDoubleTapTimeout]; a press that
  /// lands inside it is the second half of a double. The framework's own
  /// recognizer measures the same interval, first up to second down.
  Timer? _secondClickWindow;
  Offset? _firstClickAt;

  int? _pressPointer;
  Offset? _pressAt;
  bool _pressIsSecondClick = false;

  /// Set by the pointer-up that completes a double, so the row's tap - which
  /// fires on that same event, after this Listener - is skipped. Cleared in a
  /// microtask, so a stray flag can never eat a later keyboard activation.
  bool _ignoreTap = false;

  @override
  void dispose() {
    _secondClickWindow?.cancel();
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton) {
      _pressPointer = null;
      return;
    }
    final first = _firstClickAt;
    _pressIsSecondClick = _secondClickWindow != null &&
        first != null &&
        (event.position - first).distance <= kDoubleTapSlop;
    _secondClickWindow?.cancel();
    _secondClickWindow = null;
    _pressPointer = event.pointer;
    _pressAt = event.position;
  }

  void _onPointerUp(PointerUpEvent event) {
    final at = _pressAt;
    if (event.pointer != _pressPointer || at == null) return;
    _pressPointer = null;
    // A drag that ends on the row is not a click.
    if ((event.position - at).distance > kTouchSlop) {
      _firstClickAt = null;
      return;
    }
    if (_pressIsSecondClick) {
      _firstClickAt = null;
      final onDoubleTap = widget.onDoubleTap;
      if (onDoubleTap != null) {
        _ignoreTap = true;
        scheduleMicrotask(() => _ignoreTap = false);
        onDoubleTap();
      }
      return;
    }
    _firstClickAt = event.position;
    _secondClickWindow = Timer(kDoubleTapTimeout, () {
      _secondClickWindow = null;
      _firstClickAt = null;
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pressPointer) _pressPointer = null;
  }

  void _handleTap() {
    if (_ignoreTap) {
      _ignoreTap = false;
      return;
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: widget.builder(_handleTap),
    );
  }
}
