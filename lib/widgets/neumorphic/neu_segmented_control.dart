import 'package:flutter/material.dart';
import '../../theme/neu_theme.dart';

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
    final selectedIndex = keys.indexOf(selectedValue);

    return SizedBox(
      height: height,
      child: Container(
        decoration: NeuTheme.sunkenDecoration(isDark, radius: height / 2)
            .copyWith(color: NeuTheme.wellSurface(isDark)),
        padding: padding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final count = keys.length;
            final itemWidth = count > 0 ? constraints.maxWidth / count : 0.0;

            return Stack(
              children: [
                if (selectedIndex >= 0 && itemWidth > 0)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    left: selectedIndex * itemWidth,
                    top: 0,
                    bottom: 0,
                    width: itemWidth,
                    child: Container(
                      // Same recipe as every other raised surface, just with a
                      // tighter blur so it reads inside the small control.
                      decoration: NeuTheme.raisedDecoration(
                        isDark,
                        radius: (height - 8) / 2,
                      ).copyWith(
                        boxShadow: [
                          BoxShadow(
                            color: NeuTheme.shadow(isDark)
                                .withValues(alpha: isDark ? 0.6 : 0.8),
                            offset: const Offset(3, 3),
                            blurRadius: 6,
                          ),
                          BoxShadow(
                            color: NeuTheme.highlight(isDark)
                                .withValues(alpha: isDark ? 0.05 : 0.9),
                            offset: const Offset(-3, -3),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
                Row(
                  children: keys.map((key) {
                    final isSelected = key == selectedValue;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => onValueChanged(key),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Container(
                            color: Colors.transparent,
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut,
                                style: TextStyle(
                                  color: isSelected
                                      ? NeuTheme.text(isDark)
                                      : NeuTheme.subtext(isDark),
                                  fontWeight:
                                      isSelected ? FontWeight.bold : FontWeight.w500,
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
              ],
            );
          },
        ),
      ),
    );
  }
}
