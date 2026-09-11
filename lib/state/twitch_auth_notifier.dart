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

  /// Feed in any Helix response. Cheap and idempotent, so call sites can do it
  /// unconditionally right after the request.
  void recordHelixResponse(int statusCode) {
    final next = statusFromHelix(helix.value,
        statusCode: statusCode, now: DateTime.now());
    if (next != helix.value) helix.value = next;
  }

  /// The Helix request threw instead of answering.
  void recordHelixTransportError() {
    final next = statusFromTransportError(helix.value, DateTime.now());
    if (next != helix.value) helix.value = next;
  }

  /// A completed `/oauth2/validate` probe of the account token.
  void recordHelixProbe(TwitchAuthStatus status) {
    if (status != helix.value) helix.value = status;
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

  /// Visible for tests.
  @visibleForTesting
  void resetForTest() {
    helix.value = TwitchAuthStatus.absent;
    browser.value = TwitchAuthStatus.absent;
  }
}

/// The app-wide instance.
final TwitchAuth twitchAuth = TwitchAuth();
