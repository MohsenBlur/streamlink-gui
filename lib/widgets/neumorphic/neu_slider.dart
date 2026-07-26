import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'neu_container.dart';

class NeuSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final Color? activeColor;
  final double height;

  const NeuSlider({
    Key? key,
    required this.value,
    required this.onChanged,
    this.min = 0.0,
    this.max = 1.0,
    this.activeColor,
    this.height = 14.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = activeColor ?? theme.primaryColor;

    final normalized = ((value - min) / (max - min)).clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        final thumbSize = height + 10;
        final thumbPosition = normalized * (trackWidth - thumbSize);

        return GestureDetector(
          onHorizontalDragUpdate: (details) {
            final dx = details.localPosition.dx;
            final newNorm = (dx / trackWidth).clamp(0.0, 1.0);
            onChanged(min + newNorm * (max - min));
          },
          onTapDown: (details) {
            final dx = details.localPosition.dx;
            final newNorm = (dx / trackWidth).clamp(0.0, 1.0);
            onChanged(min + newNorm * (max - min));
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SizedBox(
              height: thumbSize + 4,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  // Sunken Track Slot
                  NeuContainer(
                    width: trackWidth,
                    height: height,
                    style: NeuStyle.sunken,
                    borderRadius: BorderRadius.circular(height / 2),
                    color: isDark ? const Color(0xFF13151A) : const Color(0xFFD8E0EB),
                    depth: 3.0,
                    child: Stack(
                      children: [
                        // Active Glowing Fill Bar
                        FractionallySizedBox(
                          widthFactor: normalized,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  accent.withOpacity(0.7),
                                  accent,
                                ],
                              ),
                              borderRadius: BorderRadius.circular(height / 2),
                              boxShadow: [
                                BoxShadow(
                                  color: accent.withOpacity(0.5),
                                  blurRadius: 6,
                                )
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 3D Sphere-Like Tactile Thumb Knob
                  Positioned(
                    left: thumbPosition,
                    child: NeuContainer(
                      width: thumbSize,
                      height: thumbSize,
                      isCircle: true,
                      style: NeuStyle.raised,
                      depth: 4.0,
                      color: isDark ? const Color(0xFF2A2E3B) : Colors.white,
                      border: Border.all(
                        color: isDark ? Colors.white.withOpacity(0.12) : Colors.white,
                        width: 1.5,
                      ),
                      child: Center(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent,
                            boxShadow: [
                              BoxShadow(
                                color: accent.withOpacity(0.8),
                                blurRadius: 4,
                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class NeuRotaryKnob extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final double size;
  final String label;

  const NeuRotaryKnob({
    Key? key,
    required this.value,
    required this.onChanged,
    this.min = 100.0,
    this.max = 500.0,
    this.size = 52.0,
    this.label = 'Zoom',
  }) : super(key: key);

  @override
  State<NeuRotaryKnob> createState() => _NeuRotaryKnobState();
}

class _NeuRotaryKnobState extends State<NeuRotaryKnob> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.primaryColor;

    final normalized = ((widget.value - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);
    final angle = (normalized * 270.0 - 135.0) * (math.pi / 180.0);

    return GestureDetector(
      onVerticalDragUpdate: (details) {
        final delta = -details.delta.dy * (widget.max - widget.min) / 150.0;
        final newValue = (widget.value + delta).clamp(widget.min, widget.max);
        widget.onChanged(newValue);
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: Tooltip(
          message: '${widget.label}: ${widget.value.toInt()}px',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeuContainer(
                width: widget.size,
                height: widget.size,
                isCircle: true,
                style: NeuStyle.raised,
                depth: 4.0,
                color: isDark ? const Color(0xFF222630) : const Color(0xFFE6ECEF),
                child: Transform.rotate(
                  angle: angle,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Circular indicator dots perimeter
                      Positioned(
                        top: 6,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent,
                            boxShadow: [
                              BoxShadow(
                                color: accent.withOpacity(0.8),
                                blurRadius: 4,
                              )
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
