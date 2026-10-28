import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the shape of the fix, not its behaviour — the behaviour lives in
/// `twitch_auth_status_test.dart`.
///
/// A source scan because the Settings dialog cannot be pumped in isolation
/// (the same reason `settings_tabs_test.dart` gives). What is being prevented
/// here is a regression that is invisible at runtime until a token expires,
/// which is weeks after the change that caused it: an indicator that reports
/// on the existence of a string instead of on what Twitch said, and a success
/// message that does not name the credential it tested.
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('the connection indicator cannot go back to lying', () {
    test('no green tick keyed on token emptiness', () {
      final src = read('lib/widgets/settings_dialog.dart');
      // The original defect, verbatim: `isNotEmpty ? Icons.check_circle`.
      // An expired token is a non-empty string, so this could only ever
      // report "a token is configured", never "the account works".
      expect(
        RegExp(r'twitchOauthToken[^\n]*isNotEmpty[^\n]*check_circle')
            .hasMatch(src),
        isFalse,
        reason: 'the status icon must reflect a Twitch verdict, not a string length',
      );
    });

    test('the status row reads the auth notifier', () {
      final src = read('lib/widgets/settings_dialog.dart');
      expect(src, contains('twitchAuth.helix'));
      expect(src, contains('connectionLabel('));
    });
  });

  group('the two tokens are distinguishable', () {
    test('each token has its own test call', () {
      final src = read('lib/widgets/settings_dialog.dart');
      expect(src, contains('validateHelixToken('),
          reason: 'the account token needs a test of its own');
      expect(src, contains('validateOAuthToken('),
          reason: 'the browser token keeps its test');
    });

    test('neither success message is shared or unnamed', () {
      final api = read('lib/services/twitch_api_service.dart');
      // This exact string was shown for the BROWSER token and read as
      // "everything is connected".
      expect(api, isNot(contains("Success! Connected as:")),
          reason: 'a success message must name which credential passed');
      expect(api, contains('Browser token OK'));

      final src = read('lib/widgets/settings_dialog.dart');
      expect(src, contains('Account token OK'));
    });

    test('the field labels say what each token is for', () {
      final src = read('lib/widgets/settings_dialog.dart');
      expect(src, contains('Account token'));
      expect(src, contains('Browser token'));
    });
  });

  group('raw API bodies do not reach the UI', () {
    test('helix failures throw a typed error, not an interpolated body', () {
      final api = read('lib/services/twitch_api_service.dart');
      for (final leak in const [
        r"Failed to get user profile: ${userRes.body}",
        r"Failed to get followed channels: ${followsRes.body}",
      ]) {
        expect(api, isNot(contains(leak)),
            reason: 'a 401 body in an exception message ends up in a snackbar');
      }
      expect(api, contains('TwitchApiException'));
    });

    test('the followed-channels catch does not interpolate the error raw', () {
      // The followed list loads in AccountController now; that a server
      // error reaches the user as a sentence is main_screen_account_test's.
      final src = read('lib/state/account_controller.dart');
      expect(src, isNot(contains(r"'Error loading followed channels: $e'")),
          reason: 'this is the line that showed the user a JSON blob');
      expect(src,
          contains(r"'Could not load followed channels: ${describeTwitchError(e)}'"));
    });
  });

  // What a token that starts working again refreshes, and that the listener
  // behind it comes off with the screen, were source scans of main.dart.
  // They are behaviour now: main_screen_account_test ('a token that starts
  // working again refreshes the channels, the followed list and the open VOD
  // list...') and account_controller_test.

  test('a rejected account token raises a banner with a remedy on it', () {
    // The remedy has to be ON the banner. Describing the fix and making the
    // user go find it is what turns a warning into noise. That the banner
    // shows is main_screen_test's; this is what its button does.
    final banners = read('lib/widgets/shell/status_banners.dart');
    final banner = banners.substring(
        banners.indexOf('class TwitchAuthBanner'),
        banners.indexOf('void showSaveFailureDetail'));
    expect(banner, contains("Text('Reconnect'"));
    expect(banner, contains('onPressed: onReconnect'));
    // That the screen's Reconnect starts a sign-in is
    // main_screen_account_test's.
  });
}
