import 'package:flutter/material.dart';
import '../../theme/neu_theme.dart';
import '../shell/motion.dart';
import 'neu_focusable.dart';

class NeuCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Color activeColor;

  /// Resolved from the ambient theme when omitted, like the sibling widgets.
  final bool? isDark;

  final double size;

  const NeuCheckbox({
    Key? key,
    required this.value,
    required this.onChanged,
    required this.activeColor,
    this.isDark,
    this.size = 18.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dark = isDark ?? Theme.of(context).brightness == Brightness.dark;
    final enabled = onChanged != null;

    final box = AnimatedContainer(
      duration: NeuMotion.duration(context, NeuMotion.fast),
      curve: NeuMotion.curve,
      width: size,
      height: size,
      decoration: value
          ? NeuTheme.raisedDecoration(
              dark,
              radius: 5,
              border: Border.all(
                color: enabled ? activeColor : NeuTheme.disabledText(dark),
                width: 1.5,
              ),
            )
          : NeuTheme.sunkenDecoration(dark, radius: 5),
      child: value
          ? Icon(
              Icons.check_rounded,
              size: size * 0.7,
              color: enabled ? activeColor : NeuTheme.disabledText(dark),
            )
          : null,
    );

    return NeuFocusable(
      onActivate: enabled ? () => onChanged!(!value) : null,
      toggled: value,
      focusRadius: 8,
      child: GestureDetector(
      onTap: enabled ? () => onChanged!(!value) : null,
      // The visual box stays small, but the interactive target must not: an
      // 18px hit area is well below a comfortable click/touch minimum.
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(child: box),
        ),
      ),
      ),
    );
  }
}
