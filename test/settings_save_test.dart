import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/startup_service.dart';
import 'package:streamlink_gui/state/settings_save.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';

class _RecordingStartup extends StartupService {
  _RecordingStartup(this.calls);
  final List<String> calls;

  @override
  Future<void> sync(bool enabled) async => calls.add('startup $enabled');
}

/// Saving Settings on its own: what counts as a change, and the order the
/// consequences go in. The screen's side is main_screen_settings_test.
void main() {
  setUp(twitchAuth.resetForTest);
  tearDown(twitchAuth.resetForTest);

  AppSettings settings({
    String token = 'oauth:a',
    String clientId = '',
    String browser = '',
    bool startup = false,
    bool canvas = false,
  }) =>
      AppSettings(
        twitchOauthToken: token,
        twitchClientId: clientId,
        twitchWebOauthToken: browser,
        launchAtStartup: startup,
        canvasEngine: canvas,
      );

  group('SettingsChange', () {
    test('compares the credentials as typed, give or take spaces', () {
      final same = SettingsChange.between(
          settings(token: 'oauth:a'), settings(token: ' oauth:a '));
      expect(same.accountTokenChanged, isFalse);
      expect(same.helixChanged, isFalse);

      final client = SettingsChange.between(
          settings(), settings(clientId: 'mine'));
      expect(client.accountTokenChanged, isFalse);
      expect(client.helixChanged, isTrue,
          reason: 'requests go out with the new Client ID');

      final browser =
          SettingsChange.between(settings(), settings(browser: 'b'));
      expect(browser.browserTokenChanged, isTrue);
      expect(browser.helixChanged, isFalse);
    });

    test('Simple rendering counts only when turned on', () {
      expect(
          SettingsChange.between(settings(), settings(canvas: true))
              .canvasEngineTurnedOn,
          isTrue);
      expect(
          SettingsChange.between(settings(canvas: true), settings())
              .canvasEngineTurnedOn,
          isFalse,
          reason: 'turning it off waits for the next launch');
    });
  });

  group('SettingsSaveCoordinator', () {
    late AppSettings current;
    late List<String> calls;
    var mounted = true;

    SettingsSaveCoordinator coordinator() => SettingsSaveCoordinator(
          settings: () => current,
          adopt: (updated) {
            calls.add('adopt');
            current = updated;
          },
          save: () async => calls.add('save'),
          mounted: () => mounted,
          auth: twitchAuth,
          probeAccount: () async => calls.add('probe'),
          forgetFollowed: () => calls.add('forget followed'),
          startup: _RecordingStartup(calls),
          rebuildTrayMenu: () => calls.add('tray'),
          loadFollowed: () => calls.add('load followed'),
          signedOut: () => calls.add('signed out'),
          canvasTurnedOn: () => calls.add('canvas'),
          showMessage: (m) => calls.add(m),
        );

    setUp(() {
      calls = [];
      mounted = true;
      current = settings();
    });

    test('another account token: adopted and written, then everything '
        'follows from the new one', () async {
      twitchAuth.setHelix(const TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'old'));
      await coordinator().save(settings(token: 'oauth:b', startup: true));
      expect(calls, [
        'adopt',
        'save',
        'probe',
        'forget followed',
        'startup true',
        'tray',
        'load followed',
        'Settings saved successfully!',
      ]);
      expect(twitchAuth.helix.value.login, isNot('old'));
    });

    test('an unchanged save reloads the followed list and nothing else',
        () async {
      await coordinator().save(settings());
      expect(calls, [
        'adopt',
        'save',
        'tray',
        'load followed',
        'Settings saved successfully!',
      ]);
    });

    test('no account token signs out; Simple rendering switches first',
        () async {
      await coordinator().save(settings(token: '', canvas: true));
      expect(calls, [
        'canvas',
        'adopt',
        'save',
        'probe',
        'forget followed',
        'tray',
        'signed out',
        'Settings saved successfully!',
      ]);
      expect(twitchAuth.helix.value.state, TwitchAuthState.absent);
    });

    test('a browser token is described from what it looks like', () async {
      await coordinator().save(settings(browser: 'oauth:browser'));
      expect(twitchAuth.browser.value.state,
          statusForToken('oauth:browser').state);
    });

    test('nothing follows a save the screen did not outlive', () async {
      mounted = false;
      await coordinator().save(settings(token: 'oauth:b'));
      expect(calls, ['adopt', 'save']);
    });
  });
}
