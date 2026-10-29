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
///
/// The sidebar's rows and avatars use it, and so do Home's live cards, which
/// had the same lag under the same GestureDetector.
class DoubleClickListener extends StatefulWidget {
  const DoubleClickListener({
    super.key,
    required this.onTap,
    required this.onDoubleTap,
    required this.builder,
    this.tapLeaves = false,
  });

  final VoidCallback onTap;

  /// Null for offline channels: every click is then a plain click.
  final VoidCallback? onDoubleTap;

  final Widget Function(VoidCallback onTap) builder;

  /// Whether [onTap] takes this widget off the screen, as a Home live card's
  /// does: the click opens the channel, and Home goes. The second click of a
  /// double then landed on the channel page, and the double-click that
  /// watches the channel did nothing. With this set, the spot the first click
  /// landed on is held over whatever replaces the widget, for as long as a
  /// press there would still be the second half of a double.
  final bool tapLeaves;

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
    // Before the tap, which runs on this same pointer-up after this Listener
    // and is what takes the widget away.
    if (widget.tapLeaves) _holdSecondClick(event.position);
  }

  /// Holds the spot around [at] in the root overlay for [kDoubleTapTimeout],
  /// over whatever the tap puts there: a press inside it is the second half
  /// of the double, and goes to [DoubleClickListener.onDoubleTap] and no
  /// further. Owned by its own timer, not this state, which the tap is
  /// about to dispose.
  void _holdSecondClick(Offset at) {
    final onDoubleTap = widget.onDoubleTap;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    final box = overlay?.context.findRenderObject();
    if (onDoubleTap == null || overlay == null || box is! RenderBox) return;
    final centre = box.globalToLocal(at);

    var released = false;
    late final OverlayEntry entry;
    late final Timer expiry;
    void release() {
      if (released) return;
      released = true;
      expiry.cancel();
      entry.remove();
      entry.dispose();
    }

    entry = OverlayEntry(
      builder: (context) => Positioned.fromRect(
        // The framework's own double-tap reach, as _onPointerDown measures.
        rect: Rect.fromCircle(center: centre, radius: kDoubleTapSlop),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            release();
            if (event.buttons == kPrimaryButton) onDoubleTap();
          },
        ),
      ),
    );
    overlay.insert(entry);
    expiry = Timer(kDoubleTapTimeout, release);
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
