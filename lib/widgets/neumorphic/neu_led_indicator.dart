import 'package:flutter/material.dart';
import '../../theme/neu_theme.dart';

class NeuLedIndicator extends StatefulWidget {
  final double size;
  final bool isLive;
  final Color? activeColor;
  final Color? inactiveColor;
  final bool isPulsing;

  const NeuLedIndicator({
    Key? key,
    this.size = 12.0,
    this.isLive = true,
    this.activeColor,
    this.inactiveColor,
    this.isPulsing = true,
  }) : super(key: key);

  @override
  State<NeuLedIndicator> createState() => _NeuLedIndicatorState();
}

class _NeuLedIndicatorState extends State<NeuLedIndicator>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _pulseAnimation;

  bool get _shouldPulse => widget.isLive && widget.isPulsing;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  // React to prop changes. Without this, a LED whose channel went live after
  // first build never started pulsing, and one whose channel went offline kept
  // pulsing forever.
  @override
  void didUpdateWidget(NeuLedIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldPulse != (oldWidget.isLive && oldWidget.isPulsing)) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (_shouldPulse) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      );
      _pulseAnimation ??= Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _controller!, curve: Curves.easeInOut),
      );
      _controller!.repeat(reverse: true);
    } else {
      _controller?.stop();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final color = widget.isLive
        ? (widget.activeColor ?? NeuTheme.live)
        : (widget.inactiveColor ??
            (isDark ? const Color(0xFF4A5568) : const Color(0xFFA0AEC0)));

    Widget ledContent = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.3),
          radius: 0.8,
          colors: [
            Colors.white.withValues(alpha: widget.isLive ? 0.9 : 0.4),
            color,
            color.withValues(alpha: 0.8),
          ],
        ),
        boxShadow: widget.isLive
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.8),
                  blurRadius: widget.size * 0.8,
                  spreadRadius: widget.size * 0.2,
                ),
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: widget.size * 1.5,
                  spreadRadius: widget.size * 0.5,
                ),
              ]
            : [
                BoxShadow(
                  color: NeuTheme.shadow(isDark).withValues(alpha: 0.5),
                  blurRadius: 2,
                  offset: const Offset(1, 1),
                ),
              ],
      ),
    );

    if (_shouldPulse && _pulseAnimation != null) {
      // FadeTransition + RepaintBoundary keep the large glow shadows
      // repainting inside an isolated layer instead of rebuilding the widget
      // every frame.
      return RepaintBoundary(
        child: FadeTransition(
          opacity: _pulseAnimation!,
          child: ledContent,
        ),
      );
    }

    return ledContent;
  }
}
