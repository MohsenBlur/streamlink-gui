import 'package:flutter/material.dart';

import '../../services/storage_service.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../../utils/twitch_auth_status.dart';
import '../neumorphic/neu_icon_action.dart';
import 'engraved_rule.dart';
import 'neu_dialog.dart';

/// Warns that changes are not reaching disk.
///
/// A banner rather than a message: this is a CONDITION, not an event. It
/// clears itself the moment a save succeeds (which happens within seconds
/// during normal use), and a snackbar would be missed entirely while the app
/// sits minimised in the tray, which is its normal state.
class SaveFailureBanner extends StatelessWidget {
  const SaveFailureBanner({
    super.key,
    required this.failure,
    required this.onDismiss,
  })  : unreadable = false,
        historyOnly = false;

  /// A file that is there but could not be read, so nothing is saved over it
  /// this session (see StorageReadFailure): the same condition seen from the
  /// other side - changes are not reaching disk.
  SaveFailureBanner.unreadable({
    super.key,
    required StorageReadFailure failure,
    required this.onDismiss,
  })  : failure = StorageWriteFailure(failure.path, failure.error, DateTime.now()),
        unreadable = true,
        historyOnly = !failure.isConfig;

  final StorageWriteFailure failure;
  final VoidCallback onDismiss;
  final bool unreadable;

  /// The unreadable file is the watch history's, not the config. Said as
  /// the settings, it told the user every change was being lost while the
  /// config went on saving: only watch progress was.
  final bool historyOnly;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    // The translucent wash lets the panel grain through; the engraved cut at
    // its bottom is what makes it read as a milled warning band of the
    // chassis rather than a highlighter stroke across the plate.
    return Column(mainAxisSize: MainAxisSize.min, children: [
    Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s8),
      color: NeuTheme.danger.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              size: 16, color: NeuTheme.dangerText(isDark)),
          const SizedBox(width: NeuSpace.s8),
          Expanded(
            child: Text(
              unreadable
                  ? (historyOnly
                      ? 'Your watch history could not be read, so nothing is '
                          'saved over it until the app restarts. Watch progress '
                          'made now will be lost.'
                      : 'Your saved settings could not be read, so nothing is '
                          'saved over them until the app restarts. Changes made '
                          'now will be lost.')
                  : 'Your settings could not be saved to disk. Recent changes '
                      'may be lost when the app closes.',
              style: NeuType.label(isDark, color: NeuTheme.dangerText(isDark)),
            ),
          ),
          TextButton(
            // Same fix as the reconnect banner: the accent ink vanished into
            // the danger wash.
            onPressed: () => showSaveFailureDetail(context, failure,
                unreadable: unreadable, historyOnly: historyOnly),
            style: TextButton.styleFrom(
              foregroundColor: NeuTheme.dangerText(isDark),
            ),
            child: Text('Details',
                style: NeuType.captionStrong(isDark,
                    color: NeuTheme.dangerText(isDark))),
          ),
          // NeuIconAction, whose whole reason to exist is ending exactly
          // this: a dismiss target collapsed to its 14px glyph.
          NeuIconAction(
            icon: Icons.close,
            tooltip: 'Dismiss',
            size: NeuActionSize.sm,
            style: NeuActionStyle.flat,
            onPressed: onDismiss,
          ),
        ],
      ),
    ),
    EngravedRule(),
    ]);
  }
}

/// The account token was rejected, and this is where it gets fixed.
///
/// Persistent rather than a snackbar, and carrying the remedy rather than
/// describing it: the failure this replaces greeted the user on every
/// launch with a raw `{"error":"Unauthorized"...}` blob that scrolled away
/// before it could be acted on, while Settings kept showing a green tick.
class TwitchAuthBanner extends StatelessWidget {
  const TwitchAuthBanner({
    super.key,
    required this.status,
    required this.onReconnect,
    required this.onDismiss,
  });

  final TwitchAuthStatus status;

  /// Starts the Twitch sign-in.
  final VoidCallback onReconnect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    final detail = connectionDetail(status);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: NeuSpace.s16, vertical: NeuSpace.s8),
        color: NeuTheme.danger.withValues(alpha: 0.12),
        child: Row(
          children: [
            Icon(Icons.link_off, size: 16, color: NeuTheme.dangerText(isDark)),
            const SizedBox(width: NeuSpace.s8),
            Expanded(
              child: Text(
                detail ??
                    'Your Twitch account token was rejected. Followed channels '
                        'and VOD lists are unavailable until you reconnect.',
                style: NeuType.label(isDark, color: NeuTheme.dangerText(isDark)),
              ),
            ),
            TextButton(
              // Reconnecting happens HERE. Sending the user to Settings to
              // find the button is the extra step that makes a warning feel
              // like a scolding.
              onPressed: onReconnect,
              style: TextButton.styleFrom(
                foregroundColor: NeuTheme.dangerText(isDark),
              ),
              child: Text('Reconnect',
                  style: NeuType.captionStrong(isDark,
                      color: NeuTheme.dangerText(isDark))),
            ),
            NeuIconAction(
              icon: Icons.close,
              tooltip: 'Dismiss',
              size: NeuActionSize.sm,
              style: NeuActionStyle.flat,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
      EngravedRule(),
    ]);
  }
}

/// The save failure in full: which file, and what the system said.
void showSaveFailureDetail(BuildContext context, StorageWriteFailure failure,
    {bool unreadable = false, bool historyOnly = false}) {
  NeuDialog.show<void>(
    context,
    // Read-only detail: clicking away is a fine way to leave it.
    dismissible: true,
    builder: (context) => NeuDialog(
      title: unreadable
          ? (historyOnly ? 'Could not read watch history' : 'Could not read settings')
          : 'Could not save settings',
      icon: Icons.error_outline,
      tone: DialogTone.destructive,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            unreadable
                ? 'This file is there, but reading it failed when the app '
                    'started. Common causes are backup or sync software '
                    'holding it open, or a folder on a drive that was out of '
                    'reach. Nothing is written over it, so what it holds is '
                    'safe: restart the app once the file is free.'
                : 'Writing to this file keeps failing. Common causes are a '
                    'full disk, antivirus or backup software holding the file '
                    'open, or the folder no longer being writable.',
            style: NeuType.body(themeNotifier.isDarkTheme),
          ),
          const SizedBox(height: NeuSpace.s12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(NeuSpace.s8),
            decoration: NeuTheme.sunkenDecoration(
                themeNotifier.isDarkTheme,
                radius: NeuRadius.r8),
            child: SelectableText(
              '${failure.path}\n\n${failure.error}',
              style: NeuType.mono(themeNotifier.isDarkTheme),
            ),
          ),
        ],
      ),
      actions: [
        NeuDialogAction.secondary('Close', () => Navigator.pop(context)),
      ],
    ),
  );
}

