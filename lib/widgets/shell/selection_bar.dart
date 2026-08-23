import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../neumorphic/neu_button.dart';
import '../neumorphic/neu_icon_action.dart';
import '../neumorphic/neu_progress.dart';
import '../interactive_popover.dart';

/// One bulk action offered while a selection is active.
class SelectionAction {
  const SelectionAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tone = SelectionTone.neutral,
  });

  final String label;
  final IconData icon;

  /// Null renders the action disabled - used while nothing is selected.
  final VoidCallback? onPressed;
  final SelectionTone tone;
}

enum SelectionTone { neutral, accent, positive, destructive }

/// The toolbar shown while a multi-selection is active.
///
/// It REPLACES the normal toolbar rather than growing out of it, which is the
/// whole point. The old version appended four labelled buttons, a count, a
/// progress ring and two icon buttons to the row that already held the display
/// controls, with no compact branch anywhere - so below roughly 1100px it
/// simply overflowed. A stopgap Wrap stopped the overflow stripes but left a
/// toolbar that reflowed to three lines on a narrow window.
///
/// Replacing bounds the width budget: whatever the window size, this bar holds
/// a count, two selection controls and the actions, and the actions collapse
/// into an overflow menu when they do not fit.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    Key? key,
    required this.selectedCount,
    required this.onSelectAllVisible,
    required this.onClear,
    required this.onExit,
    required this.actions,
    this.busy = false,
    this.busyLabel,
  }) : super(key: key);

  final int selectedCount;
  final VoidCallback onSelectAllVisible;
  final VoidCallback onClear;

  /// Leaves selection mode entirely and returns the normal toolbar.
  final VoidCallback onExit;

  final List<SelectionAction> actions;
  final bool busy;
  final String? busyLabel;

  Color _foreground(SelectionTone tone, bool isDark) => switch (tone) {
        SelectionTone.neutral => NeuTheme.text(isDark),
        SelectionTone.accent => themeNotifier.accentInk,
        SelectionTone.positive => NeuTheme.liveText(isDark),
        SelectionTone.destructive => NeuTheme.dangerText(isDark),
      };

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    return LayoutBuilder(builder: (context, constraints) {
      // Measured from the widest label set: the count and the two selection
      // controls need ~300px, each labelled action ~130.
      final full = constraints.maxWidth >= 300 + actions.length * 130;

      return Container(
        padding: const EdgeInsets.symmetric(
            horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
        decoration: NeuTheme.raisedDecoration(
          isDark,
          radius: NeuRadius.r12,
          border: Border.all(
              color: themeNotifier.primaryColor.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            NeuIconAction(
              icon: Icons.close,
              tooltip: 'Leave selection mode (Esc)',
              size: NeuActionSize.sm,
              onPressed: onExit,
            ),
            const SizedBox(width: NeuSpace.s12),
            Text(
              selectedCount == 0
                  ? 'Select videos'
                  : '$selectedCount selected',
              style: NeuType.label(isDark),
            ),
            const SizedBox(width: NeuSpace.s12),
            _textButton('All', onSelectAllVisible, isDark),
            const SizedBox(width: NeuSpace.s6),
            _textButton('None', selectedCount == 0 ? null : onClear, isDark),
            const Spacer(),
            if (busy) ...[
              const NeuProgressRing(
                  size: NeuProgressRingSize.xs, semanticLabel: 'Working'),
              const SizedBox(width: NeuSpace.s8),
              Text(busyLabel ?? 'Working...', style: NeuType.caption(isDark)),
            ] else if (full)
              for (final action in actions) ...[
                const SizedBox(width: NeuSpace.s8),
                _actionButton(action, isDark),
              ]
            else
              _overflow(context, isDark),
          ],
        ),
      );
    });
  }

  Widget _textButton(String label, VoidCallback? onPressed, bool isDark) {
    return NeuButton(
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(
          horizontal: NeuSpace.s12, vertical: NeuSpace.s6),
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      child: Text(label, style: NeuType.captionMetrics),
    );
  }

  Widget _actionButton(SelectionAction action, bool isDark) {
    final ink = _foreground(action.tone, isDark);
    return NeuButton(
      onPressed: action.onPressed,
      padding: const EdgeInsets.symmetric(
          horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(action.icon, size: 15, color: ink),
          const SizedBox(width: NeuSpace.s6),
          Text(action.label, style: NeuType.captionStrong(isDark, color: ink)),
        ],
      ),
    );
  }

  /// Narrow windows: the actions move into a popover rather than wrapping the
  /// bar onto a second and third line.
  Widget _overflow(BuildContext context, bool isDark) {
    return InteractivePopover(
      popoverBuilder: (context, close) => Container(
        width: 220,
        padding: const EdgeInsets.all(NeuSpace.s6),
        decoration: NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final action in actions)
              Padding(
                padding: const EdgeInsets.only(bottom: NeuSpace.s4),
                child: NeuButton(
                  onPressed: action.onPressed == null
                      ? null
                      : () {
                          close();
                          action.onPressed!();
                        },
                  padding: const EdgeInsets.symmetric(
                      horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                  borderRadius: BorderRadius.circular(NeuRadius.r8),
                  child: Row(
                    children: [
                      Icon(action.icon,
                          size: 15, color: _foreground(action.tone, isDark)),
                      const SizedBox(width: NeuSpace.s8),
                      Text(action.label,
                          style: NeuType.caption(isDark,
                              color: _foreground(action.tone, isDark))),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      child: NeuButton(
        onPressed: () {},
        padding: const EdgeInsets.symmetric(
            horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
        borderRadius: BorderRadius.circular(NeuRadius.r8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Actions', style: NeuType.captionStrong(isDark)),
            const SizedBox(width: NeuSpace.s4),
            Icon(Icons.arrow_drop_down,
                size: 16, color: NeuTheme.subtext(isDark)),
          ],
        ),
      ),
    );
  }
}
