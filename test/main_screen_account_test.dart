import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/oauth_loopback_server.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';

import 'support/main_screen_harness.dart';

/// The account token, through the pumped screen (see [ScreenHarness]):
/// signing in with Connect Account, probing the token, what a token that
/// starts working again refreshes, and the followed list's failures. The
/// sign-in listener is oauth_loopback_server_test's, the verdicts
/// twitch_auth_status_test's.
void main() {
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });
  tearDown(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });

  Future<void> connect(WidgetTester tester, ScreenHarness h) async {
    await tester.tap(find.text('Connect Account').first);
    await h.settleRoute(tester);
  }

  testWidgets(
      'Connect Account signs in through the browser, keeps the token with the '
      'Client ID that minted it, and probes it', (tester) async {
    final h = ScreenHarness();
    h.helix.user('gamma');
    h.helix.followed.add('gamma');
    await h.launch(tester,
        settings: ScreenHarness.defaultSettings()..twitchOauthToken = '');
    expect(twitchAuth.helix.value.state, TwitchAuthState.absent);

    await connect(tester, h);
    final signIn = h.signIns.single;
    expect(signIn.started, isTrue);
    expect(signIn.port, 65432);
    expect(h.shell.urls.single, signIn.authorizeUrl,
        reason: 'the browser opens the sign-in');
    expect(find.textContaining('OAuth server started on port 65432'),
        findsOneWidget);

    signIn.succeed('fresh-token');
    await h.settleRoute(tester);
    final saved = h.storage.savedSettings!;
    expect(saved.twitchOauthToken, 'oauth:fresh-token');
    expect(saved.twitchTokenClientId, OAuthLoopbackServer.publicClientId,
        reason: 'what signed in, not the blank field');
    expect(find.text('Twitch account connected successfully!'), findsOneWidget);
    expect(h.helix.validatedTokens.last, 'fresh-token');
    expect(twitchAuth.helix.value.isUsable, isTrue);
    expect(
        h.helix.to('/helix/channels/followed').last.headers['Authorization'],
        'Bearer fresh-token',
        reason: 'the followed list follows the new token');

    await h.close(tester);
  });

  testWidgets(
      'a second Connect replaces the first, whose answer is dropped; a '
      'refusal and a timeout each say so', (tester) async {
    final h = ScreenHarness();
    await h.launch(tester,
        settings: ScreenHarness.defaultSettings()..twitchOauthToken = '');

    await connect(tester, h);
    await h.advance(tester, const Duration(seconds: 6));
    await connect(tester, h);
    final first = h.signIns.first;
    final second = h.signIns.last;
    expect(first.closed, isTrue);
    first.succeed('stale-token');
    await h.settleRoute(tester);
    expect(h.storage.savedSettings?.twitchOauthToken ?? '', isEmpty);
    // Messages queue; the second Connect's own is still up.
    await h.advance(tester, const Duration(seconds: 6));

    second.deny('The user denied you access');
    await h.settleRoute(tester);
    expect(find.text('Twitch did not connect the account: The user denied you access'),
        findsOneWidget);

    await h.advance(tester, const Duration(seconds: 6));
    await connect(tester, h);
    h.signIns.last.timeOut();
    await h.settleRoute(tester);
    expect(
        find.text('The Twitch sign-in timed out. Click Connect Account to try '
            'again.'),
        findsOneWidget);

    await h.close(tester);
  });

  testWidgets(
      'a token minted for another Client ID is marked as such without asking '
      'Twitch', (tester) async {
    final h = ScreenHarness();
    await h.launch(tester,
        settings: ScreenHarness.defaultSettings()
          ..twitchTokenClientId = 'someone-elses-client');
    expect(twitchAuth.helix.value.fault, TwitchAuthFault.clientIdMismatch);
    expect(h.helix.validatedTokens, isEmpty,
        reason: 'detectable with no request, which matters offline');
    expect(find.text('Reconnect'), findsOneWidget);

    await h.close(tester);
  });

  testWidgets(
      'a token that starts working again refreshes the channels, the followed '
      'list and the open VOD list, and re-arms a dismissed banner',
      (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.addVideo('alpha', title: 'Older broadcast');
    h.helix.revokedTokens.add('account-token');
    await h.launch(tester, favorites: ['alpha']);
    await h.openChannel(tester, 'alpha');
    await tester.tap(find.byTooltip('Dismiss'));
    await h.settle(tester);
    expect(find.text('Reconnect'), findsNothing);

    h.helix.revokedTokens.clear();
    final mark = h.helix.requests.length;
    twitchAuth.recordHelixProbe(const TwitchAuthStatus(
      state: TwitchAuthState.valid,
      login: 'viewer',
      scopes: ['user:read:follows'],
    ));
    await h.settle(tester);
    expect(h.requestsTo('/helix/streams', since: mark), greaterThan(0));
    expect(h.requestsTo('/helix/channels/followed', since: mark), 1);
    expect(h.requestsTo('/helix/videos', since: mark), 1,
        reason: 'the open grid held its own 401');
    expect(find.text('Older broadcast'), findsOneWidget);

    // The dismissal covered the rejection it was shown for, not the next.
    twitchAuth.setHelix(const TwitchAuthStatus(
      state: TwitchAuthState.invalid,
      fault: TwitchAuthFault.revoked,
    ));
    await h.settle(tester);
    expect(find.text('Reconnect'), findsOneWidget);

    await h.close(tester);
  });

  testWidgets('a followed list Twitch will not give says so', (tester) async {
    final h = ScreenHarness();
    h.helix.failFollowed = true;
    await h.launch(tester);
    await h.settleRoute(tester);
    expect(find.textContaining('Could not load followed channels'),
        findsOneWidget);
    expect(twitchAuth.helix.value.isUsable, isTrue,
        reason: 'a server error is not the token');

    await h.close(tester);
  });
}
