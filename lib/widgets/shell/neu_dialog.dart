import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../neumorphic/neu_button.dart';
import 'app_layout.dart';

/// Whether a dialog is asking or telling.
enum DialogTone {
  /// Ordinary. Confirm is the accent.
  neutral,

  /// The confirm action destroys something. Confirm is the danger colour, and
  /// the dismiss action is the safe default.
  destructive,
}

/// One action in a dialog's footer.
class NeuDialogAction {
  /// The action the dialog exists to offer.
  const NeuDialogAction.primary(this.label, this.onPressed,
      {this.isDestructive = false})
      : isPrimary = true;

  /// The way out. "Cancel" when the dialog stages edits, "Close" when it is
  /// read-only.
  const NeuDialogAction.secondary(this.label, this.onPressed)
      : isPrimary = false,
        isDestructive = false;

  final String label;

  /// Null renders the action disabled - used while a form is invalid.
  final VoidCallback? onPressed;

  final bool isPrimary;
  final bool isDestructive;
}

/// The shared dialog shell.
///
/// The app had 17 dialogs and no shell at all: each hand-rolled its own shape,
/// background and actions. Three different accessors were used for the same
/// intended colour - `themeNotifier.surfaceColor`, `NeuTheme.surface(isDark)`
/// and, in one case, `themeNotifier.backgroundColor`, which made that dialog a
/// visibly different colour from its siblings. Only 2 of the 17 had a border,
/// and those two disagreed on its alpha. The header appeared in four different
/// arrangements, and the dismiss action was variously "Cancel", "Close",
/// "Keep Running", "Remind Me Later", "Skip setup" or a bare X.
///
/// Two deliberate constraints:
///
/// * [dismissible] is REQUIRED with no default. Whether a dialog can be
///   dismissed by clicking away is a real decision - the update-in-progress
///   dialog must not be, or a user can walk away mid-update - and a default
///   would let that decision be made by accident.
/// * Dialogs get a flat sheet treatment rather than neumorphic depth. They sit
///   on a scrim, and neumorphism's premise is extrusion FROM the surface
///   behind; a white bevel bleeding onto a black scrim reads as a rendering
///   artefact, and the scrim swallows the dark shadow anyway.
class NeuDialog extends StatelessWidget {
  const NeuDialog({
    Key? key,
    required this.title,
    required this.content,
    this.icon,
    this.subtitle,
    this.actions = const <NeuDialogAction>[],
    this.leadingActions = const <Widget>[],
    this.width,
    this.maxHeight,
    this.tone = DialogTone.neutral,
    this.scrollable = true,
  }) : super(key: key);

  final String title;
  /// The dialog body. Named `content` rather than `child` because it is one
  /// slot among several, and because `child` must come last by lint.
  final Widget content;
  final IconData? icon;
  final String? subtitle;
  final List<NeuDialogAction> actions;

  /// Rendered at the far left of the footer - a version chip, a help link.
  final List<Widget> leadingActions;

  /// Null sizes responsively. The old dialogs used a hard 520x520 and 720x650,
  /// neither of which fits the app's own 380x500 minimum window.
  final double? width;
  final double? maxHeight;

  final DialogTone tone;
  final bool scrollable;

  /// Shows [builder] with the right barrier behaviour.
  ///
  /// [dismissible] has no default on purpose - see the class comment.
  static Future<T?> show<T>(
    BuildContext context, {
    required bool dismissible,
    required WidgetBuilder builder,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      builder: builder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    final media = MediaQuery.sizeOf(context);
    final layout = AppLayout.maybeOf(context);

    // Never wider or taller than the window can hold. A 520x520 dialog cannot
    // fit a 380x500 window, and the app permits exactly that size.
    final effectiveWidth =
        (width ?? (layout.isCompact ? 400 : 520)).clamp(0.0, media.width - 48);
    final effectiveMaxHeight =
        (maxHeight ?? 560).clamp(0.0, media.height - 96);

    return Dialog(
      backgroundColor: NeuTheme.surface(isDark),
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: NeuTheme.border(isDark), width: 1),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: effectiveWidth.toDouble(),
          maxHeight: effectiveMaxHeight.toDouble(),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(isDark),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: scrollable
                    ? SingleChildScrollView(child: content)
                    : content,
              ),
            ),
            if (actions.isNotEmpty || leadingActions.isNotEmpty)
              _footer(isDark),
          ],
        ),
      ),
    );
  }

  Widget _header(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon,
                size: 20,
                color: tone == DialogTone.destructive
                    ? NeuTheme.dangerText(isDark)
                    : themeNotifier.accentInk),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: NeuTheme.titleStyle(isDark, fontSize: 16),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!,
                      style: NeuTheme.subtextStyle(isDark, fontSize: 12)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Row(
        children: [
          ...leadingActions,
          const Spacer(),
          // Secondary first, primary last: the confirm sits where the eye
          // finishes, and every dialog in the app now agrees on that.
          for (final action in actions.where((a) => !a.isPrimary)) ...[
            TextButton(
              onPressed: action.onPressed,
              child: Text(action.label,
                  style: TextStyle(color: NeuTheme.subtext(isDark))),
            ),
            const SizedBox(width: 8),
          ],
          for (final action in actions.where((a) => a.isPrimary))
            _primaryButton(action, isDark),
        ],
      ),
    );
  }

  Widget _primaryButton(NeuDialogAction action, bool isDark) {
    final destructive = action.isDestructive || tone == DialogTone.destructive;
    if (destructive) {
      return ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: NeuTheme.danger,
          foregroundColor: Colors.white,
        ),
        onPressed: action.onPressed,
        child: Text(action.label,
            style: const TextStyle(fontWeight: FontWeight.bold)),
      );
    }
    return NeuButton(
      onPressed: action.onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      borderRadius: BorderRadius.circular(8),
      child: Text(action.label,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: themeNotifier.accentInk)),
    );
  }
}
