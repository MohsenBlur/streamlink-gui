import 'package:flutter/foundation.dart';

import '../utils/twitch_auth_status.dart';

/// Live connection status for the app's two Twitch credentials.
///
/// Two notifiers of the *same* shape, deliberately. The bug this replaces was
/// that the two tokens were reported by unrelated machinery — one by a
/// string-emptiness check, the other by a Test button — so a passing browser
/// token read as "everything is connected" while the account token was dead.
/// With one type and two instances, every UI that shows a status has to say
/// which credential it is talking about, and the success message for one can
/// never be mistaken for the other.
///
/// A global, following `storageWriteFailure` in `storage_service.dart`: the
/// API service has no route to the widget tree and must be able to report a
/// 401 from anywhere without threading a callback through six call sites.
class TwitchAuth {
  /// The account token: Helix, followed channels, VOD lists.
  final ValueNotifier<TwitchAuthStatus> helix =
      ValueNotifier<TwitchAuthStatus>(TwitchAuthStatus.absent);

  /// The browser token: VOD watch-progress sync only.
  final ValueNotifier<TwitchAuthStatus> browser =
      ValueNotifier<TwitchAuthStatus>(TwitchAuthStatus.absent);

  /// Fingerprint of the token + Client ID pair the [helix] evidence was last
  /// gathered with. Never the token itself.
  ///
  /// Kept so a Helix 200 can tell "the same credentials succeeded at something
  /// that does not need the missing permission" (no news) from "different
  /// credentials succeeded" (a new answer). Settings saves a pasted token
  /// without resetting the status, so without this a fault diagnosed for the
  /// old token could only be cleared by reopening Settings.
  int? _helixCredential;

  /// Feed in any Helix response. Cheap and idempotent, so call sites can do it
  /// unconditionally right after the request.
  ///
  /// [credential] identifies the token + Client ID the request was sent with
  /// (see [helixCredentialFingerprint]); [endpointScopes] are the scopes the
  /// endpoint itself requires, which is all a 200 from it can prove.
  ///
  /// Only a response that is a verdict on the token (200, 401, 403) moves the
  /// remembered pair. A 429 or a 5xx sent with a newly saved token changes
  /// nothing, so letting it adopt the new pair would spend the "different
  /// credentials" signal on nothing: every later 200 would then count as the
  /// same pair, and an old diagnosis would outlive the token it described.
  void recordHelixResponse(
    int statusCode, {
    int? credential,
    Set<String> endpointScopes = const <String>{},
  }) {
    final isVerdict =
        statusCode == 200 || statusCode == 401 || statusCode == 403;
    final next = statusFromHelix(
      helix.value,
      statusCode: statusCode,
      now: DateTime.now(),
      endpointScopes: endpointScopes,
      credentialsChanged: isVerdict && _noteCredential(credential),
    );
    if (next != helix.value) helix.value = next;
  }

  /// The Helix request threw instead of answering.
  void recordHelixTransportError() {
    final next = statusFromTransportError(helix.value, DateTime.now());
    if (next != helix.value) helix.value = next;
  }

  /// A completed `/oauth2/validate` probe of the account token. [credential]
  /// names the pair it probed (see [noteHelixProbeCredential]).
  void recordHelixProbe(TwitchAuthStatus status, {int? credential}) {
    if (credential != null) noteHelixProbeCredential(credential);
    if (status != helix.value) helix.value = status;
  }

  /// A probe is about to report on [credential]: whatever it publishes next
  /// describes that pair, so later Helix responses are compared against it.
  void noteHelixProbeCredential(int credential) {
    _helixCredential = credential;
  }

  void setHelix(TwitchAuthStatus status) {
    if (status != helix.value) helix.value = status;
  }

  void setBrowser(TwitchAuthStatus status) {
    if (status != browser.value) browser.value = status;
  }

  /// The GQL progress calls answered 401.
  void recordBrowserExpired() {
    setBrowser(TwitchAuthStatus(
      state: TwitchAuthState.invalid,
      fault: TwitchAuthFault.revoked,
      login: browser.value.login,
      checkedAt: DateTime.now(),
    ));
  }

  /// True when [credential] differs from the pair the status was last
  /// established for. The first credential ever seen is not a change: there
  /// is nothing to contradict yet.
  bool _noteCredential(int? credential) {
    if (credential == null) return false;
    final previous = _helixCredential;
    _helixCredential = credential;
    return previous != null && previous != credential;
  }

  /// Visible for tests.
  @visibleForTesting
  void resetForTest() {
    helix.value = TwitchAuthStatus.absent;
    browser.value = TwitchAuthStatus.absent;
    _helixCredential = null;
  }
}

/// Identifies a token + Client ID pair without keeping the token.
///
/// Only compared within one process, so [Object.hash]'s per-run seed is fine.
int helixCredentialFingerprint(String token, String clientId) =>
    Object.hash(token, clientId);

/// The app-wide instance.
final TwitchAuth twitchAuth = TwitchAuth();
