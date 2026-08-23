import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import 'neu_focusable.dart';

/// Visual size of the button face. The hit target is 40x40 regardless.
enum NeuActionSize {
  /// 28px face — dense rows, the activity popover.
  sm,

  /// 32px face — the default.
  md,

  /// 40px face — primary actions with room around them.
  lg,
}

extension on NeuActionSize {
  double get face => switch (this) {
        NeuActionSize.sm => 28,
        NeuActionSize.md => 32,
        NeuActionSize.lg => 40,
      };

  double get glyph => switch (this) {
        NeuActionSize.sm => 14,
        NeuActionSize.md => 16,
        NeuActionSize.lg => 20,
      };
}

/// What the action means, which decides its ink.
enum NeuActionTone { neutral, accent, danger, live, warning }

extension on NeuActionTone {
  Color ink(bool isDark) => switch (this) {
        NeuActionTone.neutral => NeuTheme.text(isDark),
        NeuActionTone.accent => themeNotifier.accentInk,
        NeuActionTone.danger => NeuTheme.dangerText(isDark),
        NeuActionTone.live => NeuTheme.liveText(isDark),
        NeuActionTone.warning => NeuTheme.warningText(isDark),
      };
}

/// How the face is drawn.
enum NeuActionStyle {
  /// Extruded from the surface. The default.
  raised,

  /// No decoration — for toolbars where a row of raised chips would be noisy.
  flat,

  /// A dark scrim, for buttons sitting on video artwork where the surrounding
  /// colour is unknown.
  overlay,
}

/// An icon-only button.
///
/// Replaces three sizes doing one job (28px in the activity popover, 30px in
/// the Library, 32px in the channel header) plus a scattering of bare
/// `IconButton`s, several of which set `constraints: const BoxConstraints()`
/// with zero padding and so collapsed their tap target down to the 20px glyph.
///
/// Two things are deliberately not optional:
///
/// * **[tooltip] is required.** An icon with no label and no tooltip is a
///   guess. This app leans heavily on icon-only controls and hover-reveals,
///   and a required tooltip is the cheapest possible fix for that.
/// * **The hit target is always 40x40**, expanded transparently around the
///   visual face, so a 28px button is still comfortably clickable and reachable
///   without the layout changing.
class NeuIconAction extends StatelessWidget {
  const NeuIconAction({
    Key? key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = NeuActionSize.md,
    this.tone = NeuActionTone.neutral,
    this.style = NeuActionStyle.raised,
    this.isSelected = false,
    this.disabledReason,
  }) : super(key: key);

  final IconData icon;

  /// Required. See the class comment.
  final String tooltip;

  /// Null disables the control — it stays focusable and keeps its tooltip, so
  /// a user can still find out what it would have done.
  final VoidCallback? onPressed;

  final NeuActionSize size;
  final NeuActionTone tone;
  final NeuActionStyle style;
  final bool isSelected;

  /// Appended to the tooltip when disabled, e.g. "no channel selected".
  /// A control that is dimmed without saying why is a dead end.
  final String? disabledReason;

  bool get _enabled => onPressed != null;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    final ink = !_enabled
        ? NeuTheme.disabledText(isDark)
        : isSelected
            ? themeNotifier.accentInk
            : tone.ink(isDark);

    BoxDecoration? decoration;
    switch (style) {
      case NeuActionStyle.raised:
        decoration = isSelected
            ? NeuTheme.sunkenDecoration(isDark, radius: 8)
            : NeuTheme.raisedDecoration(isDark, radius: 8);
      case NeuActionStyle.flat:
        decoration = isSelected
            ? NeuTheme.sunkenDecoration(isDark, radius: 8)
            : null;
      case NeuActionStyle.overlay:
        decoration = BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
        );
    }

    final face = Container(
      width: size.face,
      height: size.face,
      alignment: Alignment.center,
      decoration: decoration,
      child: Icon(icon, size: size.glyph, color: ink),
    );

    // The face may be smaller than the minimum comfortable target, so pad it
    // out transparently rather than growing the visual.
    const minTarget = 40.0;
    final target = SizedBox(
      width: size.face > minTarget ? size.face : minTarget,
      height: size.face > minTarget ? size.face : minTarget,
      child: Center(child: face),
    );

    Widget button = MouseRegion(
      cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: target,
      ),
    );

    button = NeuFocusable(
      onActivate: onPressed,
      semanticLabel: tooltip,
      focusRadius: 8,
      child: button,
    );

    final message = _enabled || disabledReason == null
        ? tooltip
        : '$tooltip — $disabledReason';
    return Tooltip(message: message, child: button);
  }
}
