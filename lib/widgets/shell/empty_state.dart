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
  const EmptyState({
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
              const SizedBox(height: 6),
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
