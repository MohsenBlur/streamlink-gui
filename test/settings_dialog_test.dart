import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';
import 'package:streamlink_gui/widgets/settings_dialog.dart';

/// The real settings dialog, pumped and driven.
///
/// `settings_tabs_test` and `material_picker_test` call this dialog "not
/// practical to pump" and assert its source instead. It is practical: the
/// static `show` needs a context under a Navigator and a set of callbacks. The
/// behaviour below is what a source scan cannot see - which credential a Test
/// result is published for, what happens when the dialog closes under a
/// running test, and what Connect Account persists.
///
/// The layout sweep across every tab lives in
/// `layout/settings_dialog_sweep_test.dart`.

/// A [TwitchApiService] whose validations stay open until the test resolves
/// them, so a test can close the dialog underneath one.
///
/// Resolve, then [_settle]: one pump runs the handler's continuation, which
/// calls setDialogState, and the next one builds what it set.
class _HeldApi extends TwitchApiService {
  final helixCalls = <(String token, String clientId)>[];
  final helix = Completer<TwitchAuthStatus>();
  final browser = Completer<TokenValidationResult>();

  @override
  Future<TwitchAuthStatus> validateHelixToken(
      String rawToken, String configuredClientId) {
    helixCalls.add((rawToken, configuredClientId));
    return helix.future;
  }

  @override
  Future<TokenValidationResult> validateOAuthToken(String rawToken) =>
      browser.future;
}

const _accountTokenHint = 'oauth:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';

const _validSaved = TwitchAuthStatus(
  state: TwitchAuthState.valid,
  login: 'saved_user',
  scopes: ['user:read:follows'],
);
const _revoked = TwitchAuthStatus(
  state: TwitchAuthState.invalid,
  fault: TwitchAuthFault.revoked,
);

AppSettings _savedSettings() => AppSettings()
  ..twitchOauthToken = 'oauth:saved_token'
  ..twitchClientId = 'saved_client'
  ..localServerPort = 65432;

Finder _field(String hint) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == hint);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  late _HeldApi api;
  late List<String> events;
  late List<AppSettings> saves;

  setUp(() {
    events = <String>[];
    saves = <AppSettings>[];
    twitchAuth.resetForTest();
  });
  tearDown(twitchAuth.resetForTest);

  Future<void> openSettings(WidgetTester tester, AppSettings settings) async {
    // Built here, inside the test body, and not in setUp: a Completer
    // schedules its completion in the zone it was created in, and setUp runs
    // outside testWidgets' fake-async zone, where pump() never flushes it.
    api = _HeldApi();
    // Big enough that the interaction tests are not about scrolling; the
    // small-window case is the sweep's job.
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => SettingsDialog.show(
              context,
              settings: settings,
              themeNotifier: themeNotifier,
              authenticatedUserLogin: null,
              onRevalidateHelix: () async {},
              onConnectAccount: () => events.add('connect'),
              onSave: (s) {
                saves.add(s);
                events.add('save');
              },
              openExternalLink: (_) {},
              onClearWatchHistory: () {},
              onOpenLogs: () {},
              apiService: api,
            ),
            child: const Text('open settings'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> showTab(WidgetTester tester, String tab) async {
    await tester.ensureVisible(find.text(tab));
    await tester.pump();
    await tester.tap(find.text(tab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  /// The account token's Test button; the browser token's is the second.
  Finder accountTest() => find.text('Test').first;
  Finder browserTest() => find.text('Test').last;

  group('accountTestDescribesSavedToken', () {
    test('the saved pair, as Save would store it', () {
      expect(
          accountTestDescribesSavedToken(_savedSettings(),
              token: '  oauth:saved_token ', clientId: 'saved_client '),
          isTrue,
          reason: 'Save trims, so surrounding whitespace is the same token');
    });

    test('a different token is not the saved one', () {
      expect(
          accountTestDescribesSavedToken(_savedSettings(),
              token: 'oauth:typed', clientId: 'saved_client'),
          isFalse);
    });

    test('the saved token with a different Client ID is a different pair', () {
      // The pairing is the thing being tested: a live token with the wrong
      // Client ID 401s on every Helix call while each field looks fine.
      expect(
          accountTestDescribesSavedToken(_savedSettings(),
              token: 'oauth:saved_token', clientId: 'typed_client'),
          isFalse);
    });
  });

  group('the account Test keeps an unsaved verdict inside the dialog', () {
    testWidgets('a rejected typo does not flag the working saved account',
        (tester) async {
      twitchAuth.setHelix(_validSaved);
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');

      await tester.enterText(_field(_accountTokenHint), 'oauth:a_typo');
      await tapVisible(tester, accountTest());
      expect(api.helixCalls.single, ('oauth:a_typo', 'saved_client'),
          reason: 'the Test must still validate what is typed');

      api.helix.complete(_revoked);
      await _settle(tester);

      expect(find.textContaining('Twitch rejected this token'), findsOneWidget,
          reason: 'the verdict is still shown, in the dialog');
      expect(twitchAuth.helix.value, _validSaved,
          reason: 'every request still sends the saved token, which works');
    });

    testWidgets('a good unsaved token does not clear a rejected saved one',
        (tester) async {
      twitchAuth.setHelix(_revoked);
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');

      await tester.enterText(_field(_accountTokenHint), 'oauth:fresh_token');
      await tapVisible(tester, accountTest());
      api.helix.complete(const TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'fresh_user'));
      await _settle(tester);

      expect(twitchAuth.helix.value, _revoked,
          reason: 'a false recovery fires refreshes with the dead saved token');
      expect(find.textContaining('Save to start using it'), findsOneWidget,
          reason: 'the result has to say it is not in use yet, or it reads as '
              'contradicting the status row above it');
    });

    testWidgets('a test of the saved pair is published app-wide',
        (tester) async {
      // The other half: when the probe IS about the token in use, it is the
      // freshest verdict the app has, and keeping it local would be a loss.
      twitchAuth.setHelix(_validSaved);
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');

      await tapVisible(tester, accountTest());
      api.helix.complete(_revoked);
      await _settle(tester);

      expect(twitchAuth.helix.value, _revoked);
      expect(find.textContaining('Save to start using it'), findsNothing);
    });
  });

  group('closing the dialog under a running Test', () {
    // Cancel, Save and Connect stay enabled while a validation is in flight,
    // and a slow network makes that a window of seconds. The builder is
    // disposed by the time the answer arrives.
    testWidgets('the account Test lands quietly', (tester) async {
      twitchAuth.setHelix(_validSaved);
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');
      await tapVisible(tester, accountTest());

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Account token — followed channels, VOD lists, ad-free'),
          findsNothing,
          reason: 'precondition: the dialog has closed');

      api.helix.complete(_revoked);
      await _settle(tester);

      expect(tester.takeException(), isNull,
          reason: 'setDialogState on a disposed StatefulBuilder throws');
      expect(twitchAuth.helix.value, _validSaved,
          reason: 'a closed dialog publishes nothing: after a Save its '
              'snapshot of the settings is no longer what the app uses');
    });

    testWidgets('the browser Test lands quietly', (tester) async {
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');
      await tapVisible(tester, browserTest());

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      api.browser.complete(const TokenValidationResult(
          isValid: true, message: 'Browser token OK'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
    });
  });
}
