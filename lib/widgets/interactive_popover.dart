import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/neu_theme.dart';
import 'neumorphic/neu_focusable.dart';

class InteractivePopover extends StatefulWidget {
  final Widget child;
  final Widget? popover;

  /// Alternative to [popover] for content that needs to close itself (e.g. a
  /// result list where picking an item should dismiss the popover). The
  /// callback closes this popover.
  final Widget Function(BuildContext context, VoidCallback close)?
      popoverBuilder;

  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset offset;

  const InteractivePopover({
    Key? key,
    required this.child,
    this.popover,
    this.popoverBuilder,
    this.targetAnchor = Alignment.bottomRight,
    this.followerAnchor = Alignment.topRight,
    this.offset = const Offset(0, 6),
  })  : assert(popover != null || popoverBuilder != null),
        super(key: key);

  @override
  State<InteractivePopover> createState() => _InteractivePopoverState();
}

class _InteractivePopoverState extends State<InteractivePopover> {
  // An OverlayPortal rather than an OverlayEntry plus a
  // CompositedTransformFollower. The follower is positioned at COMPOSITING
  // time, so layout never learns where the popover lands and nothing can keep
  // it on screen: the 340px activity popover, right-aligned to a pill ~150px
  // from the window's edge, opened 110px off the left of a 380px window with
  // every label cut off. The portal's layout builder hands over the trigger's
  // rect and the overlay's size during layout, which is what clamping needs.
  //
  // It also keeps an open popover's content live for free: the overlay child
  // is built from this widget's build, so a prop change rebuilds it. The old
  // entry had to be marked dirty by hand (the header stats popover never
  // refreshed while open until it was).
  final OverlayPortalController _portal = OverlayPortalController();

  bool get _isOpen => _portal.isShowing;

  void _togglePopover() {
    if (_isOpen) {
      _closePopover();
    } else {
      _openPopover();
    }
  }

  void _openPopover() {
    if (_isOpen) return;
    setState(_portal.show);
  }

  void _closePopover() {
    if (!_isOpen || !mounted) return;
    setState(_portal.hide);
  }

  Widget _buildOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    final trigger = MatrixUtils.transformRect(
        info.childPaintTransform, Offset.zero & info.childSize);
    return Stack(
      children: [
        // Full-screen barrier to dismiss popover when clicking outside
        GestureDetector(
          onTap: _closePopover,
          behavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
        Positioned.fill(
          child: CustomSingleChildLayout(
            delegate: PopoverPlacement(
              trigger: trigger,
              targetAnchor: widget.targetAnchor,
              followerAnchor: widget.followerAnchor,
              offset: widget.offset,
            ),
            child: Material(
              color: Colors.transparent,
              child: widget.popoverBuilder != null
                  ? widget.popoverBuilder!(context, _closePopover)
                  : widget.popover!,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // The trigger contract lives HERE, once: a click cursor (two of the four
    // trigger chips in the app showed no pointer feedback at all), keyboard
    // activation and button semantics via NeuFocusable (a popover no
    // Tab-user could ever open is a menu that does not exist for them), and
    // the tap handler. The child must NOT be a button of its own - an inner
    // recognizer wins the gesture arena and the popover goes dead, which is
    // exactly how the selection bar's Actions button shipped broken.
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: _buildOverlay,
      child: NeuFocusable(
        onActivate: _togglePopover,
        semanticLabel: 'Open menu',
        focusRadius: 10,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: _togglePopover,
            behavior: HitTestBehavior.opaque,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Places a popover against its trigger, then keeps it inside the window.
///
/// [targetAnchor] on the trigger meets [followerAnchor] on the popover, moved
/// by [offset] - the same contract the CompositedTransformFollower had, so an
/// unconstrained popover lands exactly where it always did. Then, in order:
///
/// * it is never larger than the window less [margin] on each side;
/// * it flips to the other side of the trigger when it does not fit on the
///   side it asked for and does fit on the other (a trigger near the bottom
///   edge opens upward);
/// * it slides along each axis until it is inside the window, which is what
///   keeps a right-aligned popover from opening off the left of a narrow one.
///
/// Public so the geometry can be tested without pumping anything.
class PopoverPlacement extends SingleChildLayoutDelegate {
  const PopoverPlacement({
    required this.trigger,
    required this.targetAnchor,
    required this.followerAnchor,
    required this.offset,
    this.margin = NeuSpace.s8,
  });

  /// The trigger's rect in the overlay's coordinates.
  final Rect trigger;
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final Offset offset;

  /// Clearance kept between the popover and the window's edges.
  final double margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(
      math.max(0.0, constraints.maxWidth - 2 * margin),
      math.max(0.0, constraints.maxHeight - 2 * margin),
    ));
  }

  Offset _aligned(Size childSize, Alignment target, Alignment follower,
          Offset by) =>
      target.withinRect(trigger) + by - follower.alongSize(childSize);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var position =
        _aligned(childSize, targetAnchor, followerAnchor, offset);

    bool fitsVertically(Offset p) =>
        p.dy >= margin && p.dy + childSize.height <= size.height - margin;
    if (!fitsVertically(position)) {
      final flipped = _aligned(
        childSize,
        Alignment(targetAnchor.x, -targetAnchor.y),
        Alignment(followerAnchor.x, -followerAnchor.y),
        Offset(offset.dx, -offset.dy),
      );
      if (fitsVertically(flipped)) position = flipped;
    }

    double inside(double value, double extent, double available) =>
        value.clamp(margin, math.max(margin, available - margin - extent));
    return Offset(
      inside(position.dx, childSize.width, size.width),
      inside(position.dy, childSize.height, size.height),
    );
  }

  @override
  bool shouldRelayout(PopoverPlacement oldDelegate) =>
      trigger != oldDelegate.trigger ||
      targetAnchor != oldDelegate.targetAnchor ||
      followerAnchor != oldDelegate.followerAnchor ||
      offset != oldDelegate.offset ||
      margin != oldDelegate.margin;
}
