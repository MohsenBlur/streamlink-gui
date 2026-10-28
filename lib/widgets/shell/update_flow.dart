import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/update_service.dart';
import '../../state/app_shell_controller.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../neumorphic/neu_progress.dart';
import 'neu_dialog.dart';
import 'route_handle.dart';

/// The update [info] as the user sees it: a progress dialog with no way out
/// while the binaries are replaced, over the shell's steps
/// ([AppShellController.applyUpdate], which also exits for the updater).
///
/// [onFailed] is told what stopped it once the dialog is gone; the app is
/// then running as before and can be closed as usual.
void runUpdateWithProgress(
  BuildContext context,
  AppShellController shell,
  UpdateInfo info, {
  required void Function(Object error) onFailed,
}) {
  double progress = 0.0;
  String statusText = 'Downloading update archive...';

  // The dialog lives in the Navigator's overlay, so rebuilding MainScreen
  // cannot rebuild it. Progress updates must go through the dialog's own
  // StatefulBuilder setter, which was previously captured and never called -
  // leaving the bar frozen at "0.0%" for the entire download and extraction.
  void Function(VoidCallback)? setDialogState;
  void updateDialog(VoidCallback change) {
    change();
    final setter = setDialogState;
    if (setter != null) setter(() {});
  }

  // Closed by handle on failure: see the catch below.
  final progressDialog = RouteHandle();

  // No actions and not dismissible: the binaries are being replaced
  // underneath the running process, so there is genuinely no way out until
  // it finishes or fails. dialog_conformance_test pins this.
  NeuDialog.show<void>(
    context,
    dismissible: false,
    builder: (context) {
      progressDialog.attach(context);
      return StatefulBuilder(
        builder: (context, setProgressState) {
          setDialogState = setProgressState;
          final isDark = themeNotifier.isDarkTheme;
          return NeuDialog(
            title: 'Updating',
            icon: Icons.downloading,
            width: 420,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(statusText,
                    style: NeuType.body(isDark)),
                const SizedBox(height: NeuSpace.s12),
                NeuProgressBar(
                  value: progress > 0 ? progress : null,
                  semanticLabel: 'Update download',
                ),
                const SizedBox(height: NeuSpace.s8),
                Text('${(progress * 100).toStringAsFixed(1)}%',
                    style: NeuType.caption(isDark)),
              ],
            ),
          );
        },
      );
    },
  );

  // The steps themselves, and the guard on Exit while they run, are the
  // shell's (AppShellController.applyUpdate); this is what the user sees.
  Future.microtask(() async {
    try {
      await shell.applyUpdate(info, report: ({status, fraction}) {
        updateDialog(() {
          if (status != null) statusText = status;
          if (fraction != null) progress = fraction;
        });
      });
    } catch (e) {
      // THIS dialog, not the top route. Navigator.pop(context) popped
      // whatever was on top - a dialog the tray had opened over the
      // progress dialog, say - and left "Updating", which has no buttons
      // and cannot be dismissed, on screen for good.
      progressDialog.close();
      onFailed(e);
    }
  });
}

