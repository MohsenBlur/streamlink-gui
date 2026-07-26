import 'package:flutter/material.dart';
import 'neu_container.dart';

class NeuSegmentedControl<T> extends StatelessWidget {
  final Map<T, Widget> children;
  final T selectedValue;
  final ValueChanged<T> onValueChanged;
  final double height;
  final EdgeInsetsGeometry padding;

  const NeuSegmentedControl({
    Key? key,
    required this.children,
    required this.selectedValue,
    required this.onValueChanged,
    this.height = 42.0,
    this.padding = const EdgeInsets.all(4.0),
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final keys = children.keys.toList();

    return SizedBox(
      height: height,
      child: NeuContainer(
        style: NeuStyle.sunken,
        borderRadius: BorderRadius.circular(height / 2),
        padding: padding,
        depth: 4.0,
        color: isDark ? const Color(0xFF13151A) : const Color(0xFFD8E0EB),
        child: Row(
          children: keys.map((key) {
            final isSelected = key == selectedValue;
            return Expanded(
              child: GestureDetector(
                onTap: () => onValueChanged(key),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    decoration: isSelected
                        ? BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                isDark ? const Color(0xFF2B303C) : Colors.white,
                                isDark ? const Color(0xFF222630) : const Color(0xFFE8EEF5),
                              ],
                            ),
                            borderRadius: BorderRadius.circular((height - 8) / 2),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withOpacity(0.08)
                                  : Colors.white.withOpacity(0.9),
                              width: 1.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: isDark
                                    ? Colors.black.withOpacity(0.6)
                                    : const Color(0xFFA3B1C6).withOpacity(0.8),
                                offset: const Offset(3, 3),
                                blurRadius: 6,
                              ),
                              BoxShadow(
                                color: isDark
                                    ? Colors.white.withOpacity(0.05)
                                    : Colors.white.withOpacity(0.9),
                                offset: const Offset(-3, -3),
                                blurRadius: 6,
                              ),
                            ],
                          )
                        : null,
                    child: Center(
                      child: DefaultTextStyle(
                        style: TextStyle(
                          color: isSelected
                              ? (isDark ? Colors.white : const Color(0xFF2D3748))
                              : (isDark ? const Color(0xFF8A96A6) : const Color(0xFF718096)),
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          fontSize: 13,
                        ),
                        child: children[key]!,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
