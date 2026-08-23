import 'package:flutter/material.dart';
import '../../theme/neu_theme.dart';
import '../shell/motion.dart';

class NeuLedIndicator extends StatefulWidget {
  /// The dimmest a live LED ever gets, as a fraction of full brightness.
  ///
  /// Public because the contract is about what the eye sees, so the test that
  /// enforces it samples a real cycle rather than reading the tween.
  static const double pulseFloor = 0.75;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not initState: _syncAnimation reads MediaQuery for the reduced-motion
    // setting, which is not available until dependencies are resolved. This
    // hook also fires if the user changes that setting while the app runs.
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
    // A live dot that half-vanishes twice a second is exactly what the
    // reduced-motion setting exists to stop.
    if (_shouldPulse && !NeuMotion.reduced(context)) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      );
      // 0.75, not 0.4. The FadeTransition wraps the whole indicator - core as
      // well as bloom - so the floor is how dim the lamp itself gets, not just
      // its glow. At 0.4 a lit LED spends part of every cycle looking unlit,
      // which reads as flickering rather than as a heartbeat; `NeuBadge` had
      // the same defect and fixed it at 0.75 with the same reasoning, and this
      // one was left behind. On a graphite panel it reads as a fault.
      _pulseAnimation ??=
          Tween<double>(begin: NeuLedIndicator.pulseFloor, end: 1.0).animate(
        CurvedAnimation(parent: _controller!, curve: Curves.easeInOut),
      );
      _controller!.repeat(reverse: true);
    } else {
      _controller?.stop();
      // Settle bright rather than wherever the tween happened to be, so a
      // stopped LED does not sit at 40% and read as offline.
      _controller?.value = 1.0;
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
