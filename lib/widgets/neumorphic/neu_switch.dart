import 'package:flutter/material.dart';
import 'neu_container.dart';
import '../../theme/neu_theme.dart';
import 'neu_focusable.dart';

/// Neumorphic toggle switch.
///
/// Adopted in place of Material [Switch], which was the strongest visual alien
/// in the app's chrome. The original implementation here was dead code with a
/// knob that overflowed its own padded track; the geometry below is computed
/// against the padded content box so nothing clips.
class NeuSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double width;
  final double height;
  final Color? activeColor;

  const NeuSwitch({
    Key? key,
    required this.value,
    required this.onChanged,
    this.width = 46.0,
    this.height = 24.0,
    this.activeColor,
  }) : super(key: key);

  static const double _pad = 2.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = activeColor ?? theme.primaryColor;
    final enabled = onChanged != null;

    // Knob sized to the track's padded interior.
    final knobSize = height - 2 * _pad - 2;
    final knobTravel = width - 2 * _pad - knobSize - 2;

    final Color trackColor = !enabled
        ? NeuTheme.wellSurface(isDark)
        : value
            ? accent.withValues(alpha: isDark ? 0.35 : 0.25)
            : NeuTheme.wellSurface(isDark);

    return NeuFocusable(
      onActivate: enabled ? () => onChanged!(!value) : null,
      toggled: value,
      focusRadius: height / 2,
      child: GestureDetector(
      onTap: enabled ? () => onChanged!(!value) : null,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: width,
          height: height,
          decoration: NeuTheme.sunkenDecoration(isDark, radius: height / 2),
          // The tint is painted inside the sunken shell so the inset shadows
          // stay visible over it.
          child: Container(
            decoration: BoxDecoration(
              color: trackColor,
              borderRadius: BorderRadius.circular(height / 2),
            ),
            padding: const EdgeInsets.all(_pad),
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  left: value ? knobTravel : 0,
                  top: 1,
                  child: NeuContainer(
                    width: knobSize,
                    height: knobSize,
                    isCircle: true,
                    style: NeuStyle.raised,
                    depth: 2.0,
                    blurRadius: 4.0,
                    color: isDark ? const Color(0xFF2A2E3B) : Colors.white,
                    border: Border.all(
                      color: !enabled
                          ? NeuTheme.disabledText(isDark).withValues(alpha: 0.4)
                          : value
                              ? accent.withValues(alpha: 0.8)
                              : NeuTheme.highlight(isDark)
                                  .withValues(alpha: isDark ? 0.12 : 0.9),
                      width: 1.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}
