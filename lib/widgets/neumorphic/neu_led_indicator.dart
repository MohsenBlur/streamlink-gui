import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    if (widget.isLive && widget.isPulsing) {
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      )..repeat(reverse: true);
      _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _controller!, curve: Curves.easeInOut),
      );
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
        ? (widget.activeColor ?? const Color(0xFF00E6A5)) // Neon Mint-Cyan
        : (widget.inactiveColor ?? (isDark ? const Color(0xFF4A5568) : const Color(0xFFA0AEC0)));

    Widget ledContent = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.3),
          radius: 0.8,
          colors: [
            Colors.white.withOpacity(widget.isLive ? 0.9 : 0.4),
            color,
            color.withOpacity(0.8),
          ],
        ),
        boxShadow: widget.isLive
            ? [
                BoxShadow(
                  color: color.withOpacity(0.8),
                  blurRadius: widget.size * 0.8,
                  spreadRadius: widget.size * 0.2,
                ),
                BoxShadow(
                  color: color.withOpacity(0.4),
                  blurRadius: widget.size * 1.5,
                  spreadRadius: widget.size * 0.5,
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 2,
                  offset: const Offset(1, 1),
                ),
              ],
      ),
    );

    if (widget.isLive && widget.isPulsing && _pulseAnimation != null) {
      return AnimatedBuilder(
        animation: _pulseAnimation!,
        builder: (context, child) {
          return Opacity(
            opacity: _pulseAnimation!.value,
            child: ledContent,
          );
        },
      );
    }

    return ledContent;
  }
}
