import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/desktop_shell.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/update_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

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
  });

  group('exit', () {
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

  testWidgets('a token Twitch refuses raises the reconnect banner',
      (tester) async {
    final h = ScreenHarness();
    h.helix.revokedTokens.add('account-token');
    await h.launch(tester);
    expect(twitchAuth.helix.value.fault, TwitchAuthFault.revoked);
    expect(find.text('Reconnect'), findsOneWidget);
    await h.close(tester);
  });
}
