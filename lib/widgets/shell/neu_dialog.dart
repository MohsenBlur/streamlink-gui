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
  const NeuDialogAction.primary(
    this.label,
    this.onPressed, {
    this.isDestructive = false,
  }) : isPrimary = true;

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

/// A whole-row choice inside a dialog body.
///
/// For dialogs where picking IS the action - download order, player type -
/// rather than dialogs that ask a question and confirm it in the footer.
/// Those used `ListTile`, which puts the real choices in the body at body
/// weight while the footer's "Cancel" gets the only button, so the way out
/// looked more like the action than the actions did.
class NeuChoiceTile extends StatelessWidget {
  const NeuChoiceTile({
    Key? key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  }) : super(key: key);

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    return NeuButton(
      onPressed: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: NeuSpace.s12,
        vertical: NeuSpace.s12,
      ),
      borderRadius: BorderRadius.circular(NeuRadius.r12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: themeNotifier.accentInk),
          const SizedBox(width: NeuSpace.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: NeuType.headingSm(isDark)),
                if (subtitle != null) ...[
                  const SizedBox(height: NeuSpace.s2),
                  Text(subtitle!, style: NeuType.caption(isDark)),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: NeuTheme.subtext(isDark)),
        ],
      ),
    );
  }
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
/// * Dialogs take the `panel` treatment, which **reverses** the rule this file
///   used to state. The old reasoning was sound for neumorphism: extrusion
///   means extrusion *from the surface behind*, so a bevel bleeding onto a
///   black scrim was a rendering artefact rather than depth. A material is not
///   extruded from anything — it is an object — and a service panel in front
///   of another panel is exactly what a dialog is. The same argument was
///   written twice; see `NeuElevation.d5`.
class NeuDialog extends StatelessWidget {
  const NeuDialog({
    Key? key,
    required this.title,
    required this.content,
    this.icon,
    this.subtitle,
    this.headerBottom,
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

  /// Sits directly under the header, full-bleed and undivided from it - a tab
  /// bar, a search field. Part of the dialog's chrome rather than its body, so
  /// it does not scroll with the content.
  final Widget? headerBottom;

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
    final effectiveWidth = (width ?? (layout.isCompact ? 400 : 520)).clamp(
      0.0,
      media.width - 48,
    );
    final effectiveMaxHeight = (maxHeight ?? 560).clamp(0.0, media.height - 96);

    return Dialog(
      // Transparent, because the panel below paints the sheet. Leaving a
      // background here would put a flat rectangle under the material and its
      // bevel would sit on the wrong colour at the corners.
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(NeuSpace.s24),
      child: Container(
        decoration: NeuTheme.panel(
          isDark,
          radius: NeuRadius.r16,
          depth: NeuElevation.d4,
          border: Border.all(color: NeuTheme.border(isDark)),
        ),
        clipBehavior: Clip.antiAlias,
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
              ?headerBottom,
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NeuSpace.s20,
                    NeuSpace.s4,
                    NeuSpace.s20,
                    NeuSpace.s16,
                  ),
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
      ),
    );
  }

  Widget _header(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeuSpace.s20,
        NeuSpace.s16,
        NeuSpace.s20,
        NeuSpace.s12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 20,
              color: tone == DialogTone.destructive
                  ? NeuTheme.dangerText(isDark)
                  : themeNotifier.accentInk,
            ),
            const SizedBox(width: NeuSpace.s8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: NeuType.headingMd(isDark),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: NeuSpace.s4),
                  Text(
                    subtitle!,
                    style: NeuType.bodySm(
                      isDark,
                      color: NeuTheme.subtext(isDark),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        NeuSpace.s20,
        NeuSpace.s12,
        NeuSpace.s20,
        NeuSpace.s16,
      ),
      // A hairline, always. Long dialogs scroll their content behind the
      // footer, and without a boundary the last visible line just stops
      // mid-sentence above the buttons and reads as a clipping bug.
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: NeuTheme.border(isDark))),
      ),
      // A Wrap rather than a Row, because two ordinary labels do not fit on
      // one line in a 380px window: "Cancel" beside "Save changes" needed 307
      // logical pixels of the 290 the footer has, and a Row's only answer to
      // that is to overflow. Wrapping keeps both labels whole - truncating the
      // word that says what a button does is the one outcome worse than a
      // second line.
      //
      // The Spacer is gone with it: `Expanded` does the same job here, and a
      // Spacer inside a Row alongside a Flexible would have split the free
      // space with it rather than yielding all of it.
      child: Row(
        children: [
          ...leadingActions,
          if (leadingActions.isNotEmpty) const SizedBox(width: NeuSpace.s8),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: NeuSpace.s8,
              runSpacing: NeuSpace.s8,
              children: [
                // Secondary first, primary last: the confirm sits where the
                // eye finishes, and every dialog in the app agrees on that.
                // Wrap lays out in order, so a wrapped footer puts the confirm
                // on the lower line - still last in the reading order.
                for (final action in actions.where((a) => !a.isPrimary))
                  TextButton(
                    onPressed: action.onPressed,
                    child: Text(
                      action.label,
                      style: TextStyle(color: NeuTheme.subtext(isDark)),
                    ),
                  ),
                for (final action in actions.where((a) => a.isPrimary))
                  _primaryButton(action, isDark),
              ],
            ),
          ),
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
        child: Text(
          action.label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    }
    return NeuButton(
      onPressed: action.onPressed,
      padding: const EdgeInsets.symmetric(
        horizontal: NeuSpace.s16,
        vertical: NeuSpace.s8,
      ),
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      child: Text(
        action.label,
        style: NeuType.headingSm(isDark, color: themeNotifier.accentInk),
      ),
    );
  }
}
