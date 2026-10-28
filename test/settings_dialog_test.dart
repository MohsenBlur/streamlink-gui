import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_switch.dart';
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
const _clientIdHint = 'Twitch Client ID';
const _portHint = 'e.g. 65432';

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

  /// When set, onSave does not complete until the test completes it. Created
  /// in the test body, for the zone reason given in openSettings.
  Completer<void>? saveGate;

  setUp(() {
    events = <String>[];
    saves = <AppSettings>[];
    saveGate = null;
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
                return saveGate?.future;
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

    testWidgets('an account Test landing mid-exit publishes nothing',
        (tester) async {
      // The window the test above cannot see. The pop does not unmount the
      // builder: the route animates out first, and context.mounted stays true
      // throughout. A Save that replaced the token, then a probe of the OLD
      // saved token landing in that window, matched the dialog's snapshot and
      // was published as the status of a token the app no longer sends.
      twitchAuth.setHelix(_validSaved);
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');
      await tapVisible(tester, accountTest());
      expect(api.helixCalls.single.$1, 'oauth:saved_token',
          reason: 'precondition: the probe is of the saved pair');

      await tester.enterText(_field(_accountTokenHint), 'oauth:replacement');
      await tester.tap(find.text('Save changes'));
      await tester.pump();
      expect(saves.single.twitchOauthToken, 'oauth:replacement');

      api.helix.complete(_revoked);
      await _settle(tester);
      expect(find.text('Account token — followed channels, VOD lists, ad-free'),
          findsOneWidget,
          reason: 'precondition: still inside the exit animation');
      expect(twitchAuth.helix.value, _validSaved,
          reason: 'the verdict is about a token the app stopped using');

      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
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

  group('closing the dialog straight after typing', () {
    // The pop moves focus, which rebuilds the field that held the caret while
    // the route is still animating out. Disposing the controllers when the
    // dialog's future completed - at the pop - had that rebuild re-subscribe
    // to a disposed controller.
    for (final exit in ['Save changes', 'Cancel']) {
      testWidgets('via $exit', (tester) async {
        await openSettings(tester, _savedSettings());
        await showTab(tester, 'Twitch');
        await tester.enterText(_field(_portHint), '8080');
        await tester.pump();

        await tester.tap(find.text(exit));
        // Through the whole exit transition and the route's removal.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(_field(_portHint), findsNothing,
            reason: 'precondition: the dialog has gone');
        expect(tester.takeException(), isNull,
            reason: 'a field rebuilt against a disposed controller');
      });
    }
  });

  group('Connect Account saves first', () {
    // Connect used to leave the dialog without saving. The sign-in reads the
    // settings the app HOLDS, so a Client ID or port typed a few lines below
    // the button was ignored: the flow bound the old port for the old client,
    // Twitch rejected the redirect, and every other staged edit was lost.
    testWidgets('a typed Client ID and port reach the sign-in', (tester) async {
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');
      await tester.enterText(_field(_clientIdHint), 'my_own_client');
      await tester.enterText(_field(_portHint), '8080');
      await tapVisible(tester, find.text('Connect Account'));
      await _settle(tester);

      expect(events, ['save', 'connect'],
          reason: 'the save has to land before the sign-in reads the settings');
      expect(saves.single.twitchClientId, 'my_own_client');
      expect(saves.single.localServerPort, 8080);
    });

    testWidgets('the sign-in waits for the save to finish', (tester) async {
      // Not merely called first: awaited. A save that has not landed is a
      // sign-in racing the settings it reads.
      saveGate = Completer<void>();
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');
      await tester.enterText(_field(_clientIdHint), 'my_own_client');
      await tapVisible(tester, find.text('Connect Account'));
      await _settle(tester);
      expect(events, ['save']);

      saveGate!.complete();
      await _settle(tester);
      expect(events, ['save', 'connect']);
    });

    testWidgets('with nothing staged it signs in without rewriting the config',
        (tester) async {
      // Saving an unchanged config is not free: main.dart rewrites the file,
      // reloads the followed list and shows its own "saved" snackbar over the
      // sign-in one. The default settings matter here: their accent hex is
      // stored in a shorter form than the dialog writes, so a comparison
      // against the stored settings would call this an edit.
      await openSettings(tester, AppSettings());
      await showTab(tester, 'Twitch');
      await tapVisible(tester, find.text('Connect Account'));
      await _settle(tester);

      expect(events, ['connect']);
      expect(saves, isEmpty);
    });

    testWidgets('an invalid port disables it along with Save', (tester) async {
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Twitch');
      await tester.enterText(_field(_portHint), 'not a port');
      await tester.pump();

      final connect = tester.widget<ButtonStyleButton>(find.ancestor(
          of: find.text('Connect Account'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
      expect(connect.onPressed, isNull,
          reason: 'it would save nothing and listen on a port that is not one');
    });

    testWidgets('a previewed material is saved, not reverted', (tester) async {
      // Connect used to restore the live Appearance edits, which was right for
      // an exit that discarded everything else. An exit that saves has to
      // keep them, or the session and the config disagree the other way.
      final entry = themeNotifier.material;
      addTearDown(() => themeNotifier.setMaterial(entry));
      final other = MaterialSpec.available.firstWhere((m) => m.id != entry);

      await openSettings(tester, _savedSettings());
      await showTab(tester, 'Appearance');
      await tapVisible(tester, find.text(other.name));
      expect(themeNotifier.material, other.id, reason: 'precondition');
      await showTab(tester, 'Twitch');
      await tapVisible(tester, find.text('Connect Account'));
      await _settle(tester);

      expect(saves.single.material, other.id.key);
      expect(themeNotifier.material, other.id);
    });
  });

  group('notification toggles', () {
    // The new-VOD and followed-went-live notifications are opt-out and
    // opt-in respectively; each has its own switch, saved like the others.
    Finder switchFor(String label) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
        matching: find.byType(NeuSwitch));

    testWidgets('new VOD and followed went-live are saved', (tester) async {
      await openSettings(tester, _savedSettings());
      await showTab(tester, 'System');
      expect(tester.widget<NeuSwitch>(switchFor('Favorite channel has a new VOD')).value,
          isTrue);
      expect(tester.widget<NeuSwitch>(switchFor('Followed channel goes live')).value,
          isFalse);

      await tapVisible(tester, switchFor('Favorite channel has a new VOD'));
      await tapVisible(tester, switchFor('Followed channel goes live'));
      await tapVisible(tester, find.text('Save changes'));
      await _settle(tester);

      expect(saves.single.notifyNewVod, isFalse);
      expect(saves.single.notifyFollowedWentLive, isTrue);
    });
  });

  group('PlayerPathCheck', () {
    // testWidgets for its fake clock, so the debounce is a pump. The probe
    // records what it was asked and answers only when told to.
    late List<String> probed;
    late List<Completer<bool>> answers;
    late int settled;

    PlayerPathCheck check({String path = '', bool exists = false}) {
      probed = <String>[];
      answers = <Completer<bool>>[];
      settled = 0;
      return PlayerPathCheck(
        path: path,
        exists: exists,
        probe: (p) {
          probed.add(p);
          final answer = Completer<bool>();
          answers.add(answer);
          return answer.future;
        },
      );
    }

    void onSettled() => settled++;
    const debounce = Duration(milliseconds: 350);

    testWidgets('rebuilds and unchanged text never stat the disk',
        (tester) async {
      // The defect: six stats per rebuild, and a slider drag is dozens of
      // rebuilds a second.
      final c = check(path: r'C:\mpv\mpv.exe', exists: true);
      for (var i = 0; i < 50; i++) {
        c.update(r'C:\mpv\mpv.exe', onSettled);
      }
      c.update(r'  C:\mpv\mpv.exe  ', onSettled);
      await tester.pump(const Duration(seconds: 1));

      expect(probed, isEmpty);
      expect(c.exists, isTrue, reason: 'the verdict from opening still holds');
    });

    testWidgets('a burst of keystrokes is checked once, where it stopped',
        (tester) async {
      final c = check();
      const typed = r'C:\mpv\mpv.exe';
      for (var i = 1; i <= typed.length; i++) {
        c.update(typed.substring(0, i), onSettled);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(probed, isEmpty, reason: 'nothing is checked mid-word');
      expect(c.exists, isNull, reason: 'and nothing is claimed either');

      await tester.pump(debounce);
      expect(probed, [typed]);
      answers.single.complete(true);
      await tester.pump();
      expect(c.exists, isTrue);
      expect(settled, 1);
    });

    testWidgets('a verdict for a path since replaced is dropped',
        (tester) async {
      // A slow share answers late. By then the field says something else,
      // and the old answer is about a path nobody is looking at.
      final c = check();
      c.update('first', onSettled);
      await tester.pump(debounce);
      c.update('second', onSettled);
      answers.first.complete(true);
      await tester.pump();
      expect(c.exists, isNull);
      expect(settled, 0);

      await tester.pump(debounce);
      expect(probed, ['first', 'second']);
      answers.last.complete(false);
      await tester.pump();
      expect(c.exists, isFalse);
      expect(settled, 1);
    });

    testWidgets('a closed dialog takes no verdict', (tester) async {
      final c = check();
      c.update('in flight', onSettled);
      await tester.pump(debounce);
      c.update('never checked', onSettled);
      c.dispose();
      answers.single.complete(true);
      await tester.pump(const Duration(seconds: 1));

      expect(probed, ['in flight'], reason: 'the pending check was cancelled');
      expect(settled, 0, reason: 'onSettled would rebuild a disposed builder');
    });

    testWidgets('a probe that throws reads as missing', (tester) async {
      final c = PlayerPathCheck(
          path: '', exists: false, probe: (_) => throw const FileSystemException());
      c.update(r'\\offline\share\mpv.exe', onSettled);
      await tester.pump(debounce);
      await tester.pump();
      expect(c.exists, isFalse);
    });

    testWidgets('an emptied field needs no stat', (tester) async {
      final c = check(path: r'C:\mpv\mpv.exe', exists: true);
      c.update('   ', onSettled);
      await tester.pump(const Duration(seconds: 1));
      expect(probed, isEmpty);
      expect(c.path, isEmpty);
      expect(c.exists, isFalse);
    });

    test('the dialog itself never stats synchronously', () {
      // The class above is only the fix if the dialog goes through it. A
      // build-time existsSync is the exact defect, and one line brings it
      // back. Comments are skipped, since they describe the old code.
      final code = File('lib/widgets/settings_dialog.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'));
      expect(code.where((l) => l.contains('existsSync')), isEmpty,
          reason: 'a synchronous stat in this dialog runs on every rebuild');
    });

    test('it names the file the launcher would actually run', () {
      // The indicator is only useful if it is about the same file. Explorer's
      // "Copy as path" adds quotes; the launcher strips them, and the old
      // check did not, so a working player was labelled "File not found".
      for (final raw in const [
        r'"C:\Program Files\mpv\mpv.exe"',
        r'  C:\mpv\mpv.exe  ',
        r' "C:\a folder\mpv.exe" ',
      ]) {
        expect(
            PlayerPathCheck.normalize(raw),
            PlayerService().resolvePlayerExecutable(
                'custom', AppSettings()..customPlayerPath = raw),
            reason: raw);
      }
    });
  });

  group('the custom player path in the dialog', () {
    testWidgets('is checked once the typing stops, and says so meanwhile',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('settings_player_path');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sep = Platform.pathSeparator;
      final player = File('${dir.path}${sep}mpv.exe')..createSync();
      final missing = '${dir.path}${sep}not-here.exe';

      await openSettings(tester, AppSettings()..playerType = 'custom');
      final field = _field(r'e.g. C:\Program Files\MPV\mpv.exe');

      Future<void> typeAndWait(String text) async {
        await tester.enterText(field, text);
        await tester.pump();
        expect(find.text('Checking path...'), findsOneWidget,
            reason: 'no verdict is claimed for a path not yet checked');
        await tester.pump(const Duration(milliseconds: 400));
        // The stat is real IO: give the event loop turns to deliver it.
        for (var i = 0;
            i < 50 && find.text('Checking path...').evaluate().isNotEmpty;
            i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await _settle(tester);
        }
      }

      await typeAndWait(missing);
      expect(find.text('File not found at this path'), findsOneWidget);

      await typeAndWait('"${player.path}"');
      expect(find.text('Executable found'), findsOneWidget,
          reason: 'a quoted path is one the launcher runs');
    });
  });
}
