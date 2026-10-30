import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';

/// The notifier's job on top of the pure transitions: remembering which
/// credential pair the current status describes, so a 200 can be told apart
/// as "the same token succeeding at something unscoped" or "a different
/// token".
void main() {
  late TwitchAuth auth;
  final saved = helixCredentialFingerprint('saved-token', 'client-a');
  final pasted = helixCredentialFingerprint('pasted-token', 'client-a');

  const missingScope = TwitchAuthStatus(
    state: TwitchAuthState.invalid,
    fault: TwitchAuthFault.missingScope,
    login: 'mohsenblur',
  );

  setUp(() => auth = TwitchAuth());

  test('the minute poll no longer flips a missing scope to valid', () {
    // Replays the reported loop. The probe diagnoses the missing scope; each
    // minute the poll's unscoped 200s used to read as a recovery.
    auth.noteHelixProbeCredential(saved);
    auth.recordHelixProbe(missingScope);

    final seen = <TwitchAuthStatus>[];
    auth.helix.addListener(() => seen.add(auth.helix.value));
    for (var minute = 0; minute < 5; minute++) {
      auth.recordHelixResponse(200, credential: saved); // helix/streams
      auth.recordHelixResponse(401,
          credential: saved, endpointScopes: kRequiredHelixScopes);
    }

    expect(auth.helix.value.state, TwitchAuthState.invalid);
    expect(auth.helix.value.fault, TwitchAuthFault.missingScope);
    // main.dart's recovery refresh (and its reset of the banner dismissal)
    // keys on an unusable -> usable transition; there must be none.
    expect(seen.where((s) => s.isUsable), isEmpty);
    expect(seen.map((s) => s.fault).toSet(), {TwitchAuthFault.missingScope},
        reason: 'the scoped 401s must not reword it as "revoked"');
  });

  test('a pasted token clears the old diagnosis on its first success', () {
    // Settings saves a new token without resetting the status. The first
    // request made with it is the evidence that matters.
    auth.noteHelixProbeCredential(saved);
    auth.recordHelixProbe(missingScope);

    auth.recordHelixResponse(200, credential: pasted);
    expect(auth.helix.value.state, TwitchAuthState.valid);
    expect(auth.helix.value.login, isNull,
        reason: 'the previous account name does not describe the new token');
  });

  test('a 429 with the new token does not use up the change', () {
    // The first request made with a freshly saved token can be refused for
    // reasons that say nothing about it. Adopting its pair anyway made every
    // later 200 "the same credentials", and the old diagnosis stuck.
    auth.noteHelixProbeCredential(saved);
    auth.recordHelixProbe(missingScope);

    auth.recordHelixResponse(429, credential: pasted);
    auth.recordHelixResponse(503, credential: pasted);
    expect(auth.helix.value, missingScope);

    auth.recordHelixResponse(200, credential: pasted);
    expect(auth.helix.value.isUsable, isTrue);
  });

  test('a re-probe window cannot be healed by an unscoped 200', () {
    // AccountController.probe publishes `checking`, then probes. A poll 200 landing
    // in between used to produce an unusable -> usable edge: the recovery
    // refresh, the followed-list 401, the next forced probe.
    auth.noteHelixProbeCredential(saved);
    auth.recordHelixProbe(missingScope);
    final seen = <TwitchAuthStatus>[];
    auth.helix.addListener(() => seen.add(auth.helix.value));

    auth.setHelix(statusChecking(auth.helix.value));
    auth.recordHelixResponse(200, credential: saved);
    auth.recordHelixTransportError();
    auth.recordHelixResponse(200, credential: saved);

    expect(seen.where((s) => s.isUsable), isEmpty);
    expect(auth.helix.value.state, TwitchAuthState.invalid);
    expect(auth.helix.value.fault, TwitchAuthFault.missingScope);
  });

  test('the first credential ever seen is not treated as a change', () {
    auth.recordHelixProbe(missingScope);
    auth.recordHelixResponse(200, credential: saved);
    expect(auth.helix.value, missingScope);
  });

  test('a response with no credential is never a change', () {
    auth.noteHelixProbeCredential(saved);
    auth.recordHelixProbe(missingScope);
    auth.recordHelixResponse(200);
    expect(auth.helix.value, missingScope);
  });

  test('resetForTest forgets the credential too', () {
    auth.noteHelixProbeCredential(saved);
    auth.resetForTest();
    auth.recordHelixProbe(missingScope);
    auth.recordHelixResponse(200, credential: pasted);
    expect(auth.helix.value, missingScope,
        reason: 'with nothing remembered, the first credential is not a change');
  });
}
