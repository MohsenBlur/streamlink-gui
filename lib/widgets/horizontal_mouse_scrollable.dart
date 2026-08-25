import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/neu_theme.dart';

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
      onPointerSignal: (pointerSignal) {
        if (pointerSignal is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(pointerSignal, (event) {
            if (event is PointerScrollEvent && _internalController.hasClients) {
              final delta = event.scrollDelta.dy != 0.0
                  ? event.scrollDelta.dy
                  : event.scrollDelta.dx;
              if (delta != 0.0) {
                final newOffset = (_internalController.offset + delta).clamp(
                  0.0,
                  _internalController.position.maxScrollExtent,
                );
                _internalController.jumpTo(newOffset);
              }
            }
          });
        }
      },
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
