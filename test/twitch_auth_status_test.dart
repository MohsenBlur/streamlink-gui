import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';

/// The state machine behind "are we actually connected?".
///
/// It exists because the app used to answer that question in three places that
/// could not agree, and the one place with real evidence — a Helix response —
/// was only allowed to add good news. A revoked token therefore showed a green
/// tick forever while every request 401'd.
///
/// Two invariants here matter more than the rest, because breaking either one
/// re-creates a bug that is worse than the original: a network failure must
/// never read as "your token is bad" (that trains people to ignore the
/// warning), and a login must never be erased by a failure.
void main() {
  final now = DateTime(2026, 9, 11, 12);
  const clientId = 'abc123';

  Map<String, dynamic> validBody({
    String login = 'mohsenblur',
    String? client = clientId,
    List<String> scopes = const ['user:read:follows'],
  }) =>
      {'login': login, 'client_id': client, 'scopes': scopes};

  group('validation probe', () {
    test('a good token, right client, right scopes, is valid', () {
      final s = statusFromValidation(
          statusCode: 200,
          body: validBody(),
          configuredClientId: clientId,
          now: now);
      expect(s.state, TwitchAuthState.valid);
      expect(s.isUsable, isTrue);
      expect(s.needsReconnect, isFalse);
      expect(s.login, 'mohsenblur');
    });

    test('401 is invalid/revoked', () {
      final s = statusFromValidation(
          statusCode: 401, body: null, configuredClientId: clientId, now: now);
      expect(s.state, TwitchAuthState.invalid);
      expect(s.fault, TwitchAuthFault.revoked);
      expect(s.needsReconnect, isTrue);
    });

    test('a LIVE token minted for another client is invalid, not valid', () {
      // The case that made the Test button and the banner disagree: Twitch
      // says 200 because the token is real, but every Helix call pairs it with
      // a different Client-Id and gets a bare 401. Before this, /validate's
      // client_id was decoded and thrown away, so the one diagnosable failure
      // mode was undiagnosable.
      final s = statusFromValidation(
          statusCode: 200,
          body: validBody(client: 'a-different-client'),
          configuredClientId: clientId,
          now: now);
      expect(s.state, TwitchAuthState.invalid);
      expect(s.fault, TwitchAuthFault.clientIdMismatch);
      expect(s.tokenClientId, 'a-different-client');
      expect(connectionDetail(s), contains('different Client ID'));
    });

    test('a live token missing the follows scope is invalid', () {
      final s = statusFromValidation(
          statusCode: 200,
          body: validBody(scopes: const []),
          configuredClientId: clientId,
          now: now);
      expect(s.state, TwitchAuthState.invalid);
      expect(s.fault, TwitchAuthFault.missingScope);
    });

    test('a blank configured client id does not trigger a mismatch', () {
      // Nothing to disagree with. Reporting a mismatch here would send the
      // user to fix a field that is empty on purpose.
      final s = statusFromValidation(
          statusCode: 200,
          body: validBody(client: 'whatever'),
          configuredClientId: '   ',
          now: now);
      expect(s.state, TwitchAuthState.valid);
    });

    test('a 5xx is unreachable and keeps the known login', () {
      final prev = TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'mohsenblur', checkedAt: now);
      final s = statusFromValidation(
          statusCode: 503,
          body: null,
          configuredClientId: clientId,
          now: now,
          previous: prev);
      expect(s.state, TwitchAuthState.unreachable);
      expect(s.needsReconnect, isFalse,
          reason: 'Twitch being down is not the user having to reconnect');
      expect(s.login, 'mohsenblur');
    });

    test('an undecodable body is unreachable, not invalid', () {
      // A captive portal or proxy returning HTML with a 200. Believing it
      // would tell the user their account was disconnected by a hotel wifi.
      final s = statusFromValidation(
          statusCode: 200,
          body: null,
          configuredClientId: clientId,
          now: now);
      expect(s.state, TwitchAuthState.unreachable);
    });
  });

  group('helix responses', () {
    test('a 401 anywhere flips the state to invalid', () {
      const before = TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'mohsenblur');
      final s = statusFromHelix(before, statusCode: 401, now: now);
      expect(s.state, TwitchAuthState.invalid);
      expect(s.needsReconnect, isTrue);
      expect(s.login, 'mohsenblur', reason: 'a failure must not erase who you were');
    });

    test('403 is treated as an auth failure too', () {
      final s = statusFromHelix(TwitchAuthStatus.absent,
          statusCode: 403, now: now);
      expect(s.state, TwitchAuthState.invalid);
    });

    test('a 200 heals unverified with no extra round trip', () {
      const before = TwitchAuthStatus(state: TwitchAuthState.unverified);
      final s = statusFromHelix(before, statusCode: 200, now: now);
      expect(s.state, TwitchAuthState.valid);
    });

    test('a 200 heals unreachable and keeps the login', () {
      const before = TwitchAuthStatus(
          state: TwitchAuthState.unreachable, login: 'mohsenblur');
      final s = statusFromHelix(before, statusCode: 200, now: now);
      expect(s.state, TwitchAuthState.valid);
      expect(s.login, 'mohsenblur');
    });

    test('a 500 changes nothing', () {
      const before = TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'mohsenblur');
      expect(statusFromHelix(before, statusCode: 500, now: now), before);
    });

    test('a mismatch diagnosis survives a subsequent 401', () {
      // Helix cannot tell expiry from a mismatch, so it must not overwrite the
      // more specific answer /validate already produced - otherwise the advice
      // degrades from "fix your Client ID" to "reconnect", which cannot work.
      const before = TwitchAuthStatus(
          state: TwitchAuthState.invalid,
          fault: TwitchAuthFault.clientIdMismatch);
      final s = statusFromHelix(before, statusCode: 401, now: now);
      expect(s.fault, TwitchAuthFault.clientIdMismatch);
    });
  });

  group('transport failures never accuse the token', () {
    test('a thrown error is unreachable, never invalid', () {
      const before = TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'mohsenblur');
      final s = statusFromTransportError(before, now);
      expect(s.state, TwitchAuthState.unreachable);
      expect(s.needsReconnect, isFalse);
      expect(s.login, 'mohsenblur');
    });

    test('needsReconnect is true in exactly one state', () {
      for (final state in TwitchAuthState.values) {
        final s = TwitchAuthStatus(state: state);
        expect(s.needsReconnect, state == TwitchAuthState.invalid,
            reason: '$state must not ask the user to reconnect');
      }
    });
  });

  group('token edits', () {
    test('an empty token is absent, not invalid', () {
      expect(statusForToken('   ').state, TwitchAuthState.absent);
    });

    test('a pasted token is unverified - editing a field proves nothing', () {
      final s = statusForToken('oauth:abc', mintedClientId: clientId);
      expect(s.state, TwitchAuthState.unverified);
      expect(s.isUsable, isFalse);
      expect(s.needsReconnect, isFalse);
      expect(s.tokenClientId, clientId);
    });

    test('checking keeps the previous login so the row does not blank', () {
      const prev = TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'mohsenblur');
      final s = statusChecking(prev);
      expect(s.state, TwitchAuthState.checking);
      expect(s.login, 'mohsenblur');
    });
  });

  group('copy', () {
    test('connectionLabel is total over every state and fault', () {
      for (final state in TwitchAuthState.values) {
        for (final fault in TwitchAuthFault.values) {
          final label = connectionLabel(TwitchAuthStatus(state: state, fault: fault));
          expect(label, isNotEmpty);
        }
      }
    });

    test('only invalid states carry a reason sentence', () {
      for (final state in TwitchAuthState.values) {
        final detail = connectionDetail(TwitchAuthStatus(state: state));
        expect(detail == null, state != TwitchAuthState.invalid,
            reason: '$state should${state == TwitchAuthState.invalid ? '' : ' not'} explain itself');
      }
    });

    test('valid without a login still reads as connected', () {
      expect(connectionLabel(const TwitchAuthStatus(state: TwitchAuthState.valid)),
          'Connected');
    });
  });

  group('describeTwitchError strips API bodies', () {
    test('a raw Twitch 401 body never reaches the user', () {
      // The reported symptom, verbatim.
      final msg = describeTwitchError(Exception(
          'Failed to get user profile: {"error":"Unauthorized","status":401,"message":"Invalid OAuth token"}'));
      expect(msg, isNot(contains('{')));
      expect(msg, isNot(contains('Exception:')));
      expect(msg, isNot(contains('Unauthorized')));
      expect(msg, 'Failed to get user profile');
    });

    test('an ordinary message survives intact', () {
      expect(describeTwitchError(Exception('Network unreachable')),
          'Network unreachable');
    });

    test('a body-only error still yields a sentence', () {
      expect(describeTwitchError(Exception('{"error":"x"}')),
          'Twitch request failed');
    });
  });
}
