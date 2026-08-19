import 'package:flutter/material.dart';

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
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  // The overlay builder reads widget.* through this State, so rebuilding the
  // entry on prop changes keeps an open popover's content live. Without this
  // the content was frozen at open time (the header stats popover never
  // refreshed while open).
  @override
  void didUpdateWidget(InteractivePopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    _overlayEntry?.markNeedsBuild();
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

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            // Full-screen barrier to dismiss popover when clicking outside
            GestureDetector(
              onTap: _closePopover,
              behavior: HitTestBehavior.translucent,
              child: const SizedBox.expand(),
            ),
            // Positioned popover anchored to the trigger widget
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: widget.targetAnchor,
              followerAnchor: widget.followerAnchor,
              offset: widget.offset,
              child: Material(
                color: Colors.transparent,
                child: widget.popoverBuilder != null
                    ? widget.popoverBuilder!(context, _closePopover)
                    : widget.popover!,
              ),
            ),
          ],
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
    setState(() {
      _isOpen = true;
    });
  }

  void _closePopover() {
    if (!_isOpen) return;
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() {
        _isOpen = false;
      });
    }
  }

  @override
  void dispose() {
    _closePopover();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _togglePopover,
        behavior: HitTestBehavior.opaque,
        child: widget.child,
      ),
    );
  }
}
