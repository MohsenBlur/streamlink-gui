import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/update_service.dart';
import 'package:streamlink_gui/widgets/shell/app_dialogs.dart';

/// The main screen's dialogs, each asked and answered: what every button
/// returns, and whether a click on the scrim can dismiss it. A dismissed
/// dialog answers null, which every caller treats as "no".
void main() {
  TwitchVideo vod(String title) => TwitchVideo(
        id: title,
        title: title,
        duration: '1h0m0s',
        thumbnailUrl: '',
        viewCount: '0',
        publishedAt: DateTime(2026),
      );

  /// Opens [ask], taps [button] (or the scrim when null), and returns what
  /// the dialog answered.
  Future<Object?> answer(
    WidgetTester tester,
    Future<Object?> Function(BuildContext context) ask,
    String? button,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Object? result = 'unanswered';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await ask(context),
            child: const Text('ask'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ask'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    if (button == null) {
      await tester.tapAt(const Offset(4, 4));
    } else {
      await tester.tap(find.text(button));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return result;
  }

  final cases = <String, (Future<Object?> Function(BuildContext), String, Object?)>{
    'exit with downloads: keep running': (
      confirmExitWithDownloads,
      'Keep running',
      false
    ),
    'exit with downloads: go': (
      confirmExitWithDownloads,
      'Exit and save queue',
      true
    ),
    'exit with an unsaved queue: back': (
      (c) => confirmExitWithUnsavedQueue(c, 'channels_config.json'),
      'Go back',
      false
    ),
    'exit with an unsaved queue: anyway': (
      (c) => confirmExitWithUnsavedQueue(c, 'channels_config.json'),
      'Exit anyway',
      true
    ),
    'unstar: keep': (
      (c) => confirmRemoveFavorite(c,
          name: 'alpha',
          existing: TwitchChannel(username: 'alpha')..autoPlayLive = true),
      'Keep it',
      false
    ),
    'unstar: remove': (
      (c) => confirmRemoveFavorite(c,
          name: 'alpha',
          existing: TwitchChannel(username: 'alpha')..autoDownloadVods = true),
      'Remove',
      true
    ),
    'stop playback': (
      (c) => confirmStopActivity(c, isDownload: false),
      'Stop',
      true
    ),
    'cancel a download: keep': (
      (c) => confirmStopActivity(c, isDownload: true),
      'Keep running',
      false
    ),
    'delete a download': ((c) => confirmDeleteDownload(c, 'A VOD'), 'Delete', true),
    'download order: newest': (
      (c) => chooseDownloadOrder(c, 3),
      'Newest first',
      'newest'
    ),
    'download order: oldest': (
      (c) => chooseDownloadOrder(c, 3),
      'Oldest first',
      'oldest'
    ),
    'download order: cancel': ((c) => chooseDownloadOrder(c, 3), 'Cancel', null),
    'delete downloads: keep': (
      (c) => confirmDeleteDownloads(c, [vod('one'), vod('two')]),
      'Keep them',
      false
    ),
    'delete downloads: delete': (
      (c) => confirmDeleteDownloads(c, [vod('one'), vod('two')]),
      'Delete files',
      true
    ),
  };
  for (final entry in cases.entries) {
    testWidgets(entry.key, (tester) async {
      final (ask, button, expected) = entry.value;
      expect(await answer(tester, ask, button), expected);
    });
  }

  testWidgets('every confirmation is dismissible, and dismissal is not a yes',
      (tester) async {
    for (final ask in <Future<Object?> Function(BuildContext)>[
      confirmExitWithDownloads,
      (c) => confirmExitWithUnsavedQueue(c, 'x'),
      (c) => confirmRemoveFavorite(c,
          name: 'a', existing: TwitchChannel(username: 'a')..autoPlayLive = true),
      (c) => confirmStopActivity(c, isDownload: true),
      (c) => confirmDeleteDownload(c, 'A VOD'),
      (c) => chooseDownloadOrder(c, 2),
      (c) => confirmDeleteDownloads(c, [vod('one')]),
    ]) {
      expect(await answer(tester, ask, null), isNull);
    }
  });

  testWidgets('the update offer cannot be clicked away, and taking it runs '
      'the update', (tester) async {
    final info = UpdateInfo(
      version: '99.0.0',
      releaseNotes: 'Faster.',
      zipDownloadUrl: 'https://example.invalid/app.zip',
      isUpdateAvailable: true,
    );
    var updated = 0;
    Future<Object?> offer(BuildContext c) =>
        showUpdatePrompt(c, info, onUpdate: () => updated++).then((_) => 'closed');

    expect(await answer(tester, offer, null), 'unanswered',
        reason: 'a stray click would defer the update for a day');
    await tester.tap(find.text('Remind me later'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(updated, 0);

    expect(await answer(tester, offer, 'Update and restart'), 'closed');
    expect(updated, 1);
  });
}
