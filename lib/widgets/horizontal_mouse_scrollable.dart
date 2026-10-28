import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/neu_theme.dart';

/// Where a mouse wheel over a horizontal strip takes it, or null when the
/// wheel would not move it at all.
///
/// The null is the point. The pointer-signal resolver is first-come: whoever
/// registers for a wheel event first is the only one that sees it, and the
/// strip sits deeper in the hit test than the page scroller around it, so it
/// always registers first. It used to register unconditionally and work out
/// whether it could scroll afterwards - so a chip row that fitted, or one
/// already at its end, swallowed the wheel and did nothing with it. With the
/// pointer resting on the VOD grid's game chips the grid underneath simply
/// would not scroll. A null here means "not mine": the strip stays out of the
/// resolver and the page gets the event.
///
/// Vertical wheel travel is read as horizontal (that is the whole job of the
/// strip); a horizontal delta is used only when there is no vertical one.
/// Same clamp as the framework's own `Scrollable` pointer handling.
double? horizontalWheelTarget({
  required double offset,
  required double minExtent,
  required double maxExtent,
  required Offset scrollDelta,
}) {
  final delta = scrollDelta.dy != 0.0 ? scrollDelta.dy : scrollDelta.dx;
  if (delta == 0.0) return null;
  final target = (offset + delta).clamp(minExtent, maxExtent).toDouble();
  return target == offset ? null : target;
}

/// Turns the mouse wheel into horizontal travel for the strip [controller]
/// drives - claiming the event only when it will actually move the strip.
///
/// Shared by [HorizontalMouseScrollable] and the sidebar's avatar rail, which
/// had its own copy of the same claim-everything handler.
void routeWheelToHorizontalStrip(
    PointerSignalEvent signal, ScrollController controller) {
  if (signal is! PointerScrollEvent || !controller.hasClients) return;
  double? targetFor(PointerScrollEvent event) {
    final position = controller.position;
    return horizontalWheelTarget(
      offset: position.pixels,
      minExtent: position.minScrollExtent,
      maxExtent: position.maxScrollExtent,
      scrollDelta: event.scrollDelta,
    );
  }

  if (targetFor(signal) == null) return;
  GestureBinding.instance.pointerSignalResolver.register(signal, (event) {
    // Recomputed at dispatch rather than captured: the resolver runs the
    // winner after the whole hit-test path has been offered the event.
    if (event is! PointerScrollEvent || !controller.hasClients) return;
    final target = targetFor(event);
    if (target != null) controller.jumpTo(target);
  });
}

/// Reusable wrapper widget that enables vertical mouse wheel scrolling
/// on horizontal lists across the application seamlessly.
///
/// Also the place where a horizontal strip's SHADOW CLEARANCE lives. Every
/// raised element casts outside its own box, and a scroll viewport clips at
/// its edge - so every strip needs interior room above, below and beside its
/// content. Hand-tuning that per site is how the filter chips got room below
/// while losing the halo above: the clearance is one definition
/// ([NeuShadowRoom.strip]) applied here by default, and a strip that truly
/// needs something else says so explicitly.
class HorizontalMouseScrollable extends StatefulWidget {
  final Widget child;
  final ScrollController? controller;

  /// Extra padding merged INSIDE the default shadow clearance.
  final EdgeInsetsGeometry? padding;

  /// Reserve [NeuShadowRoom.strip] inside the viewport's clip. On by
  /// default; opt out only for content that casts nothing.
  final bool shadowRoom;

  const HorizontalMouseScrollable({
    Key? key,
    required this.child,
    this.controller,
    this.padding,
    this.shadowRoom = true,
  }) : super(key: key);

  @override
  State<HorizontalMouseScrollable> createState() => _HorizontalMouseScrollableState();
}

class _HorizontalMouseScrollableState extends State<HorizontalMouseScrollable> {
  late ScrollController _internalController;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _internalController = widget.controller!;
    } else {
      _internalController = ScrollController();
      _ownsController = true;
    }
  }

  @override
  void didUpdateWidget(HorizontalMouseScrollable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      if (_ownsController) {
        _internalController.dispose();
      }
      if (widget.controller != null) {
        _internalController = widget.controller!;
        _ownsController = false;
      } else {
        _internalController = ScrollController();
        _ownsController = true;
      }
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _internalController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (signal) =>
          routeWheelToHorizontalStrip(signal, _internalController),
      child: SingleChildScrollView(
        controller: _internalController,
        scrollDirection: Axis.horizontal,
        padding: widget.shadowRoom
            ? (widget.padding == null
                ? NeuShadowRoom.strip
                : NeuShadowRoom.strip.add(widget.padding!))
            : widget.padding,
        physics: const BouncingScrollPhysics(),
        child: widget.child,
      ),
    );
  }
}
