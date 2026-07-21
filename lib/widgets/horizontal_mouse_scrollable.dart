import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Reusable wrapper widget that enables vertical mouse wheel scrolling
/// on horizontal lists across the application seamlessly.
class HorizontalMouseScrollable extends StatefulWidget {
  final Widget child;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;

  const HorizontalMouseScrollable({
    Key? key,
    required this.child,
    this.controller,
    this.padding,
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
        padding: widget.padding,
        physics: const BouncingScrollPhysics(),
        child: widget.child,
      ),
    );
  }
}
