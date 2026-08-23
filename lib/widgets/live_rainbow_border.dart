import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'shell/motion.dart';

class LiveRainbowBorder extends StatefulWidget {
  final Widget child;
  final double strokeWidth;
  final double borderRadius;
  final Duration duration;
  final bool animate;

  /// Freeze the ring after this long (a static frame keeps painting). The
  /// sidebar's newly-live window used to rely on unrelated rebuilds to stop
  /// the animation; this makes the cutoff deterministic.
  final Duration? stopAfter;

  const LiveRainbowBorder({
    Key? key,
    required this.child,
    this.strokeWidth = 2.0,
    this.borderRadius = 8.0,
    this.duration = const Duration(seconds: 4),
    this.animate = true,
    this.stopAfter,
  }) : super(key: key);

  @override
  State<LiveRainbowBorder> createState() => _LiveRainbowBorderState();
}

class _LiveRainbowBorderState extends State<LiveRainbowBorder> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  Timer? _stopTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery is not safe to read in initState, and this is the lifecycle
    // hook that also fires if the user changes the setting while running.
    if (NeuMotion.reduced(context)) {
      _controller.stop();
    } else if (widget.animate && !_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    if (widget.animate) {
      _controller.repeat();
    }
    _scheduleStop();
  }

  void _scheduleStop() {
    _stopTimer?.cancel();
    final stopAfter = widget.stopAfter;
    if (stopAfter == null || !widget.animate) return;
    if (stopAfter <= Duration.zero) {
      _controller.stop();
      return;
    }
    _stopTimer = Timer(stopAfter, () {
      if (mounted) _controller.stop();
    });
  }

  @override
  void didUpdateWidget(covariant LiveRainbowBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate) {
      if (widget.animate) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
      if (widget.animate) {
        _controller.repeat();
      }
    }
    if (widget.stopAfter != oldWidget.stopAfter ||
        widget.animate != oldWidget.animate) {
      _scheduleStop();
    }
  }

  @override
  void dispose() {
    _stopTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary isolates the 60fps ring from the subtree it decorates;
    // the prebuilt child is actually USED now (the old builder rebuilt the
    // whole child subtree every animation frame and ignored the cached one).
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _RainbowBorderPainter(
              rotation: _controller.value * 2 * math.pi,
              strokeWidth: widget.strokeWidth,
              borderRadius: widget.borderRadius,
            ),
            child: child,
          );
        },
        child: Padding(
          padding: EdgeInsets.all(widget.strokeWidth),
          child: widget.child,
        ),
      ),
    );
  }
}

class _RainbowBorderPainter extends CustomPainter {
  final double rotation;
  final double strokeWidth;
  final double borderRadius;

  _RainbowBorderPainter({
    required this.rotation,
    required this.strokeWidth,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final colors = <Color>[
      // Intentional: the decorative rainbow palette itself.
      const Color(0xFFFF007F), // Hot pink
      const Color(0xFF9146FF), // Purple
      const Color(0xFF00F2FE), // Cyan
      const Color(0xFF4CAF50), // Green
      const Color(0xFFFFC107), // Yellow
      const Color(0xFFFF007F), // Loop back
    ];

    paint.shader = SweepGradient(
      colors: colors,
      transform: GradientRotation(rotation),
    ).createShader(rect);

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _RainbowBorderPainter oldDelegate) {
    return oldDelegate.rotation != rotation ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.borderRadius != borderRadius;
  }
}
