import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// What is shown where content would be, when there is none.
///
/// The app had six of these, all as a bare centred `Text` in `subtext` at 12 or
/// 13px. Several stated the situation without offering a way out of it - the
/// Library's "Nothing here yet" and the VOD grid's "No past broadcasts found"
/// both leave the user reading a sentence with nothing to click.
///
/// An empty state has three jobs and this widget makes room for all of them:
/// say what is missing ([title]), say why or what to do ([message]), and give
/// the user the action if there is one ([action]).
class EmptyState extends StatelessWidget {
  /// **Deliberately not `const`.**
  ///
  /// This widget reads the `themeNotifier` global in `build`, and a const
  /// widget that does that never rebuilds when the theme changes. Const
  /// expressions are canonicalised, so the "new" widget a parent hands down is
  /// the *same instance*; `Element.updateChild` short-circuits on
  /// `child.widget == newWidget` and returns the existing element without
  /// calling `update` at all. The subtree is skipped, and it keeps whatever
  /// ink it was first built with.
  ///
  /// It is not hypothetical: `themeNotifier.isDarkTheme` starts true and is
  /// corrected from the config asynchronously, so on a light-theme install
  /// every const instance of this widget rendered its heading in the DARK
  /// theme's near-white ink on a light ground, permanently. "Live now" was
  /// built without `const` two hundred lines from "Quick actions" which had
  /// it, and only the second one was wrong.
  ///
  /// Dropping `const` from the constructor makes that a compile error rather
  /// than a rendering bug. `const_theme_reader_test` guards the general case.
  // ignore: prefer_const_constructors_in_immutables
  EmptyState({
    Key? key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  }) : super(key: key);

  final IconData icon;

  /// One short line. What is not here.
  final String title;

  /// Optional second line: why, or what to do about it.
  final String? message;

  /// The way out, when one exists.
  final Widget? action;

  /// Tighter spacing, for a panel rather than a whole page.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 24,
          vertical: compact ? 24 : 40,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: compact ? 28 : 40,
              // Deliberately dim: an empty state should read as calm, not as
              // an error.
              color: NeuTheme.disabledText(isDark),
            ),
            SizedBox(height: compact ? 10 : 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: compact
                  ? NeuType.headingSm(isDark)
                  : NeuType.headingMd(isDark),
            ),
            if (message != null) ...[
              const SizedBox(height: NeuSpace.s6),
              ConstrainedBox(
                // Keeps the line length readable instead of stretching a
                // sentence across a 2560px window.
                constraints: const BoxConstraints(maxWidth: 380),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: NeuType.bodySm(isDark, color: NeuTheme.subtext(isDark)),
                ),
              ),
            ],
            if (action != null) ...[
              SizedBox(height: compact ? 12 : 18),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
