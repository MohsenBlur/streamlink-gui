import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/desktop_shell.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/update_service.dart';
import 'package:streamlink_gui/state/app_shell_controller.dart';
import 'package:streamlink_gui/state/download_history.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/state/vod_cache.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';
import 'package:streamlink_gui/widgets/shell/channel_dashboard.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

import 'support/fake_process.dart';
import 'support/main_screen_harness.dart';

/// The main screen itself, pumped whole over fakes (see [ScreenHarness]).
///
/// Its rules are tested where they live - the poll in channels_controller,
/// the VOD list in vod_browser_controller, saving in settings_repository -
/// and this is the wiring between them that only the screen has: which
/// refresh a poll tick or a window coming back starts, what saving Settings
/// resets, and what an exit does, in what order. Until this file every one
/// of those was checked by reading the source; if the screen stopped calling
/// a refresh, nothing failed.
void main() {
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });
  tearDown(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });

  Finder sidebarRow(String name) => find.descendant(
      of: find.byType(SidebarPanel), matching: find.text(name));

  Future<void> openChannel(
      WidgetTester tester, ScreenHarness h, String name) async {
    await tester.tap(sidebarRow(name).first);
    await h.settle(tester);
  }

  int videoFetches(ScreenHarness h, int since) =>
      h.requestsTo('/helix/videos', since: since);

  testWidgets('starts from the config main() read: favourites, poll, tray',
      (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.user('beta');
    h.helix.goLive('alpha');
    await h.launch(tester, favorites: ['alpha', 'beta']);

    expect(sidebarRow('alpha'), findsWidgets);
    expect(sidebarRow('beta'), findsWidgets);
    expect(h.requestsTo('/helix/streams'), greaterThan(0));
    expect(h.tray.initialised, isTrue);
    expect(h.tray.menuLabels, contains('Watch alpha'),
        reason: 'a live favourite is offered in the tray menu');
    expect(h.storage.configWrites, 0,
        reason: 'starting up is no reason to rewrite the config');

    await h.close(tester);
  });

  group('the open VOD list', () {
    testWidgets(
        'a VOD published while its channel is open reaches the grid on the '
        'cadence, without reselecting', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Older broadcast');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');
      expect(find.text('Older broadcast'), findsOneWidget);

      h.helix.addVideo('alpha', title: 'Fresh broadcast');
      final mark = h.helix.requests.length;
      // Polls tick every minute; under the four-minute cadence they leave
      // the list alone.
      await h.advance(tester, const Duration(minutes: 3));
      expect(videoFetches(h, mark), 0);
      expect(find.text('Fresh broadcast'), findsNothing);

      // Past it, a tick refreshes the open list in place.
      await h.advance(tester, const Duration(minutes: 2));
      expect(videoFetches(h, mark), 1);
      expect(find.text('Fresh broadcast'), findsOneWidget);
      expect(find.text('Older broadcast'), findsOneWidget,
          reason: 'merged into the list, not swapped for it');

      await h.close(tester);
    });

    testWidgets(
        'a channel left for the dashboard is kept current by the prefetch',
        (tester) async {
      // The browser still holds the channel after "Go to dashboard", and the
      // prefetch skipped what it held; the open list's cadence needs a
      // channel open, so nothing read that one again.
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Older broadcast');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');
      await tester.tap(find.byTooltip('Dashboard Hub (Return Home)').first);
      await h.settle(tester);

      final mark = h.helix.requests.length;
      await h.advance(tester, VodCache.ttl + const Duration(minutes: 1),
          step: const Duration(seconds: 30));
      expect(videoFetches(h, mark), 1);

      await h.close(tester);
    });

    testWidgets('what a fetch brings is saved by the debounced, config-only '
        'write', (tester) async {
      // Every selection and refresh wrote the config and the progress
      // sidecar at once, each fsync'd.
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Older broadcast');
      await h.launch(tester, favorites: ['alpha']);
      final config = h.storage.configWrites;
      final progress = h.storage.progressWrites;

      await openChannel(tester, h, 'alpha');
      expect(h.storage.configWrites, config, reason: 'not at once');
      await h.advance(tester, const Duration(seconds: 2));
      expect(h.storage.configWrites, config + 1);
      expect(h.storage.progressWrites, progress);

      await h.close(tester);
    });

    testWidgets(
        'the open channel going live shows within one poll, and the VOD its '
        'broadcast leaves arrives as soon as it ends', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Yesterday');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');
      expect(find.text('42 viewers'), findsNothing);

      h.helix.goLive('alpha', archive: false, title: 'Speedrun night');
      await h.advance(tester, const Duration(seconds: 61));
      expect(find.text('42 viewers'), findsOneWidget,
          reason: "the header's live stats, one poll later");
      expect(find.textContaining('Speedrun night'), findsWidgets);
      expect(h.notifications.titles, contains('alpha is now LIVE!'));

      // The broadcast ends, and Twitch publishes what it recorded. The
      // cadence is minutes away: only the broadcast ending brings it in.
      h.helix.goOffline('alpha');
      h.helix.addVideo('alpha', title: 'Speedrun night, recorded');
      await h.advance(tester, const Duration(seconds: 61));
      expect(find.text('42 viewers'), findsNothing);
      expect(find.text('Speedrun night, recorded'), findsOneWidget);
      expect(h.notifications.titles, isNot(contains('New VOD from alpha')),
          reason: 'the grid on screen shows it arriving; no toast as well');

      await h.close(tester);
    });

    testWidgets(
        'left open with the window hidden, its broadcast end is looked at '
        'again when the first look fails', (tester) async {
      // The open channel, in the tray: its normal resting state. The look at
      // the broadcast's end was its only one - the cadence stops while the
      // window is hidden and the prefetch left it to that cadence - so one
      // failed request lost its New VOD toast.
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.goLive('alpha');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');
      h.tray.choose('Hide App');
      await h.settle(tester);

      h.helix
        ..goOffline('alpha')
        ..failVideos = true;
      await h.advance(tester, const Duration(seconds: 61));
      h.helix.failVideos = false;
      expect(h.notifications.titles, isNot(contains('New VOD from alpha')));

      await h.advance(tester, const Duration(minutes: 3));
      expect(h.notifications.titles, contains('New VOD from alpha'));

      await h.close(tester);
    });

    testWidgets(
        'coming back after a minute away refreshes it once, however many '
        'events the return fires', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Older broadcast');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');

      h.helix.addVideo('alpha', title: 'While you were away');
      await h.advance(tester, const Duration(seconds: 90));
      expect(find.text('While you were away'), findsNothing,
          reason: 'precondition: the cadence has not come round');

      final mark = h.helix.requests.length;
      // Alt-tabbing back and forth: a burst of focus events.
      h.window.userRefocuses();
      h.window.userRefocuses();
      h.window.userRefocuses();
      await tester.pump(const Duration(milliseconds: 250));
      expect(videoFetches(h, mark), 0, reason: 'debounced');
      await tester.pump(const Duration(milliseconds: 100));
      await h.settle(tester);
      expect(videoFetches(h, mark), 1);
      expect(find.text('While you were away'), findsOneWidget);

      // The list is fresh now: coming back again fetches nothing.
      final again = h.helix.requests.length;
      h.window.userRefocuses();
      await tester.pump(const Duration(milliseconds: 400));
      await h.settle(tester);
      expect(videoFetches(h, again), 0);

      await h.close(tester);
    });

    testWidgets(
        "the toolbar's refresh says when it failed, over a list of any age, "
        'and a good one clears that', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Older broadcast');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');
      Finder note() => find.textContaining("Couldn't refresh");

      h.helix.failVideos = true;
      final mark = h.helix.requests.length;
      await tester.tap(find.byTooltip('Check for new VODs'));
      await h.settle(tester);
      expect(videoFetches(h, mark), 1);
      expect(note(), findsOneWidget,
          reason: 'a refresh the user asked for that failed says so, '
              'however new the list is');
      expect(find.text('Older broadcast'), findsOneWidget,
          reason: 'the list stays');

      h.helix.failVideos = false;
      h.helix.addVideo('alpha', title: 'Fresh broadcast');
      await tester.tap(find.byTooltip('Check for new VODs'));
      await h.settle(tester);
      expect(note(), findsNothing);
      expect(find.text('Fresh broadcast'), findsOneWidget);

      await h.close(tester);
    });

    testWidgets("the header's links go to the shell, not to a child of the "
        'app', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');

      await tester.tap(find.byTooltip('Open Twitch channel'));
      await tester.tap(find.byTooltip('Open Twitch chat popout'));
      await h.settle(tester);
      expect(h.shell.urls,
          ['https://twitch.tv/alpha', 'https://twitch.tv/alpha/chat']);

      await h.close(tester);
    });

    testWidgets(
        'selection mode: pick VODs by clicking them, mark them watched, and '
        'leave', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'First');
      h.helix.addVideo('alpha', title: 'Second');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');

      await tester.tap(find.text('Select'));
      await h.settle(tester);
      expect(find.text('Select videos'), findsOneWidget);
      await tester.tap(find.text('First'));
      await h.settle(tester);
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.text('All'));
      await h.settle(tester);
      expect(find.text('2 selected'), findsOneWidget);

      final progress = h.storage.progressWrites;
      await tester.tap(find.text('Watched'));
      await h.settle(tester);
      expect(find.textContaining('Marked 2 VODs watched'), findsOneWidget);
      expect(find.text('Select'), findsOneWidget,
          reason: 'marking ends selection mode');
      expect(h.storage.progressWrites, progress + 1);
      expect(h.storage.watchProgress, hasLength(2));

      await h.close(tester);
    });

    testWidgets(
        'is left alone while the window is in the tray, and refreshed when '
        'it is shown again', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha', title: 'Older broadcast');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');

      h.tray.choose('Hide App');
      await h.settle(tester);
      expect(h.window.visible, isFalse);

      h.helix.addVideo('alpha', title: 'Published overnight');
      final mark = h.helix.requests.length;
      await h.advance(tester, const Duration(minutes: 6));
      expect(videoFetches(h, mark), 0,
          reason: 'nobody can see the grid; the poll does not fetch it');

      h.tray.fire(TrayEvent.click);
      await tester.pump(const Duration(milliseconds: 350));
      await h.settle(tester);
      expect(h.window.visible, isTrue);
      expect(videoFetches(h, mark), 1);
      expect(find.text('Published overnight'), findsOneWidget);

      await h.close(tester);
    });
  });

  testWidgets('the live pulse runs only while the window is on screen',
      (tester) async {
    // Its visibility was set by hand on the few paths that remembered to, so
    // closing to the tray left a pulse running there - at 60fps, for as long
    // as a favourite stayed live.
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.goLive('alpha');
    await h.launch(tester, favorites: ['alpha']);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, greaterThan(0),
        reason: 'a favourite is live and the window is up');

    h.window.userCloses();
    await h.settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);

    h.tray.fire(TrayEvent.click);
    await h.settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await h.close(tester);
  });

  testWidgets('a rate-limited poll leaves live channels live', (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.goLive('alpha');
    await h.launch(tester, favorites: ['alpha']);
    expect(find.text('Nobody is live'), findsNothing);
    expect(h.notifications.titles, isEmpty,
        reason: 'already live at launch is not "went live"');

    h.helix.rateLimitStreams = true;
    final mark = h.helix.requests.length;
    await h.advance(tester, const Duration(seconds: 61));
    expect(h.requestsTo('/helix/streams', since: mark), greaterThan(0),
        reason: 'precondition: the poll asked and was refused');
    expect(find.text('Nobody is live'), findsNothing);
    expect(h.tray.menuLabels, contains('Watch alpha'));

    // Had the refusal read as offline, the next answer would announce the
    // broadcast all over again.
    h.helix.rateLimitStreams = false;
    await h.advance(tester, const Duration(seconds: 61));
    expect(h.notifications.titles, isEmpty);
    expect(find.text('Nobody is live'), findsNothing);

    await h.close(tester);
  });

  testWidgets(
      'saving Settings with another account token starts over for that '
      'account: status probed, followed list reloaded with it',
      (tester) async {
    final h = ScreenHarness();
    h.helix.user('gamma');
    h.helix.followed.add('gamma');
    h.helix.tokenLogins['second-token'] = 'other';
    await h.launch(tester, size: const Size(1400, 1000));
    // As a Test of the saved token in Settings left it: "Connected as viewer".
    twitchAuth.recordHelixProbe(const TwitchAuthStatus(
      state: TwitchAuthState.valid,
      login: 'viewer',
      scopes: ['user:read:follows'],
    ));
    expect(h.helix.validatedTokens, isNot(contains('second-token')));

    await tester.tap(find.byTooltip('Settings').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('Twitch'));
    await tester.tap(find.text('Twitch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(
        find.byWidgetPredicate((w) =>
            w is TextField &&
            w.decoration?.hintText == 'oauth:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'),
        'oauth:second-token');
    // Nothing answers for the new token yet - neither its probe nor the
    // followed list loading with it - to see what the screen says about the
    // account meanwhile.
    h.helix.holdValidate = Completer<void>();
    h.helix.holdUsers = Completer<void>();
    h.helix.holdFollowed = Completer<void>();
    await tester.tap(find.text('Save changes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await h.settle(tester);
    expect(twitchAuth.helix.value.login, isNot('viewer'),
        reason: '"Connected as" the previous account must not outlive it');

    h.helix.holdValidate!.complete();
    h.helix.holdUsers!.complete();
    h.helix.holdFollowed!.complete();
    await h.settle(tester);
    expect(h.storage.savedSettings?.twitchOauthToken, 'oauth:second-token');
    expect(h.helix.validatedTokens.last, 'second-token',
        reason: 'the new token is probed now, not at its first 401');
    expect(twitchAuth.helix.value.login, 'other');
    final followed = h.helix.to('/helix/channels/followed');
    expect(followed.last.headers['Authorization'], 'Bearer second-token');

    await h.close(tester);
  });

  testWidgets("a double-click on Home's live card plays it, though its "
      'first click has already opened the channel', (tester) async {
    // The click opens the channel at once, so Home - and the card - are
    // gone before the second click: it landed on the channel page, and the
    // double-click that watches the channel did nothing.
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.addVideo('alpha', title: 'Old broadcast');
    h.helix.goLive('alpha', title: 'Speedrun night');
    await h.launch(tester, favorites: ['alpha']);
    await h.advance(tester, const Duration(seconds: 2));
    final at = tester.getCenter(find.text('Speedrun night').first);

    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(ChannelDashboard), findsOneWidget,
        reason: 'the first click opened it, without waiting');
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await h.settle(tester);

    expect(h.player.runningChannels, {'alpha'});
    expect(find.byType(ChannelDashboard), findsOneWidget);

    await h.close(tester);
  });

  testWidgets("but a click there once a double-click's time is up is the "
      "channel page's", (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.addVideo('alpha', title: 'Old broadcast');
    h.helix.goLive('alpha', title: 'Speedrun night');
    await h.launch(tester, favorites: ['alpha']);
    await h.advance(tester, const Duration(seconds: 2));
    final at = tester.getCenter(find.text('Speedrun night').first);

    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await h.settle(tester);
    expect(h.player.runningChannels, isEmpty,
        reason: 'nothing is held over the page past the double-click time');
    expect(find.byType(ChannelDashboard), findsOneWidget);

    await h.close(tester);
  });

  group('the update guard', () {
    testWidgets('an Exit or a close while an update installs is refused, '
        'with the reason, until the update fails', (tester) async {
      final h = ScreenHarness();
      h.updates.available = UpdateInfo(
        version: '99.0.0',
        releaseNotes: 'Faster.',
        zipDownloadUrl: 'https://example.invalid/app.zip',
        isUpdateAvailable: true,
      );
      await h.launch(tester,
          settings: ScreenHarness.defaultSettings()..closeAction = 'exit');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Update available'), findsOneWidget);
      await tester.tap(find.text('Update and restart'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Updating'), findsOneWidget);
      expect(h.updates.downloads, 1);

      h.window.userCloses();
      await h.settle(tester);
      expect(find.textContaining('An update is being installed'),
          findsOneWidget);
      h.tray.choose('Exit');
      await h.settle(tester);
      expect(h.window.destroyed, isFalse);
      expect(h.tray.destroyed, isFalse);
      expect(h.log, isNot(contains('player.stopAll')));

      h.updates.download.completeError(Exception('network down'));
      await h.settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Update failed: network down'),
          findsOneWidget);

      h.tray.choose('Exit');
      await h.settle(tester);
      expect(h.window.destroyed, isTrue,
          reason: 'a failed update gives the way out back');

      await h.close(tester);
    });

    testWidgets('an update that fails before its dialog has built still '
        'takes the dialog away', (tester) async {
      final h = ScreenHarness();
      h.updates.available = UpdateInfo(
        version: '99.0.0',
        releaseNotes: 'Faster.',
        zipDownloadUrl: 'https://example.invalid/app.zip',
        isUpdateAvailable: true,
      );
      // Offline with no adapter: the download fails before the next frame,
      // so the failure reaches the dialog's handle ahead of its first build.
      h.updates.download.future.ignore();
      h.updates.download.completeError(Exception('offline'));
      await h.launch(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Update available'), findsOneWidget);

      await tester.tap(find.text('Update and restart'));
      await h.settle(tester);
      await tester.pump(const Duration(milliseconds: 600));
      await h.settle(tester);

      expect(find.textContaining('Update failed: offline'),
          findsOneWidget);
      expect(find.text('Updating'), findsNothing,
          reason: 'it has no buttons and cannot be dismissed');

      await h.close(tester);
    });
  });

  group('exit', () {
    testWidgets(
        'with a config that could not be read, saves nothing over it, and '
        'says so', (tester) async {
      // Held open by a backup client at launch: the app ran on defaults and
      // the Exit's save wrote them over every channel, setting and token.
      addTearDown(() => storageReadFailure.value = null);
      final failure =
          StorageReadFailure('channels_config.json', 'in use by another program');
      storageReadFailure.value = failure;
      final h = ScreenHarness();
      h.helix.user('alpha');
      await h.launch(tester, favorites: ['alpha'], configReadFailure: failure);
      expect(find.textContaining('could not be read'), findsOneWidget);

      h.tray.choose('Exit');
      await h.settle(tester);

      expect(h.log, contains('window.destroy'), reason: 'it did exit');
      expect(h.storage.configWrites, 0);
      expect(h.storage.config!['channels'], hasLength(1),
          reason: 'what was there is still there');

      await h.close(tester);
    });

    testWidgets(
        'captures the window, stops the players, saves, and only then '
        'removes the tray icon and the window', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      await h.launch(tester, favorites: ['alpha']);
      h.log.clear();

      h.tray.choose('Exit');
      await h.settle(tester);

      const steps = {
        'window.state',
        'player.stopAll',
        'save.config',
        'save.progress',
        'save.recents',
        'tray.destroy',
        'window.destroy',
      };
      final order = [for (final e in h.log) if (steps.contains(e)) e];
      expect(order.first, 'window.state');
      expect(order.indexOf('player.stopAll'), 1,
          reason: 'stopping reports a final position; the saves must see it');
      expect(order.sublist(2, 5),
          unorderedEquals(['save.config', 'save.progress', 'save.recents']));
      expect(order.sublist(5), ['tray.destroy', 'window.destroy']);
      expect(h.window.listenerCount(), 0,
          reason: 'no window event reaches a screen that is going');
      expect(h.storage.savedSettings?.windowPlacement, isNotNull,
          reason: 'the geometry captured is the geometry saved');

      // A second Exit while the first one runs is ignored.
      h.tray.choose('Exit');
      await h.settle(tester);
      expect(h.window.calls['destroy'], 1);

      await h.close(tester);
    });

    testWidgets(
        'with downloads queued it asks first, and saves their queue before '
        'stopping them', (tester) async {
      final h = ScreenHarness();
      await h.launch(tester);
      final folder = Directory.systemTemp.createTempSync('screen_downloads_');
      addTearDown(() {
        try {
          folder.deleteSync(recursive: true);
        } catch (_) {}
      });
      h.player.queueVodDownload(
        TwitchVideo(
          id: 'v77',
          title: 'A long VOD',
          duration: '1h0m0s',
          thumbnailUrl: '',
          viewCount: '0',
          publishedAt: DateTime(2026),
        ),
        'alpha',
        AppSettings(vodDownloadFolder: folder.path),
      );
      await h.settle(tester);

      h.tray.choose('Exit');
      await h.settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Downloads are still running'), findsOneWidget);
      await tester.tap(find.text('Keep running'));
      await h.settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.window.destroyed, isFalse);
      expect(h.log, isNot(contains('player.stopAll')));

      h.log.clear();
      h.tray.choose('Exit');
      await h.settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Exit and save queue'));
      // The download is a running yt-dlp now, which the stop waits on.
      await tester.pump(AppShellController.stopAllTimeout);
      await h.settle(tester);
      expect(h.window.destroyed, isTrue);
      expect(h.log.indexOf('save.config'),
          lessThan(h.log.indexOf('player.stopAll')),
          reason: 'the queue they resume from is on disk before they stop');
      expect(h.storage.savedSettings?.unfinishedDownloads, hasLength(1));

      await h.close(tester);
    });

    testWidgets("an Exit from the tray starts no refresh with its own show",
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      await h.launch(tester, favorites: ['alpha']);
      await openChannel(tester, h, 'alpha');
      h.tray.choose('Hide App');
      await h.settle(tester);
      // Old enough that coming back would refresh both the channels and the
      // open list.
      await h.advance(tester, const Duration(seconds: 45));

      final mark = h.helix.requests.length;
      h.tray.choose('Exit');
      await h.settle(tester);
      expect(h.window.destroyed, isTrue);
      await h.advance(tester, const Duration(minutes: 3));
      expect(h.helix.requests.length, mark,
          reason: 'showing the window to exit is not the user coming back');

      await h.close(tester);
    });
  });

  testWidgets("the tray's Watch opens the channel as it is when clicked",
      (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.user('beta');
    h.helix.goLive('alpha');
    h.helix.goLive('beta');
    await h.launch(tester, favorites: ['alpha', 'beta']);
    final staleBeta = h.tray.menu.firstWhere((e) => e.label == 'Watch beta');

    h.tray.choose('Watch alpha');
    await h.settle(tester);
    expect(h.player.runningChannels, ['alpha']);
    expect(h.launcher.launched.single.arguments.join(' '), contains('alpha'));

    // A menu item outlives the poll that took its channel offline.
    h.helix.goOffline('beta');
    await h.advance(tester, const Duration(seconds: 61));
    staleBeta.onClicked!();
    await h.settle(tester);
    expect(h.player.runningChannels, ['alpha']);

    await h.close(tester);
  });

  group("a toast's click", () {
    /// The toast titled [title], clicked.
    Future<void> click(
        WidgetTester tester, ScreenHarness h, String title) async {
      final toast = h.notifications.shown.lastWhere((n) => n.title == title);
      await toast.onClick!();
      await h.settle(tester);
    }

    String? openChannelName(WidgetTester tester) {
      final dashboard = find.byType(ChannelDashboard);
      if (dashboard.evaluate().isEmpty) return null;
      return tester.widget<ChannelDashboard>(dashboard).channel.username;
    }

    testWidgets(
        'on a went-live toast brings the window back, opens the channel and '
        'starts its stream', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.user('beta');
      await h.launch(tester, favorites: ['alpha', 'beta']);
      await openChannel(tester, h, 'beta');
      h.tray.choose('Hide App');
      await h.settle(tester);
      expect(h.window.visible, isFalse);

      h.helix.goLive('alpha', title: 'Speedrun night');
      await h.advance(tester, const Duration(seconds: 61));
      expect(h.notifications.titles, contains('alpha is now LIVE!'));
      expect(h.player.runningChannels, isEmpty,
          reason: 'precondition: a toast only says so');

      await click(tester, h, 'alpha is now LIVE!');
      expect(h.window.visible, isTrue);
      expect(openChannelName(tester), 'alpha');
      expect(h.player.runningChannels, ['alpha']);
      expect(h.launcher.launched.single.arguments.join(' '), contains('alpha'));

      await h.close(tester);
    });

    testWidgets(
        'on a New VOD toast brings the window back and opens the channel, '
        'with the VOD in its grid', (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.goLive('alpha');
      await h.launch(tester, favorites: ['alpha']);
      h.tray.choose('Hide App');
      await h.settle(tester);

      // The broadcast ends off screen, and leaves its VOD.
      h.helix.goOffline('alpha');
      h.helix.addVideo('alpha', title: 'Last night, recorded');
      await h.advance(tester, const Duration(seconds: 61));
      expect(h.notifications.titles, contains('New VOD from alpha'));
      expect(openChannelName(tester), isNull);

      await click(tester, h, 'New VOD from alpha');
      expect(h.window.visible, isTrue);
      expect(openChannelName(tester), 'alpha');
      expect(find.text('Last night, recorded'), findsOneWidget);
      expect(h.player.runningChannels, isEmpty,
          reason: 'a VOD is not played for the asking');

      await h.close(tester);
    });
  });

  testWidgets('Esc leaves the Library for where you were; Ctrl+F finds the '
      'sidebar search', (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    await h.launch(tester, favorites: ['alpha']);
    await openChannel(tester, h, 'alpha');
    Finder back() => find.byTooltip('Back to alpha (Esc)');

    h.tray.choose('Open Library');
    await h.settle(tester);
    expect(back(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await h.settle(tester);
    expect(back(), findsNothing);
    expect(find.text('Select'), findsOneWidget, reason: "alpha's dashboard");

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await h.settle(tester);
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    expect(
        find.descendant(
            of: find.byType(SidebarPanel),
            matching: find.byWidgetPredicate(
                (w) => w is EditableText && w.focusNode.hasFocus)),
        findsOneWidget,
        reason: 'focused: $focused');

    await h.close(tester);
  });

  testWidgets('a close with the default action hides to the tray, once',
      (tester) async {
    final h = ScreenHarness();
    await h.launch(tester);

    h.window.userCloses();
    await h.settle(tester);
    expect(h.window.visible, isFalse);
    expect(h.window.destroyed, isFalse);
    expect(h.notifications.titles, ['Still running in the tray']);
    expect(h.storage.savedSettings?.trayNoticeShown, isTrue);

    h.tray.fire(TrayEvent.click);
    await h.settle(tester);
    h.window.userCloses();
    await h.settle(tester);
    expect(h.notifications.titles, ['Still running in the tray'],
        reason: 'the heads-up is one-time');

    await h.close(tester);
  });

  group('the banners', () {
    testWidgets(
        'a token Twitch refuses raises the reconnect banner; a dismissal '
        'covers that reason and not the next', (tester) async {
      final h = ScreenHarness();
      h.helix.revokedTokens.add('account-token');
      await h.launch(tester);
      expect(twitchAuth.helix.value.fault, TwitchAuthFault.revoked);
      expect(find.text('Reconnect'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await h.settle(tester);
      expect(find.text('Reconnect'), findsNothing);

      twitchAuth.setHelix(const TwitchAuthStatus(
        state: TwitchAuthState.invalid,
        fault: TwitchAuthFault.clientIdMismatch,
      ));
      await h.settle(tester);
      expect(find.text('Reconnect'), findsOneWidget,
          reason: 'a different problem is a different message');

      await h.close(tester);
    });

    testWidgets(
        'a failing save raises its banner until dismissed, and a new failure '
        'after a good save raises it again', (tester) async {
      final h = ScreenHarness();
      await h.launch(tester);
      Finder banner() => find.textContaining('could not be saved to disk');
      expect(banner(), findsNothing);

      storageWriteFailure.value =
          StorageWriteFailure('channels_config.json', 'disk full', DateTime(2026));
      await h.settle(tester);
      expect(banner(), findsOneWidget);
      await tester.tap(find.text('Details'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('disk full'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byTooltip('Dismiss'));
      await h.settle(tester);
      expect(banner(), findsNothing);

      storageWriteFailure.value = null;
      await h.settle(tester);
      storageWriteFailure.value =
          StorageWriteFailure('channels_config.json', 'disk full', DateTime(2026));
      await h.settle(tester);
      expect(banner(), findsOneWidget);

      storageWriteFailure.value = null;
      await h.close(tester);
    });
  });

  group('auto-download', () {
    // Over the real player service, with yt-dlp faked and a real download
    // folder: retention and the downloaded-file scan work on the disk.
    //
    // The scan runs on an isolate, so these let real time pass for it
    // (runAsync) - and with it the title bar's window_manager query, which
    // the other tests never let land and which no plugin answers here.
    const windowManager = MethodChannel('window_manager');
    late Directory folder;
    setUp(() {
      folder = Directory.systemTemp.createTempSync('streamlink_gui_vods_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManager,
              (call) async => call.method == 'isMaximized' ? false : null);
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManager, null);
      try {
        folder.deleteSync(recursive: true);
      } catch (_) {}
    });

    TwitchChannel autoDownloading(String name, {required int keep}) =>
        TwitchChannel(
            username: name, autoDownloadVods: true, maxVodKeepCount: keep);

    AppSettings downloadingTo({int retention = 0}) =>
        ScreenHarness.defaultSettings()
          ..vodDownloadFolder = folder.path
          ..maxDownloadsToKeep = retention;

    List<FakeProcess> ytDlpFor(ScreenHarness h, String vodId) => [
          for (final run in h.launcher.launched)
            if (run.arguments.last == 'https://twitch.tv/videos/$vodId') run,
        ];

    File fileOf(String vodId) =>
        File(p.join(folder.path, 'alpha', 'VOD $vodId - $vodId.mp4'));

    /// [vodId]'s yt-dlp writes its file and exits 0.
    Future<void> finishDownload(
        WidgetTester tester, ScreenHarness h, String vodId,
        {DateTime? modified}) async {
      final file = fileOf(vodId)
        ..createSync(recursive: true)
        ..writeAsStringSync('video');
      if (modified != null) file.setLastModifiedSync(modified);
      unawaited(ytDlpFor(h, vodId).single.exit(0));
      // A fake process ends on a zero-length timer, which only a pump that
      // moves the clock fires.
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
    }

    /// Runs the clock until the saved registry no longer holds [vodId] - but
    /// still holds [kept], when given: the ten-second tick's downloaded-file
    /// scan runs on an isolate, so real time has to pass for it as well, and
    /// what it changes is saved a second later.
    Future<void> untilScanForgets(
        WidgetTester tester, ScreenHarness h, String vodId,
        {String? kept}) async {
      bool forgotten() {
        final saved = h.storage.config!['downloaded_vods'] as Map;
        return !saved.containsKey(vodId) &&
            (kept == null || saved.containsKey(kept));
      }

      for (var i = 0; i < 200 && !forgotten(); i++) {
        await h.advance(tester, const Duration(seconds: 1));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await h.settle(tester);
      }
      expect(forgotten(), isTrue, reason: 'the scan found its file gone');
    }

    testWidgets(
        'a VOD retention deleted from its window is not downloaded again',
        (tester) async {
      // Two in the window, one kept on disk. Retention deleted the older,
      // the scan took it out of the registry, and the next pass fetched it
      // again for retention to delete the newer - every pass.
      final h = ScreenHarness();
      h.helix.user('alpha');
      final older = h.helix.addVideo('alpha',
          publishedAt: h.helix.now.subtract(const Duration(days: 2)));
      final newer = h.helix.addVideo('alpha',
          publishedAt: h.helix.now.subtract(const Duration(days: 1)));
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 2)],
          settings: downloadingTo(retention: 1));

      expect(ytDlpFor(h, older), hasLength(1), reason: 'oldest first');
      await finishDownload(tester, h, older,
          modified: h.helix.now.subtract(const Duration(hours: 1)));
      expect(ytDlpFor(h, newer), hasLength(1));
      await finishDownload(tester, h, newer);
      expect(fileOf(older).existsSync(), isFalse, reason: 'retention');
      expect(fileOf(newer).existsSync(), isTrue);

      await untilScanForgets(tester, h, older, kept: newer);
      // Passes a minute apart: each used to queue it again.
      await h.advance(tester, const Duration(minutes: 3));
      expect(ytDlpFor(h, older), hasLength(1));
      expect(ytDlpFor(h, newer), hasLength(1));
      expect(h.storage.config!['download_history'],
          allOf(contains(older), contains(newer)));

      await h.close(tester);
    });

    testWidgets(
        'a VOD downloaded before the upgrade is not fetched again once it '
        'is gone', (tester) async {
      // A config from before the download history: only the registry knows
      // the VOD, whose file was deleted while the app was closed.
      final h = ScreenHarness();
      h.helix.user('alpha');
      final vod = h.helix.addVideo('alpha',
          publishedAt: h.helix.now.subtract(const Duration(days: 1)));
      Directory(p.join(folder.path, 'alpha')).createSync(recursive: true);
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo(),
          config: {
            'downloaded_vods': {vod: fileOf(vod).path},
          });
      expect(h.launcher.launched, isEmpty, reason: 'the registry has it');

      await untilScanForgets(tester, h, vod);
      await h.advance(tester, const Duration(minutes: 2));
      expect(h.launcher.launched, isEmpty,
          reason: 'seeded from the registry, the history still has it');
      expect(h.storage.config!['download_history'], contains(vod));

      await h.close(tester);
    });

    testWidgets(
        "a VOD yt-dlp's archive holds from before the upgrade is not fetched "
        'again', (tester) async {
      // Builds before the archive matched Twitch's ids never took a line out
      // of it, so a VOD deleted under one is in neither the registry nor on
      // disk: its archive line is all that is left of the download. The pass
      // queued it, yt-dlp skipped it as done, and the user was told of an
      // auto-download and a completed one, for a VOD they had deleted.
      final h = ScreenHarness();
      h.helix.user('alpha');
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo(),
          files: {'yt_dlp_archive.txt': 'twitchvod v4242\n'});
      // The archive is read beside the load, as real file I/O, and what it
      // adds is saved a second later.
      bool seeded() =>
          (h.storage.config!['download_history'] as Map?)
              ?.containsKey('4242') ??
          false;
      for (var i = 0; i < 50 && !seeded(); i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await h.advance(tester, const Duration(seconds: 1));
      }
      expect(seeded(), isTrue, reason: 'the history starts from the archive');

      // Listed only now, so that the pass reads it once the seed is in.
      h.helix.addVideo('alpha',
          id: '4242',
          publishedAt: h.helix.now.subtract(const Duration(days: 1)));
      await h.advance(tester, const Duration(minutes: 2));
      expect(ytDlpFor(h, '4242'), isEmpty);

      await h.close(tester);
    });

    testWidgets(
        "past the history's cap, the registry's VODs outrank the archive's",
        (tester) async {
      // The registry is seeded as the config loads, the archive once it has
      // been read, a moment later - and stamped later, the archive's lines
      // outranked the registry's VODs, which went first past the cap.
      final h = ScreenHarness();
      h.helix.user('alpha');
      final archive = StringBuffer();
      for (var i = 0; i < DownloadHistory.maxEntries; i++) {
        archive.writeln('twitchvod v${9000 + i}');
      }
      Directory(p.join(folder.path, 'alpha')).createSync(recursive: true);
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo(),
          config: {
            'downloaded_vods': {'5150': fileOf('5150').path},
          },
          files: {'yt_dlp_archive.txt': archive.toString()});
      Map<dynamic, dynamic> saved() =>
          h.storage.config!['download_history'] as Map? ?? const {};
      for (var i = 0; i < 50 && !saved().containsKey('9999'); i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await h.advance(tester, const Duration(seconds: 1));
      }
      expect(saved().containsKey('9999'), isTrue,
          reason: "precondition: the archive's seed is in");

      expect(saved(), hasLength(DownloadHistory.maxEntries));
      expect(saved().containsKey('5150'), isTrue);
      expect(saved().containsKey('9000'), isFalse,
          reason: "the archive's oldest line went instead");

      await h.close(tester);
    });

    testWidgets(
        'with the download folder out of reach, nothing is queued to fail '
        'every minute', (tester) async {
      // An unplugged drive: each pass queued the VODs, each failed at once,
      // and each pass after it did the same - two toasts and a snackbar
      // per VOD, every minute, for as long as the drive was away.
      final unplugged = File(p.join(folder.path, 'not a folder'))
        ..writeAsStringSync('x');
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.addVideo('alpha',
          publishedAt: h.helix.now.subtract(const Duration(days: 1)));
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: ScreenHarness.defaultSettings()
            ..vodDownloadFolder = p.join(unplugged.path, 'VODs'));
      await h.advance(tester, const Duration(minutes: 3));

      expect(h.notifications.titles, isNot(contains('VOD Download Failed')));
      expect(h.notifications.titles, isNot(contains('Auto-Downloading VOD')));
      expect(h.launcher.launched, isEmpty);
      expect(
          h.notifications.titles.where((t) => t == 'Auto-Download Paused'),
          hasLength(1),
          reason: 'said once, not every minute, and not never');

      await h.close(tester);
    });

    testWidgets(
        'a VOD the pass downloads and announces raises no New VOD toast as '
        'well', (tester) async {
      // A broadcast ending off screen leaves a VOD inside the auto-download
      // window: one toast for it, the pass's, not "New VOD" too.
      final h = ScreenHarness();
      h.helix.user('alpha');
      h.helix.goLive('alpha', archive: false);
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo());
      h.tray.choose('Hide App');
      await h.settle(tester);

      h.helix.goOffline('alpha');
      final vod = h.helix.addVideo('alpha', title: 'Last night, recorded');
      await h.advance(tester, const Duration(seconds: 61));
      expect(ytDlpFor(h, vod), hasLength(1));
      expect(h.notifications.titles, contains('Auto-Downloading VOD'));
      expect(h.notifications.titles, isNot(contains('New VOD from alpha')));

      await h.close(tester);
    });

    testWidgets(
        'reads watch positions from Twitch only for what it would download',
        (tester) async {
      // One GQL request per VOD on the page, every minute, for every
      // auto-download favourite with a browser token.
      final h = ScreenHarness();
      h.helix.user('alpha');
      final ids = [
        for (var day = 3; day >= 1; day--)
          h.helix.addVideo('alpha',
              publishedAt: h.helix.now.subtract(Duration(days: day))),
      ];
      int lookups() => [
            for (final r in h.helix.requests)
              if (r.url.path == '/gql' && r.body.contains('viewingHistory')) r,
          ].length;
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo()
            ..twitchWebOauthToken = 'oauth:browser-token',
          config: {
            // The oldest, the one VOD in the window, was downloaded already.
            'download_history': {ids.first: h.helix.now.millisecondsSinceEpoch},
          });
      expect(lookups(), 3, reason: 'the first pass reads every one');

      await h.advance(tester, const Duration(minutes: 5));
      expect(lookups(), 3, reason: 'five passes with nothing to download');
      expect(h.launcher.launched, isEmpty);

      await h.close(tester);
    });

    testWidgets('Download by hand still fetches a VOD the pass leaves alone',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      final vod = h.helix.addVideo('alpha',
          title: 'Deleted earlier',
          publishedAt: h.helix.now.subtract(const Duration(days: 1)));
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo(),
          config: {
            'download_history': {vod: h.helix.now.millisecondsSinceEpoch},
          });
      await h.advance(tester, const Duration(minutes: 1));
      expect(h.launcher.launched, isEmpty, reason: 'downloaded once');

      // What a build before the archive id match left behind, which made
      // yt-dlp skip the download as done and exit 0 with no file.
      final archive = h.storage.getStorageFile('yt_dlp_archive.txt')
        ..writeAsStringSync('twitchvod $vod\ntwitchvod v99\n');

      await openChannel(tester, h, 'alpha');
      await tester.tap(find.text('Deleted earlier').first,
          buttons: kSecondaryMouseButton);
      // The menu grows open; until it has, its items are clipped away.
      await h.advance(tester, const Duration(milliseconds: 500),
          step: const Duration(milliseconds: 100));
      await tester.tap(find.text('Download'));
      await h.settle(tester);
      // The rewrite is real file I/O, a step at a time, under a lock that
      // keeps a read out until it is done.
      List<String>? lines() {
        try {
          return archive.readAsLinesSync();
        } on FileSystemException {
          return null;
        }
      }

      for (var i = 0; i < 200 && (lines()?.length ?? 2) > 1; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await h.settle(tester);
      }
      expect(lines(), ['twitchvod v99']);
      await h.advance(tester, const Duration(seconds: 6));

      expect(ytDlpFor(h, vod), hasLength(1));

      await h.close(tester);
    });

    /// Right-clicks [title]'s card and picks [item] from its menu.
    Future<void> fromMenu(WidgetTester tester, ScreenHarness h, String title,
        String item) async {
      await tester.tap(find.text(title).first,
          buttons: kSecondaryMouseButton);
      // The menu grows open; until it has, its items are clipped away.
      await h.advance(tester, const Duration(milliseconds: 500),
          step: const Duration(milliseconds: 100));
      await tester.tap(find.text(item).last);
      await h.settle(tester);
    }

    testWidgets(
        'a VOD whose auto-download the user cancelled is not queued again, '
        'and Download by hand still fetches it', (tester) async {
      // The cancel was recorded nowhere, so the next pass, a minute later,
      // queued the same VOD again.
      final h = ScreenHarness();
      h.helix.user('alpha');
      final vod = h.helix.addVideo('alpha',
          title: 'Not this one',
          publishedAt: h.helix.now.subtract(const Duration(days: 1)));
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo());
      expect(ytDlpFor(h, vod), hasLength(1),
          reason: 'precondition: the pass queued it');

      await openChannel(tester, h, 'alpha');
      await fromMenu(tester, h, 'Not this one', 'Cancel download');
      // It is running, so the card asks first.
      await tester.tap(find.text('Cancel download').last);
      await h.settleRoute(tester);
      // taskkill's yt-dlp ends on a zero-length timer.
      await h.advance(tester, const Duration(milliseconds: 50),
          step: const Duration(milliseconds: 10));
      expect(find.text('Download cancelled.'), findsOneWidget);

      await h.advance(tester, const Duration(minutes: 3));
      expect(ytDlpFor(h, vod), hasLength(1), reason: 'three passes later');
      expect(h.storage.config!['download_history'], contains(vod));

      await fromMenu(tester, h, 'Not this one', 'Download');
      // Queued by hand, it waits for its archive line to be taken out, which
      // is real file I/O.
      for (var i = 0; i < 100 && ytDlpFor(h, vod).length < 2; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await h.settle(tester);
      }
      expect(ytDlpFor(h, vod), hasLength(2));

      await h.close(tester);
    });

    testWidgets(
        'an auto-download an exit stops is not taken for a cancel: it is '
        'saved to resume', (tester) async {
      // Only the user's Cancel says no to a VOD. An exit stops every
      // download without it, and the next launch resumes them.
      final h = ScreenHarness();
      h.helix.user('alpha');
      final vod = h.helix.addVideo('alpha',
          publishedAt: h.helix.now.subtract(const Duration(days: 1)));
      await h.launch(tester,
          channels: [autoDownloading('alpha', keep: 1)],
          settings: downloadingTo());
      expect(ytDlpFor(h, vod), hasLength(1),
          reason: 'precondition: the pass queued it');

      h.tray.choose('Exit');
      await h.settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Exit and save queue'));
      await tester.pump(AppShellController.stopAllTimeout);
      await h.settle(tester);
      expect(h.window.destroyed, isTrue);

      expect(h.storage.config!['download_history'], isNot(contains(vod)));
      expect(h.storage.savedSettings?.unfinishedDownloads, hasLength(1));

      await h.close(tester);
    });
  });
}
