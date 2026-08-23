import 'package:flutter/material.dart';
import '../../theme/neu_theme.dart';
import 'neu_focusable.dart';

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
    this.padding = const EdgeInsets.all(NeuSpace.s4),
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
        // The `.copyWith(color: wellSurface)` that used to be here was a
        // no-op: `sunken()` has defaulted its base to the well since the
        // commit that fixed NeuSwitch's invisible off-track. It was a leftover
        // from when the default was the panel colour.
        decoration: NeuTheme.sunkenDecoration(isDark, radius: height / 2),
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
                      // The hand-written stack this replaces was not "a
                      // tighter blur", as its comment claimed - Offset(3, 3)
                      // at blurRadius 6 is exactly `depth: NeuElevation.d2`,
                      // since blurFor(d) is d * 2. Saying so lets the material
                      // own the light model.
                      //
                      // It also carried its own shadow alphas, which the
                      // palette now supplies. Light mode is unchanged; the
                      // dark thumb's highlight rises from 0.05 to 0.50. That
                      // is deliberate: a per-call shadow override would be the
                      // one place in the app able to paint a shadow the active
                      // material never declared.
                      decoration: NeuTheme.raised(
                        isDark,
                        radius: (height - 8) / 2,
                        depth: NeuElevation.d2,
                      ),
                    ),
                  ),
                Row(
                  children: keys.map((key) {
                    final isSelected = key == selectedValue;
                    return Expanded(
                      child: NeuFocusable(
                        onActivate: () => onValueChanged(key),
                        focusRadius: 10,
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
                                style: isSelected
                                    ? NeuType.headingSm(isDark)
                                    : NeuType.body(isDark,
                                        color: NeuTheme.subtext(isDark)),
                                child: children[key]!,
                              ),
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
