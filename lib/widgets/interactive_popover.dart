import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  // Focus moves INTO the popover when it opens, so its Esc binding below
  // hears every Esc. It used to stay where it was: after a mouse click that
  // was the page, the key went straight to the page's shortcuts, and Esc
  // closed the Library behind a popover that stayed open. A scope of its own
  // also lets an `autofocus` field inside take focus, which it cannot in a
  // scope whose focused child is the page's.
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'popover');

  // The trigger's key hook, so a focus move onto the trigger is not mistaken
  // for focus leaving the popover.
  final FocusNode _triggerFocus = FocusNode(
      debugLabel: 'popover trigger', canRequestFocus: false, skipTraversal: true);

  // Where focus was before the popover took it, given back when it closes.
  FocusNode? _focusBeforeOpen;

  bool get _isOpen => _portal.isShowing;

  @override
  void dispose() {
    _scope.dispose();
    _triggerFocus.dispose();
    super.dispose();
  }

  void _togglePopover() {
    if (_isOpen) {
      _closePopover();
    } else {
      _openPopover();
    }
  }

  void _openPopover() {
    if (_isOpen) return;
    _focusBeforeOpen = FocusManager.instance.primaryFocus;
    setState(_portal.show);
    // After the frame that builds the scope. A field inside that asked for
    // focus itself (autofocus, or a request of its own) is not overridden:
    // a scope that already holds focus is left alone, and a later request
    // wins over this one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isOpen && !_scope.hasFocus) _scope.requestFocus();
    });
  }

  void _closePopover() {
    if (!_isOpen || !mounted) return;
    final previous = _focusBeforeOpen;
    _focusBeforeOpen = null;
    // Only while focus is still in here. If something the popover did has
    // already moved it - a dialog it opened, a field it handed off to -
    // pulling it back would undo that. Synchronous, before the hide: a
    // dialog an item opens asks for focus later, when its route builds, and
    // still wins.
    if (_scope.hasFocus &&
        previous != null &&
        (previous.context?.mounted ?? false) &&
        previous.canRequestFocus) {
      previous.requestFocus();
    }
    setState(_portal.hide);
  }

  // Focus that leaves the popover for somewhere else on the same page (Ctrl+F
  // to the sidebar search, say) closes it, as a click there would: an open
  // popover that no longer has focus could not hear its Esc either. Focus
  // that goes to another route (a dialog or menu opened from inside it), or
  // nowhere (the window deactivated), is not a decision to leave, and the
  // popover stays.
  void _onScopeFocusChange(bool hasFocus) {
    if (hasFocus || !_isOpen || _triggerFocus.hasFocus) return;
    final now = FocusManager.instance.primaryFocus;
    final page = _scope.enclosingScope;
    if (now == null || page == null) return;
    if (now == page || now.ancestors.contains(page)) _closePopover();
  }

  Widget _buildOverlay(BuildContext context, OverlayChildLayoutInfo info) {
    final trigger = MatrixUtils.transformRect(
        info.childPaintTransform, Offset.zero & info.childSize);
    // Esc closes the popover from anywhere inside it - which, with focus
    // moved in on open, is wherever focus is while it is open. The portal
    // builds this content BELOW the trigger in the widget tree, so its key
    // events bubble through the page's own shortcuts - where Esc closes the
    // Library. The old OverlayEntry sat outside them. Unclaimed here, Esc
    // typed into the search popover's field closed the Library behind a
    // popover that stayed open.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _closePopover,
      },
      child: FocusScope(
        node: _scope,
        onFocusChange: _onScopeFocusChange,
        child: Stack(
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
        ),
      ),
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
      // Esc with focus on the TRIGGER while the popover is open. Opening
      // moves focus inside, but after Enter or Space it is still on the
      // trigger until the popover's first frame is up. The overlay's binding
      // only hears keys from focus inside the popover, so this Esc went on up
      // to the page's shortcuts: the Library behind closed and the popover
      // stayed open. Claimed only while open; a closed popover's trigger
      // leaves Esc to the page. No focus or Tab stop of its own: it hears
      // the trigger's keys.
      child: Focus(
        focusNode: _triggerFocus,
        onKeyEvent: _onTriggerKey,
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
      ),
    );
  }

  KeyEventResult _onTriggerKey(FocusNode node, KeyEvent event) {
    if (!_isOpen ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    _closePopover();
    return KeyEventResult.handled;
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
///   keeps a right-aligned popover from opening off the left of a narrow one
///   - except along an axis the trigger itself has scrolled out of the
///   window by, where it follows the trigger out instead, on the side of it
///   that faces the window.
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
    final flipped = _aligned(
      childSize,
      Alignment(targetAnchor.x, -targetAnchor.y),
      Alignment(followerAnchor.x, -followerAnchor.y),
      Offset(offset.dx, -offset.dy),
    );

    // A trigger scrolled clean out of the window takes its popover with it.
    // Held inside the edge instead, the popover hung there over whatever had
    // scrolled in, attached to nothing. Strict comparisons, so a trigger
    // touching the edge, or one with no size yet, still counts as on screen.
    //
    // Per axis. A trigger gone off the top is still where it was across, so
    // the slide that held the popover inside a narrow window stays: dropping
    // both clamps threw the popover sideways in the frame the trigger left.
    final goneAbove = trigger.bottom < 0;
    final goneBelow = trigger.top > size.height;
    final goneAcross = trigger.right < 0 || trigger.left > size.width;

    bool fitsVertically(Offset p) =>
        p.dy >= margin && p.dy + childSize.height <= size.height - margin;
    if (goneAbove || goneBelow) {
      // On the trigger's side facing the window, which is the side it was on
      // as the trigger left: near an edge, the side with room is the one away
      // from it. A trigger gone off the bottom used to drop its popover back
      // below it, out of the window in one frame instead of following it.
      final flippedFacesWindow =
          goneAbove ? flipped.dy > position.dy : flipped.dy < position.dy;
      if (flippedFacesWindow) position = flipped;
    } else if (!fitsVertically(position) && fitsVertically(flipped)) {
      position = flipped;
    }

    double inside(double value, double extent, double available) =>
        value.clamp(margin, math.max(margin, available - margin - extent));
    return Offset(
      goneAcross
          ? position.dx
          : inside(position.dx, childSize.width, size.width),
      goneAbove || goneBelow
          ? position.dy
          : inside(position.dy, childSize.height, size.height),
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
