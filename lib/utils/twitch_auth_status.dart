/// What the app actually knows about a Twitch credential.
///
/// This exists because the app used to answer "are we connected?" in three
/// unrelated places that could not agree: the Settings row tested
/// `twitchOauthToken.isNotEmpty`, the Test button validated a *different*
/// token, and the only real evidence — a Helix round trip — was allowed to
/// append a login name but never to take one away. So a revoked token showed
/// a green tick forever while every request 401'd.
///
/// The fix is that one value owns the answer, every response feeds into it,
/// and the UI is not allowed to compute the answer itself.
///
/// Pure and IO-free on purpose: the whole transition table is unit tested,
/// including the two invariants that are easy to break by accident — a
/// network failure must never read as "your token is bad", and a login must
/// never be erased by a failure.
library;

/// The six things that can be true of a credential.
enum TwitchAuthState {
  /// No token stored.
  absent,

  /// A token is stored but has never been checked this run.
  unverified,

  /// A check is in flight. Keeps the previous login so the UI does not flicker.
  checking,

  /// Proved good by /oauth2/validate, or by any Helix 200.
  valid,

  /// Proved bad. **The only state that asks the user to reconnect.**
  invalid,

  /// We could not reach Twitch. Says nothing about the token.
  unreachable,
}

/// Why a token was rejected. Drives the sentence the user reads, because
/// "reconnect" is useless advice for a Client ID mismatch.
enum TwitchAuthFault {
  none,

  /// Twitch rejected it outright: expired, or revoked from the account page.
  revoked,

  /// Live token, but minted for a different Client ID than the one configured.
  /// Produces a 401 on Helix that looks identical to expiry, which is why it
  /// gets its own fault rather than being folded into [revoked].
  clientIdMismatch,

  /// Live token, right client, but missing a scope the app needs.
  missingScope,
}

/// Scopes the Helix calls cannot work without.
const Set<String> kRequiredHelixScopes = <String>{'user:read:follows'};

/// A credential's status. Immutable; replaced wholesale on every transition.
class TwitchAuthStatus {
  const TwitchAuthStatus({
    required this.state,
    this.fault = TwitchAuthFault.none,
    this.login,
    this.tokenClientId,
    this.scopes = const <String>[],
    this.checkedAt,
  });

  final TwitchAuthState state;
  final TwitchAuthFault fault;

  /// The last login this token actually proved. Sticky across [unreachable]
  /// so an offline launch can still say who you were.
  final String? login;

  /// The Client ID /validate says the token was minted for.
  final String? tokenClientId;

  final List<String> scopes;
  final DateTime? checkedAt;

  static const TwitchAuthStatus absent =
      TwitchAuthStatus(state: TwitchAuthState.absent);

  /// Safe to make requests with.
  bool get isUsable => state == TwitchAuthState.valid;

  /// **The one predicate that may raise a reconnect prompt.** Deliberately not
  /// `!isUsable`: unverified, checking and unreachable are all "we don't know",
  /// and telling someone to reconnect because their wifi dropped is how a
  /// warning becomes noise that gets ignored when it is real.
  bool get needsReconnect => state == TwitchAuthState.invalid;

  TwitchAuthStatus copyWith({
    TwitchAuthState? state,
    TwitchAuthFault? fault,
    String? login,
    String? tokenClientId,
    List<String>? scopes,
    DateTime? checkedAt,
  }) =>
      TwitchAuthStatus(
        state: state ?? this.state,
        fault: fault ?? this.fault,
        login: login ?? this.login,
        tokenClientId: tokenClientId ?? this.tokenClientId,
        scopes: scopes ?? this.scopes,
        checkedAt: checkedAt ?? this.checkedAt,
      );

  @override
  bool operator ==(Object other) =>
      other is TwitchAuthStatus &&
      other.state == state &&
      other.fault == fault &&
      other.login == login &&
      other.tokenClientId == tokenClientId &&
      other.checkedAt == checkedAt &&
      _sameScopes(other.scopes, scopes);

  static bool _sameScopes(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(state, fault, login, tokenClientId, checkedAt, scopes.length);

  @override
  String toString() => 'TwitchAuthStatus(${state.name}, ${fault.name}, $login)';
}

/// The token text changed (saved, pasted, cleared, or captured from OAuth).
///
/// Never returns [TwitchAuthState.invalid]: editing a field is not evidence
/// about a server's opinion.
TwitchAuthStatus statusForToken(String rawToken, {String? mintedClientId}) {
  if (rawToken.trim().isEmpty) return TwitchAuthStatus.absent;
  return TwitchAuthStatus(
    state: TwitchAuthState.unverified,
    tokenClientId: mintedClientId,
  );
}

/// A check has started. Holds the previous login so the row does not blank out.
TwitchAuthStatus statusChecking(TwitchAuthStatus current) => TwitchAuthStatus(
      state: TwitchAuthState.checking,
      login: current.login,
      tokenClientId: current.tokenClientId,
      scopes: current.scopes,
      checkedAt: current.checkedAt,
    );

/// `/oauth2/validate` answered. [body] is the decoded JSON, or null if it did
/// not decode.
///
/// This is the only function that can diagnose a Client ID mismatch, because
/// /validate is the only endpoint that reports which client minted the token.
/// The old code decoded `login` and threw `client_id` and `scopes` away, which
/// is precisely why a mismatched token could pass the Test button and then
/// 401 on every real request.
TwitchAuthStatus statusFromValidation({
  required int statusCode,
  required Map<String, dynamic>? body,
  required String configuredClientId,
  required DateTime now,
  TwitchAuthStatus? previous,
}) {
  if (statusCode == 401) {
    return TwitchAuthStatus(
      state: TwitchAuthState.invalid,
      fault: TwitchAuthFault.revoked,
      checkedAt: now,
    );
  }
  if (statusCode != 200 || body == null) {
    // Anything else — 5xx, a proxy's HTML, an undecodable body — is a
    // statement about the network, not about the token.
    return TwitchAuthStatus(
      state: TwitchAuthState.unreachable,
      login: previous?.login,
      tokenClientId: previous?.tokenClientId,
      checkedAt: now,
    );
  }

  final login = body['login'] as String?;
  final tokenClientId = body['client_id'] as String?;
  final scopes = <String>[
    for (final s in (body['scopes'] as List<dynamic>? ?? const <dynamic>[]))
      if (s is String) s,
  ];

  final wanted = configuredClientId.trim();
  if (wanted.isNotEmpty &&
      tokenClientId != null &&
      tokenClientId.isNotEmpty &&
      tokenClientId != wanted) {
    return TwitchAuthStatus(
      state: TwitchAuthState.invalid,
      fault: TwitchAuthFault.clientIdMismatch,
      login: login,
      tokenClientId: tokenClientId,
      scopes: scopes,
      checkedAt: now,
    );
  }

  final missing = kRequiredHelixScopes.difference(scopes.toSet());
  if (missing.isNotEmpty) {
    return TwitchAuthStatus(
      state: TwitchAuthState.invalid,
      fault: TwitchAuthFault.missingScope,
      login: login,
      tokenClientId: tokenClientId,
      scopes: scopes,
      checkedAt: now,
    );
  }

  return TwitchAuthStatus(
    state: TwitchAuthState.valid,
    login: login,
    tokenClientId: tokenClientId,
    scopes: scopes,
    checkedAt: now,
  );
}

/// Any Helix response, from any endpoint.
///
/// This is what closes the hole the bug lived in: every one of the six Helix
/// calls now reports its verdict, so a 401 anywhere flips the state instead of
/// being swallowed into an exception string or a channel marked Offline.
TwitchAuthStatus statusFromHelix(
  TwitchAuthStatus current, {
  required int statusCode,
  required DateTime now,
}) {
  if (statusCode == 200) {
    // A success heals `unverified` and `unreachable` with no extra round trip:
    // the request itself is the proof. The login is left alone — Helix does
    // not tell us who we are here, and a stale name beats no name.
    if (current.state == TwitchAuthState.valid) return current;
    return current.copyWith(
        state: TwitchAuthState.valid,
        fault: TwitchAuthFault.none,
        checkedAt: now);
  }
  if (statusCode == 401 || statusCode == 403) {
    return TwitchAuthStatus(
      state: TwitchAuthState.invalid,
      // Helix cannot distinguish expiry from a Client ID mismatch — both are a
      // bare 401. A follow-up /validate probe refines this; until then the
      // wording has to stay true for either.
      fault: current.fault == TwitchAuthFault.clientIdMismatch
          ? TwitchAuthFault.clientIdMismatch
          : TwitchAuthFault.revoked,
      login: current.login,
      tokenClientId: current.tokenClientId,
      scopes: current.scopes,
      checkedAt: now,
    );
  }
  // 5xx, 429, anything else: Twitch's problem, not the token's.
  return current;
}

/// The request threw rather than answering — timeout, DNS, no route.
///
/// Always [unreachable], never [invalid]. A test pins this, because getting it
/// wrong turns every flaky connection into "your account was disconnected".
TwitchAuthStatus statusFromTransportError(
  TwitchAuthStatus current,
  DateTime now,
) =>
    TwitchAuthStatus(
      state: TwitchAuthState.unreachable,
      login: current.login,
      tokenClientId: current.tokenClientId,
      scopes: current.scopes,
      checkedAt: now,
    );

/// The short line shown beside the status dot.
///
/// Total over every state and fault: the UI must never have to invent copy,
/// which is how the three disagreeing indicators happened in the first place.
String connectionLabel(TwitchAuthStatus s) {
  switch (s.state) {
    case TwitchAuthState.absent:
      return 'Not connected';
    case TwitchAuthState.unverified:
      return 'Not checked yet';
    case TwitchAuthState.checking:
      return 'Checking…';
    case TwitchAuthState.valid:
      return s.login != null && s.login!.isNotEmpty
          ? 'Connected as ${s.login}'
          : 'Connected';
    case TwitchAuthState.unreachable:
      return s.login != null && s.login!.isNotEmpty
          ? "Can't reach Twitch (last connected as ${s.login})"
          : "Can't reach Twitch";
    case TwitchAuthState.invalid:
      switch (s.fault) {
        case TwitchAuthFault.clientIdMismatch:
          return 'Wrong Client ID for this token';
        case TwitchAuthFault.missingScope:
          return 'Missing permission';
        case TwitchAuthFault.revoked:
        case TwitchAuthFault.none:
          return 'Token rejected';
      }
  }
}

/// The explanatory sentence under the label, or null when none is needed.
String? connectionDetail(TwitchAuthStatus s) {
  if (s.state != TwitchAuthState.invalid) return null;
  switch (s.fault) {
    case TwitchAuthFault.clientIdMismatch:
      final minted = s.tokenClientId;
      return 'This token was issued for a different Client ID'
          '${minted != null && minted.isNotEmpty ? ' ($minted)' : ''}. '
          'Reconnect, or restore the Client ID it was created with.';
    case TwitchAuthFault.missingScope:
      return 'This token is missing the follows permission. '
          'Reconnect to grant it.';
    case TwitchAuthFault.revoked:
    case TwitchAuthFault.none:
      return 'Twitch rejected this token. It has expired or been revoked. '
          'Reconnect to sign in again.';
  }
}

/// A user-facing sentence for any error, with no raw API body in it.
///
/// The reported bug showed `{"error":"Unauthorized","status":401,...}` in a
/// snackbar, which is both unreadable and, for a token endpoint, the last
/// thing that should be pasted into UI.
String describeTwitchError(Object error) {
  var text = error.toString();
  if (text.startsWith('Exception: ')) text = text.substring(11);
  final brace = text.indexOf('{');
  if (brace >= 0) text = text.substring(0, brace).trim();
  if (text.endsWith(':')) text = text.substring(0, text.length - 1);
  text = text.trim();
  return text.isEmpty ? 'Twitch request failed' : text;
}
