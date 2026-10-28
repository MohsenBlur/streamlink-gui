import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme/neu_theme.dart';
import '../theme/theme_notifier.dart';
import 'shell/neu_dialog.dart';

/// Asks where VODs go, for a download started before any folder was set.
///
/// [show] completes with the folder the user picked, or null when they
/// cancelled or dismissed the prompt. Saving the folder and starting the
/// download are the caller's, on a non-null answer only.
///
/// The folder dialog runs off the UI isolate since file_picker 13, so this
/// prompt stays live behind it. It can be dismissed - Cancel, Esc, a click on
/// the scrim - while the folder dialog is still open, and the caller then
/// reports the download as cancelled. A folder picked after that used to be
/// saved anyway, as the download folder, for a download that was no longer
/// going to happen. It is dropped now: the prompt that asked is gone, and so
/// is the question.
class DownloadFolderPrompt extends StatefulWidget {
  /// Not `const`: it reads `themeNotifier` in build, and a const instance
  /// is never rebuilt when the theme changes (see const_theme_reader_test).
  // ignore: prefer_const_constructors_in_immutables
  DownloadFolderPrompt({Key? key}) : super(key: key);

  static Future<String?> show(BuildContext context) => NeuDialog.show<String>(
        context,
        dismissible: true,
        builder: (context) => DownloadFolderPrompt(),
      );

  @override
  State<DownloadFolderPrompt> createState() => _DownloadFolderPromptState();
}

class _DownloadFolderPromptState extends State<DownloadFolderPrompt> {
  /// The folder dialog is open. A second press would open a second one, and
  /// whichever answered last would win.
  bool _picking = false;

  Future<void> _chooseFolder() async {
    if (_picking) return;
    // Taken before the await. `mounted` alone is not "the prompt is still
    // up": the dialog outlives its pop by the whole exit animation, while the
    // route stops being active at the pop itself.
    final route = ModalRoute.of(context);
    setState(() => _picking = true);
    final path = await FilePicker.getDirectoryPath().whenComplete(() {
      if (mounted) setState(() => _picking = false);
    });
    if (!mounted || route?.isActive == false) return;
    if (path == null || path.isEmpty) return;
    // This prompt's own route, not whichever is on top. A route can land over
    // the prompt while the folder dialog is open - the update offer at
    // startup, the tray's Exit asking about unfinished downloads - and a pop
    // then closed that one instead, with a folder path for its answer.
    if (route != null && !route.isCurrent) {
      Navigator.removeRoute(context, route, path);
    } else {
      Navigator.pop(context, path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    return NeuDialog(
      title: 'Where should VODs be saved?',
      icon: Icons.folder_copy,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No download folder is set yet. Pick one and the download starts '
            'straight away; everything you download later goes there too.',
            style: NeuType.body(isDark),
          ),
          // The folder dialog does not keep itself above the app, so a click
          // back here can bury it. Say where the answer is expected.
          if (_picking) ...[
            const SizedBox(height: NeuSpace.s8),
            Text(
              'Pick a folder in the window that opened.',
              style: NeuType.caption(isDark),
            ),
          ],
        ],
      ),
      actions: [
        NeuDialogAction.secondary('Cancel', () => Navigator.pop(context)),
        NeuDialogAction.primary(
          'Choose folder',
          _picking ? null : _chooseFolder,
        ),
      ],
    );
  }
}
