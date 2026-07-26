import 'package:flutter/material.dart';
import 'neu_container.dart';

class NeuSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final double width;
  final double height;
  final Color? activeColor;

  const NeuSwitch({
    Key? key,
    required this.value,
    required this.onChanged,
    this.width = 50.0,
    this.height = 26.0,
    this.activeColor,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = activeColor ?? theme.primaryColor;

    final knobSize = height - 4;

    return GestureDetector(
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: width,
          height: height,
          child: NeuContainer(
            style: NeuStyle.sunken,
            borderRadius: BorderRadius.circular(height / 2),
            color: value
                ? accent.withOpacity(isDark ? 0.35 : 0.25)
                : (isDark ? const Color(0xFF13151A) : const Color(0xFFD8E0EB)),
            depth: 3.0,
            padding: const EdgeInsets.all(2.0),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  left: value ? (width - knobSize - 4) : 0,
                  child: NeuContainer(
                    width: knobSize,
                    height: knobSize,
                    isCircle: true,
                    style: NeuStyle.raised,
                    depth: 3.0,
                    color: isDark ? const Color(0xFF282C38) : Colors.white,
                    border: Border.all(
                      color: value
                          ? accent.withOpacity(0.8)
                          : (isDark ? Colors.white.withOpacity(0.08) : Colors.white),
                      width: 1.0,
                    ),
                    child: Center(
                      // Micro-grip texture lines inside the toggle knob
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 1.5,
                            height: 8,
                            color: isDark ? Colors.white24 : Colors.black26,
                          ),
                          const SizedBox(width: 2),
                          Container(
                            width: 1.5,
                            height: 8,
                            color: isDark ? Colors.white24 : Colors.black26,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
