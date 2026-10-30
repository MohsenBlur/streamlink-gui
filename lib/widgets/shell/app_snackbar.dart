import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// The app's in-app message: [message] on the danger red when [isError],
/// on the accent otherwise, replacing whatever message is up.
///
/// [context] must be mounted; the screen checks that before it asks.
void showAppSnackBar(
  BuildContext context,
  String message, {
  required bool isError,
  SnackBarAction? action,
}) {
  // Errors use the fixed danger red (white text); info follows the accent.
  //
  // Replace rather than queue: ScaffoldMessenger plays queued snackbars one
  // after another, so a burst of messages read as one that would not go
  // away. Only the newest is worth showing.
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        // w600: w500 is not a real weight in Segoe UI, so this snackbar
        // has always rendered at w400. A notification should stand out.
        style: TextStyle(
          color: isError
              ? NeuTheme.onAccent(NeuTheme.danger)
              : themeNotifier.onPrimaryColor,
          fontWeight: FontWeight.w600,
        ),
      ),
      backgroundColor: isError ? NeuTheme.danger : themeNotifier.primaryColor,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r8)),
      margin: const EdgeInsets.all(NeuSpace.s12),
      // Long enough to read and act on, short enough to get out of the way.
      duration: Duration(seconds: action != null ? 8 : 3),
      showCloseIcon: true,
      closeIconColor: isError ? Colors.white : themeNotifier.onPrimaryColor,
      action: action,
    ),
  );
}
