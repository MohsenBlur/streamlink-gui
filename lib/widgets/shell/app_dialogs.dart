import 'package:flutter/material.dart';

import '../../models/twitch_channel.dart';
import '../../models/twitch_video.dart';
import '../../services/update_service.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import 'neu_dialog.dart';

/// The main screen's questions and offers, as dialogs. Each was inlined in
/// the screen method that asks it; they moved as they were, and the answers
/// are handled where they always were.

/// Offers [info]'s update; [onUpdate] runs when the user takes it. Completes
/// once the prompt has closed.
///
/// Not dismissible by clicking away: this is the only place the update is
/// offered, and a stray click outside would silently defer it for a day.
Future<void> showUpdatePrompt(
  BuildContext context,
  UpdateInfo info, {
  required VoidCallback onUpdate,
}) {
  return NeuDialog.show<void>(
    context,
    dismissible: false,
    builder: (context) {
      final isDark = themeNotifier.isDarkTheme;
      return NeuDialog(
        title: 'Update available',
        subtitle: 'v${UpdateService.currentVersion} → ${info.tagName}',
        icon: Icons.system_update,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A newer build is on GitHub Releases. The app downloads it, '
              'verifies its checksum and restarts itself.',
              style: NeuType.body(isDark),
            ),
            if (info.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: NeuSpace.s16),
              Text("What's new",
                  style: NeuType.label(isDark)),
              const SizedBox(height: NeuSpace.s6),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(NeuSpace.s12),
                decoration:
                    NeuTheme.sunkenDecoration(isDark, radius: NeuRadius.r8),
                child: SingleChildScrollView(
                  child: Text(
                    info.releaseNotes,
                    style: NeuType.bodySm(isDark),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          NeuDialogAction.secondary(
              'Remind me later', () => Navigator.pop(context)),
          NeuDialogAction.primary('Update and restart', () {
            Navigator.pop(context);
            onUpdate();
          }),
        ],
      );
    },
  );
}

/// Exit with downloads running: true to pause them and go, false or null to
/// keep running.
Future<bool?> confirmExitWithDownloads(BuildContext context) {
  return NeuDialog.show<bool>(
    context,
    dismissible: true,
    builder: (context) => NeuDialog(
      title: 'Downloads are still running',
      icon: Icons.download_for_offline_outlined,
      content: Text(
        'Exiting pauses them. They resume the next time you start the app.',
        style: NeuType.body(themeNotifier.isDarkTheme),
      ),
      actions: [
        NeuDialogAction.secondary(
            'Keep running', () => Navigator.pop(context, false)),
        NeuDialogAction.primary(
            'Exit and save queue', () => Navigator.pop(context, true)),
      ],
    ),
  );
}

/// The download queue an Exit was about to save did not reach [path]: true
/// to exit anyway.
Future<bool?> confirmExitWithUnsavedQueue(BuildContext context, String? path) {
  return NeuDialog.show<bool>(
    context,
    dismissible: true,
    builder: (context) => NeuDialog(
      title: 'Could not save the download queue',
      icon: Icons.error_outline,
      tone: DialogTone.destructive,
      content: Text(
        'Writing to $path failed, so the '
        'queued downloads will not resume after a restart.'
        '\n\nThis usually means the folder is full, read-only, or locked '
        'by another program. Go back to fix it and try again.',
        style: NeuType.body(themeNotifier.isDarkTheme),
      ),
      actions: [
        NeuDialogAction.secondary(
            'Go back', () => Navigator.pop(context, false)),
        NeuDialogAction.primary(
            'Exit anyway', () => Navigator.pop(context, true)),
      ],
    ),
  );
}

/// Removing the favourite [existing] (shown as [name]) discards its
/// automation: true to go ahead.
Future<bool?> confirmRemoveFavorite(
  BuildContext context, {
  required String name,
  required TwitchChannel existing,
}) {
  return NeuDialog.show<bool>(
    context,
    dismissible: true,
    builder: (context) => NeuDialog(
      title: 'Remove $name from favourites?',
      icon: Icons.star_border,
      tone: DialogTone.destructive,
      content: Text(
        'Its automation is discarded and cannot be undone:'
        '${existing.autoPlayLive ? '\n• Auto-play when live (priority #${existing.autoPlayPriority + 1})' : ''}'
        '${existing.autoDownloadVods ? '\n• Auto-download VODs (keep ${existing.maxVodKeepCount})' : ''}'
        '\n\nAlready-downloaded files are kept.',
        style: NeuType.body(themeNotifier.isDarkTheme),
      ),
      actions: [
        NeuDialogAction.secondary(
            'Keep it', () => Navigator.pop(context, false)),
        NeuDialogAction.primary(
            'Remove', () => Navigator.pop(context, true)),
      ],
    ),
  );
}

/// Cancelling a download ([isDownload]) or stopping playback: true to stop.
Future<bool?> confirmStopActivity(BuildContext context, {required bool isDownload}) {
  return NeuDialog.show<bool>(
    context,
    dismissible: true,
    builder: (context) => NeuDialog(
      title: isDownload ? 'Cancel this download?' : 'Stop playback?',
      icon: isDownload ? Icons.downloading : Icons.stop_circle_outlined,
      tone: isDownload ? DialogTone.destructive : DialogTone.neutral,
      content: Text(
        isDownload
            ? 'The partial file is deleted. The VOD stays available to '
                'download again.'
            : 'This closes the player window.',
        style: NeuType.body(themeNotifier.isDarkTheme),
      ),
      actions: [
        NeuDialogAction.secondary(
            'Keep running', () => Navigator.pop(context, false)),
        NeuDialogAction.primary(isDownload ? 'Cancel download' : 'Stop',
            () => Navigator.pop(context, true)),
      ],
    ),
  );
}

/// Deleting the downloaded file of [title]: true to delete. A dismissed
/// dialog is null, which must never mean yes.
Future<bool?> confirmDeleteDownload(BuildContext context, String title) {
  return NeuDialog.show<bool>(
    context,
    // Dismissible: clicking away is the same as Cancel here, and the
    // destructive action requires a deliberate click either way.
    dismissible: true,
    builder: (context) => NeuDialog(
      title: 'Delete download?',
      icon: Icons.delete_outline,
      tone: DialogTone.destructive,
      content: Text(
        'Delete the downloaded file for "$title"? This cannot be undone.',
        style: NeuType.body(themeNotifier.isDarkTheme),
      ),
      actions: [
        NeuDialogAction.secondary('Cancel', () => Navigator.pop(context, false)),
        NeuDialogAction.primary('Delete', () => Navigator.pop(context, true)),
      ],
    ),
  );
}

/// The order [count] queued VODs download in: 'newest', 'oldest', or null
/// when cancelled.
Future<String?> chooseDownloadOrder(BuildContext context, int count) {
  return NeuDialog.show<String>(
    context,
    dismissible: true,
    builder: (context) {
      return NeuDialog(
        title: 'Download order',
        subtitle: '$count VODs, one at a time',
        icon: Icons.download_for_offline,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Picking IS the action, so these rows carry it and the footer
            // only offers the way out. The old version buried the same two
            // choices in ListTiles under a paragraph asking you to choose.
            NeuChoiceTile(
              icon: Icons.arrow_downward,
              title: 'Newest first',
              subtitle: 'The latest broadcast starts downloading now',
              onTap: () => Navigator.pop(context, 'newest'),
            ),
            const SizedBox(height: NeuSpace.s8),
            NeuChoiceTile(
              icon: Icons.arrow_upward,
              title: 'Oldest first',
              subtitle: 'Work forwards from the oldest one selected',
              onTap: () => Navigator.pop(context, 'oldest'),
            ),
            // "Simultaneous Downloads" used to sit here. It called the same
            // queueVodDownload as the two branches above, which drains one
            // download at a time, and only differed in skipping the sort -
            // while announcing "Starting N parallel downloads...". Real
            // concurrency is a feature, not a relabelling.
          ],
        ),
        actions: [
          NeuDialogAction.secondary('Cancel', () => Navigator.pop(context)),
        ],
      );
    },
  );
}

/// Deleting the files of [toDelete]: true to delete.
Future<bool?> confirmDeleteDownloads(
    BuildContext context, List<TwitchVideo> toDelete) {
  return NeuDialog.show<bool>(
    context,
    dismissible: true,
    builder: (context) {
      final isDark = themeNotifier.isDarkTheme;
      return NeuDialog(
        title: 'Delete ${toDelete.length} downloaded '
            '${toDelete.length == 1 ? 'VOD' : 'VODs'}?',
        subtitle: 'The files on disk are removed. This cannot be undone.',
        icon: Icons.delete_outline,
        tone: DialogTone.destructive,
        scrollable: false,
        content: Container(
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.symmetric(vertical: NeuSpace.s8),
          decoration:
              NeuTheme.sunkenDecoration(isDark, radius: NeuRadius.r12),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: toDelete.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: NeuSpace.s12, vertical: NeuSpace.s4),
              child: Text(
                toDelete[index].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: NeuType.bodySm(isDark),
              ),
            ),
          ),
        ),
        actions: [
          NeuDialogAction.secondary(
              'Keep them', () => Navigator.pop(context, false)),
          NeuDialogAction.primary(
              'Delete files', () => Navigator.pop(context, true)),
        ],
      );
    },
  );
}
