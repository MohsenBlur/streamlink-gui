import 'package:flutter/material.dart';
import '../../theme/neu_theme.dart';

class NeuCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final Color activeColor;
  final bool isDark;
  final double size;

  const NeuCheckbox({
    Key? key,
    required this.value,
    required this.onChanged,
    required this.activeColor,
    required this.isDark,
    this.size = 18.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged != null ? () => onChanged!(!value) : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: size,
          height: size,
          decoration: value
              ? NeuTheme.raisedDecoration(
                  isDark,
                  radius: 5,
                  border: Border.all(color: activeColor, width: 1.5),
                )
              : NeuTheme.sunkenDecoration(
                  isDark,
                  radius: 5,
                ),
          child: value
              ? Icon(
                  Icons.check_rounded,
                  size: size * 0.7,
                  color: activeColor,
                )
              : null,
        ),
      ),
    );
  }
}
