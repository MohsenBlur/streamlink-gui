import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/state/account_controller.dart';
import 'package:streamlink_gui/state/channels_controller.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';

import 'support/fake_helix.dart';

/// The account token's rules on their own. The screen's use of them - a
/// sign-in, a recovery's refreshes, the banner - is main_screen_account_test.
void main() {
  late FakeHelix helix;
  late AppSettings settings;
  late List<String> calls;
  late bool startupComplete;
  late AccountController account;
  late bool disposed;

  const valid = TwitchAuthStatus(
    state: TwitchAuthState.valid,
    login: 'viewer',
    scopes: ['user:read:follows'],
  );
  const revoked = TwitchAuthStatus(
    state: TwitchAuthState.invalid,
    fault: TwitchAuthFault.revoked,
  );

  setUp(() {
    twitchAuth.resetForTest();
    helix = FakeHelix();
    settings = AppSettings(twitchOauthToken: 'oauth:account-token');
    calls = [];
    startupComplete = true;
    disposed = false;
    final api = helix.service(auth: twitchAuth);
    account = AccountController(
      api: api,
      channels: ChannelsController(
        api: api,
        settings: () => settings,
        favorites: [],
        selected: () => null,
        clock: () => helix.now,
      ),
      auth: twitchAuth,
      settings: () => settings,
      signInServer: ({required int port, required String clientId}) =>
          throw UnimplementedError(),
      openLink: (url) async {},
      save: () async => calls.add('save'),
      mounted: () => true,
      startupComplete: () => startupComplete,
      refreshChannels: () async => calls.add('refresh channels'),
      refreshOpenVods: () => calls.add('refresh open VODs'),
      followedLoaded: () => calls.add('followed loaded'),
      showMessage: (m, {required isError}) => calls.add(m),
    );
  });
  tearDown(() {
    // Each one listens on the global; one left attached would answer the
    // next test's status changes.
    if (!disposed) account.dispose();
    twitchAuth.resetForTest();
  });

  test('a token that starts working refreshes what it left stale, once '
      'startup is done, and only on the transition', () async {
    account.attach();
    twitchAuth.setHelix(revoked);
    startupComplete = false;
    twitchAuth.setHelix(valid);
    expect(calls, isEmpty, reason: 'startup fetches everything itself');

    twitchAuth.setHelix(revoked);
    startupComplete = true;
    twitchAuth.setHelix(valid);
    await pumpEventQueue();
    expect(calls, containsAllInOrder(['refresh channels', 'refresh open VODs']));
    expect(calls, contains('followed loaded'));

    calls.clear();
    twitchAuth.setHelix(valid.copyWith(login: 'viewer'));
    expect(calls, isEmpty, reason: 'still usable is not a recovery');
  });

  test('stops listening when it goes', () async {
    account.attach();
    twitchAuth.setHelix(revoked);
    account.dispose();
    disposed = true;
    twitchAuth.setHelix(valid);
    await pumpEventQueue();
    expect(calls, isEmpty);
  });

  test("a dismissed banner stays down for its reason, comes back for "
      'another, and for the same one after the token worked again', () {
    account.attach();
    expect(account.showsBanner(revoked), isTrue);
    account.dismissBanner(revoked.fault);
    expect(account.showsBanner(revoked), isFalse);

    const mismatch = TwitchAuthStatus(
      state: TwitchAuthState.invalid,
      fault: TwitchAuthFault.clientIdMismatch,
    );
    expect(account.showsBanner(mismatch), isTrue);
    account.dismissBanner(mismatch.fault);
    startupComplete = false; // no refreshes in this test
    twitchAuth.setHelix(valid);
    expect(account.showsBanner(mismatch), isTrue);
  });

  test('a token minted for another Client ID is marked without a request',
      () async {
    settings.twitchTokenClientId = 'someone-else';
    await account.probe(force: true);
    expect(twitchAuth.helix.value.fault, TwitchAuthFault.clientIdMismatch);
    expect(helix.validatedTokens, isEmpty);

    settings.twitchTokenClientId = '';
    await account.probe(force: true);
    expect(helix.validatedTokens, ['account-token']);
    expect(twitchAuth.helix.value.isUsable, isTrue);

    settings.twitchOauthToken = '';
    await account.probe();
    expect(twitchAuth.helix.value.state, TwitchAuthState.absent);
  });
}
