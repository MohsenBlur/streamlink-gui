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
      final src = read('lib/main.dart');
      expect(src, isNot(contains(r"'Error loading followed channels: $e'")),
          reason: 'this is the line that showed the user a JSON blob');
      expect(src, contains('describeTwitchError('));
    });
  });

  group('recovering from a rejection refreshes what it made stale', () {
    // Reconnecting used to reload only the followed list, so every favourite
    // kept the error text stamped on it during the outage - "Helix Stream API
    // error: status 401" sat on the open channel until the one-minute poll
    // happened to clear it, minutes after the account was working again.
    test('the auth status drives a refresh of both lists and the open VODs', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src, contains('_onAuthStatusChanged'));
      final start = src.indexOf('void _onAuthStatusChanged()');
      expect(start, greaterThan(-1));
      final body = src.substring(start, start + 1400);
      expect(body, contains('_refreshAllChannels('),
          reason: 'the favourites carry the stale per-channel error');
      expect(body, contains('_loadFollowedChannels('));
      expect(body, contains('_fetchVodsForChannel('),
          reason: 'the open VOD grid holds its own stale 401');
    });

    test('the listener is attached and detached', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src, contains('twitchAuth.helix.addListener(_onAuthStatusChanged)'));
      expect(src, contains('twitchAuth.helix.removeListener(_onAuthStatusChanged)'),
          reason: 'a listener on a global notifier outlives the widget otherwise');
    });
  });

  test('a rejected account token raises a banner with a remedy on it', () {
    final src = read('lib/main.dart');
    expect(src, contains('_buildTwitchAuthBanner'));
    // The remedy has to be ON the banner. Describing the fix and making the
    // user go find it is what turns a warning into noise.
    final banner = src.substring(src.indexOf('Widget _buildTwitchAuthBanner'));
    final body = banner.substring(0, banner.indexOf('void _showSaveFailureDetail'));
    expect(body, contains('Reconnect'));
    expect(body, contains('_startOAuthServer'));
  });
}
