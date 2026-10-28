import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../state/twitch_auth_notifier.dart';
import '../utils/twitch_auth_status.dart';
import '../models/twitch_video.dart';

class FollowedChannelsResult {
  final List<TwitchChannel> channels;
  final String userLogin;
  final String? userAvatar;

  /// False when the walk stopped before Twitch's last page: a later page
  /// failed ([pageError] says how), or the page cap was reached ([pageError]
  /// is null).
  ///
  /// A failed later page used to end the walk silently, and the caller
  /// replaced its whole list with the shortened one: someone following 350
  /// channels lost 150 from the Followed tab, the tray and Live, with no sign
  /// anything had gone wrong.
  final bool isComplete;

  /// What stopped the walk early: a [TwitchApiException] (a
  /// [TwitchRateLimitedException] for a 429), or the transport error. Never an
  /// auth failure - a refused token throws instead, however many pages were
  /// already in, because that is the banner's to explain.
  final Object? pageError;

  FollowedChannelsResult({
    required this.channels,
    required this.userLogin,
    this.userAvatar,
    this.isComplete = true,
    this.pageError,
  });

  /// The list to show in place of [previous].
  ///
  /// A channel already in [previous] keeps its object, so its avatar, live
  /// state and failure count survive the reload, and a selected channel is
  /// not left pointing at an object nothing refreshes any more. A complete
  /// result is the truth about who is followed, so channels missing from it
  /// go. An incomplete one is not: channels it never reached are kept from
  /// [previous] rather than dropped.
  List<TwitchChannel> reconcileWith(List<TwitchChannel> previous) {
    final byName = {for (final c in previous) c.username: c};
    final merged = <TwitchChannel>[];
    final placed = <String>{};
    for (final fresh in channels) {
      if (!placed.add(fresh.username)) continue;
      final kept = byName[fresh.username];
      if (kept == null) {
        merged.add(fresh);
        continue;
      }
      if (isValidTwitchUserId(fresh.id)) kept.id = fresh.id;
      merged.add(kept);
    }
    if (!isComplete) {
      for (final old in previous) {
        if (placed.add(old.username)) merged.add(old);
      }
    }
    return merged;
  }
}

class VodsFetchResult {
  final List<TwitchVideo> vods;
  final String? nextCursor;
  final bool isWebTokenExpired;
  VodsFetchResult({required this.vods, this.nextCursor, this.isWebTokenExpired = false});
}

class TokenValidationResult {
  final bool isValid;
  final String message;
  final String? login;

  /// The Client ID the token was minted for, and the scopes it carries.
  ///
  /// Both were decoded and thrown away until v1.9.1. That discard is exactly
  /// why a token minted for a different Client ID passed the Test button and
  /// then 401'd on every real request: /oauth2/validate is the ONLY endpoint
  /// that reports the minting client, so discarding it made the one
  /// diagnosable failure mode undiagnosable.
  final String? clientId;
  final List<String> scopes;
  final int? statusCode;

  const TokenValidationResult({
    required this.isValid,
    required this.message,
    this.login,
    this.clientId,
    this.scopes = const <String>[],
    this.statusCode,
  });
}

/// A Twitch API call that did not return 200.
///
/// Carries the body for the log without inviting it into the UI: the reported
/// bug put a raw `{"error":"Unauthorized",...}` blob in a snackbar because the
/// only thing available to print was an exception whose message WAS the body.
class TwitchApiException implements Exception {
  TwitchApiException(this.statusCode, this.endpoint, this.body);

  final int statusCode;
  final String endpoint;
  final String body;

  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'Twitch API returned $statusCode for $endpoint';
}

/// Twitch answered 429, or a request was held back because the host is still
/// inside the back-off a previous response asked for.
///
/// Its own type because it is the one failure that says nothing about the
/// channel being asked about: the Helix bucket is per token, so once it is
/// empty every request is refused until it refills. A 429 used to surface as
/// "Helix Stream API error: status 429" and count toward the channel's
/// consecutive failures, which is how a large followed list flapped offline.
class TwitchRateLimitedException extends TwitchApiException {
  TwitchRateLimitedException(String endpoint, this.retryAt, {String body = ''})
      : super(429, endpoint, body);

  /// When requests to this host may resume.
  final DateTime retryAt;

  @override
  String toString() =>
      'Twitch is rate limiting requests to $endpoint; try again shortly';
}

/// How one channel's refresh ended.
///
/// Returned rather than inferred from `errorMessage`, because a rate-limited
/// refresh must not be treated like either of the other two: nothing was
/// learned about the channel, and nothing went wrong with it.
enum ChannelRefreshOutcome {
  /// Fresh data was applied and the failure count reset.
  updated,

  /// The request failed for this channel; it counts toward going offline.
  failed,

  /// Twitch's rate limit refused the request. The channel keeps the state it
  /// had, and its consecutive-failure count is left alone.
  rateLimited,
}

/// What [TwitchApiService.refreshLiveStatus] did with each channel.
class ChannelsRefreshResult {
  ChannelsRefreshResult(this.outcomes, {this.rateLimitedUntil});

  /// One entry per distinct channel object passed in, keyed by identity
  /// (TwitchChannel has no value equality): a favourite and the followed-list
  /// object for the same streamer are two entries.
  final Map<TwitchChannel, ChannelRefreshOutcome> outcomes;

  /// Set when the pass ended with the host backing off: the earliest time a
  /// new pass would not simply be refused.
  final DateTime? rateLimitedUntil;

  bool get wasRateLimited =>
      outcomes.values.contains(ChannelRefreshOutcome.rateLimited);

  Iterable<TwitchChannel> get failed => outcomes.entries
      .where((e) => e.value == ChannelRefreshOutcome.failed)
      .map((e) => e.key);
}

/// The longest any single rate-limit response can keep a host quiet.
///
/// A defence against a malformed or far-future reset header: Helix's bucket
/// refills within a minute, and an app that silently stops polling for an
/// hour on one odd response is worse than one extra 429.
const Duration kMaxRateLimitBackoff = Duration(minutes: 2);

/// Used when a 429 arrives with neither `Ratelimit-Reset` nor `Retry-After`.
const Duration kDefaultRateLimitBackoff = Duration(seconds: 30);

/// How long to stay off a host after a response, or null when no back-off is
/// called for.
///
/// [headers] are lower-cased, as package:http delivers them. Backs off on a
/// 429, and also on a success that reports `Ratelimit-Remaining: 0`: the very
/// next request would be the 429, so waiting now avoids spending it.
///
/// Helix's `Ratelimit-Reset` is an absolute epoch on Twitch's clock. It is
/// measured against the response's own `Date` header, not the local clock, so
/// a PC whose clock is a few minutes off neither hammers a drained bucket nor
/// goes quiet for minutes.
Duration? rateLimitBackoff({
  required int statusCode,
  required Map<String, String> headers,
  required DateTime now,
}) {
  final exhausted = headers['ratelimit-remaining']?.trim() == '0';
  if (statusCode != 429 && !exhausted) return null;

  Duration? wait;
  final reset = int.tryParse(headers['ratelimit-reset']?.trim() ?? '');
  if (reset != null) {
    final resetAt =
        DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
    wait = resetAt.difference(_serverNow(headers['date']) ?? now.toUtc());
  } else {
    final retryAfter = int.tryParse(headers['retry-after']?.trim() ?? '');
    if (retryAfter != null) wait = Duration(seconds: retryAfter);
  }
  if (wait == null) {
    // An exhausted bucket with no reset time gives nothing to wait for.
    if (statusCode != 429) return null;
    wait = kDefaultRateLimitBackoff;
  }
  const minimum = Duration(seconds: 1);
  if (wait < minimum) return minimum;
  if (wait > kMaxRateLimitBackoff) return kMaxRateLimitBackoff;
  return wait;
}

DateTime? _serverNow(String? dateHeader) {
  if (dateHeader == null) return null;
  try {
    return HttpDate.parse(dateHeader);
  } catch (_) {
    return null;
  }
}

/// Caps how many requests are in flight at once, across every caller.
///
/// The minute poll used to open one connection per request for every
/// favourite and every followed channel at the same instant: hundreds of TLS
/// handshakes in one burst for a large followed list.
class _RequestGate {
  _RequestGate(this.limit) : assert(limit > 0);

  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active < limit) {
      _active++;
    } else {
      final turn = Completer<void>();
      _waiting.add(turn);
      // The request that finishes hands its slot straight to the next in
      // line, so the count never dips and lets a newcomer jump the queue.
      await turn.future;
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}

/// The client, concurrency cap and back-off ledger that requests share.
///
/// One per process for the app: main.dart, the player service, Settings and
/// onboarding each construct their own [TwitchApiService], and the rate limit
/// and the connection pool belong to the process, not to an instance.
class _Transport {
  _Transport(this.client, int maxConcurrentRequests)
      : gate = _RequestGate(maxConcurrentRequests);

  final http.Client client;
  final _RequestGate gate;

  /// Per host, because Helix, DecAPI and GQL each limit independently.
  final Map<String, DateTime> backoffUntil = <String, DateTime>{};
}

enum _DecapiUptime { live, offline, unreadable }

class TwitchApiService {
  /// [client] replaces the process-wide shared client (and with it the shared
  /// concurrency cap and back-off), which is what tests use to fake Twitch.
  /// [maxConcurrentRequests] only applies alongside an injected [client].
  TwitchApiService({
    http.Client? client,
    TwitchAuth? auth,
    DateTime Function()? clock,
    int maxConcurrentRequests = defaultMaxConcurrentRequests,
  })  : _transport = client == null
            ? _sharedTransport
            : _Transport(client, maxConcurrentRequests),
        _auth = auth ?? twitchAuth,
        _now = clock ?? DateTime.now;

  /// Requests allowed in flight at once. Enough to overlap latency, few enough
  /// that a refresh is a trickle rather than a burst.
  static const int defaultMaxConcurrentRequests = 8;

  static final _Transport _sharedTransport =
      _Transport(http.Client(), defaultMaxConcurrentRequests);

  final _Transport _transport;
  final TwitchAuth _auth;
  final DateTime Function() _now;

  /// When Helix requests may resume, or null when they are not being held
  /// back. A poll that starts before this would only be refused.
  DateTime? get helixRateLimitedUntil => _backingOffUntil(_helixHost);

  DateTime? _backingOffUntil(String host) {
    final until = _transport.backoffUntil[host];
    return until != null && until.isAfter(_now()) ? until : null;
  }

  static const String _helixHost = 'api.twitch.tv';

  /// Validates an OAuth token against id.twitch.tv, accepting the `oauth:`
  /// prefix users paste from various tools. Shared by the Settings token
  /// tester and the onboarding wizard.
  Future<TokenValidationResult> validateOAuthToken(String rawToken) async {
    var token = rawToken.trim();
    if (token.isEmpty) {
      return const TokenValidationResult(
          isValid: false, message: 'Please enter a token first.');
    }
    if (token.startsWith('oauth:')) {
      token = token.substring(6);
    }
    try {
      final response = await _validate(token);
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body) as Map<String, dynamic>;
        final login = decoded['login'] as String?;
        final clientId = decoded['client_id'] as String?;
        final scopes = <String>[
          for (final s in (decoded['scopes'] as List<dynamic>? ?? const []))
            if (s is String) s,
        ];
        return TokenValidationResult(
          isValid: true,
          // Names the credential. The old text was a bare "Success! Connected
          // as: x" shared by both token fields, which is what let a passing
          // browser-token test read as "the whole app is connected".
          message: 'Browser token OK — VOD progress will sync as $login',
          login: login,
          clientId: clientId,
          scopes: scopes,
          statusCode: 200,
        );
      }
      return TokenValidationResult(
          isValid: false,
          message: 'Invalid token (Status ${response.statusCode})',
          statusCode: response.statusCode);
    } catch (e) {
      return TokenValidationResult(
          isValid: false, message: 'Connection error: ${describeTwitchError(e)}');
    }
  }

  /// Validates the ACCOUNT token against the Client ID it will be paired with.
  ///
  /// Separate from [validateOAuthToken] because it answers a different
  /// question: not "is this string a live token" but "will this token work for
  /// the requests this app makes, with the Client ID this app is configured
  /// with". A live token and a valid Client ID can still be a broken pair, and
  /// that pair is what every Helix call actually sends.
  Future<TwitchAuthStatus> validateHelixToken(
      String rawToken, String configuredClientId) async {
    var token = rawToken.trim();
    if (token.isEmpty) return TwitchAuthStatus.absent;
    if (token.startsWith('oauth:')) token = token.substring(6);
    try {
      final response = await _validate(token);
      Map<String, dynamic>? body;
      try {
        final decoded = json.decode(response.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {
        body = null;
      }
      // The verdict about to be published describes this exact pair, so a
      // later Helix 200 sent with a different one is new evidence, not a
      // repeat of something the probe already accounted for.
      final sentClientId = _effectiveClientId(configuredClientId);
      _auth.noteHelixProbeCredential(
          helixCredentialFingerprint(token, sentClientId));
      return statusFromValidation(
        statusCode: response.statusCode,
        body: body,
        // The Client-Id Helix requests actually carry, not the field: a blank
        // field sends Twitch's public client, so judging the token against
        // the blank found no mismatch while every request 401'd - and the
        // probe and Helix took turns flipping the status every refresh.
        configuredClientId: sentClientId,
        now: _now(),
        previous: _auth.helix.value,
      );
    } catch (_) {
      // A timeout or a dead network says nothing about the token, and must
      // never produce a "reconnect your account" prompt.
      return statusFromTransportError(_auth.helix.value, _now());
    }
  }

  /// `/oauth2/validate`, on the shared client but outside the request gate:
  /// it is a single, user-initiated probe (the Settings Test button, the
  /// banner's re-check), and queueing it behind a refresh in progress would
  /// make the button look broken.
  Future<http.Response> _validate(String token) => _transport.client.get(
        Uri.https('id.twitch.tv', '/oauth2/validate'),
        headers: {'Authorization': 'OAuth $token'},
      ).timeout(const Duration(seconds: 5));

  /// Every Twitch/DecAPI request goes through these wrappers.
  ///
  /// None of the calls in this file had a timeout: a request that never
  /// completes stalled the whole refresh, and because the favourites poll had
  /// no re-entrancy guard the stalled passes accumulated.
  static const Duration _requestTimeout = Duration(seconds: 12);

  /// Every Helix response updates the account token's status, from here
  /// rather than from the seven call sites.
  ///
  /// A chokepoint because the alternative is remembering to report at each
  /// call, and the bug being fixed is precisely that the one call which threw
  /// on a 401 was the only one anybody noticed - `fetchChannelStats` silently
  /// converged on marking channels Offline, so a dead token looked like four
  /// offline streamers. A new Helix call added later is covered for free.
  ///
  /// [requiredScopes] names the scopes the endpoint itself needs: a 200 from
  /// it is the only Helix evidence that the token holds them.
  ///
  /// A 429, or a request made while its host is still backing off, throws
  /// [TwitchRateLimitedException] instead of returning, so no caller can
  /// mistake it for an ordinary failure by checking `statusCode != 200`.
  Future<http.Response> _get(
    Uri url, {
    Map<String, String>? headers,
    Set<String> requiredScopes = const <String>{},
  }) =>
      _send(url, () => _transport.client.get(url, headers: headers),
          headers: headers, requiredScopes: requiredScopes);

  Future<http.Response> _post(Uri url, {Map<String, String>? headers, Object? body}) =>
      _send(url,
          () => _transport.client.post(url, headers: headers, body: body),
          headers: headers);

  Future<http.Response> _send(
    Uri url,
    Future<http.Response> Function() request, {
    Map<String, String>? headers,
    Set<String> requiredScopes = const <String>{},
  }) async {
    // Checked before queueing, so a backed-off host costs no slot...
    _throwIfBackingOff(url);
    return _transport.gate.run(() async {
      // ...and again after, because a 429 may have landed while this request
      // was waiting for its turn.
      _throwIfBackingOff(url);
      final isHelix = url.host == _helixHost;
      final http.Response res;
      try {
        res = await request().timeout(_requestTimeout);
      } catch (e) {
        if (isHelix) _auth.recordHelixTransportError();
        rethrow;
      }
      if (isHelix) {
        _auth.recordHelixResponse(
          res.statusCode,
          credential: _credentialOf(headers),
          endpointScopes: requiredScopes,
        );
      }
      final backoff = rateLimitBackoff(
          statusCode: res.statusCode, headers: res.headers, now: _now());
      if (backoff != null) {
        final until = _now().add(backoff);
        final current = _transport.backoffUntil[url.host];
        if (current == null || until.isAfter(current)) {
          _transport.backoffUntil[url.host] = until;
        }
      }
      if (res.statusCode == 429) {
        throw TwitchRateLimitedException(
            _endpointOf(url), _transport.backoffUntil[url.host]!,
            body: res.body);
      }
      return res;
    });
  }

  void _throwIfBackingOff(Uri url) {
    final until = _transport.backoffUntil[url.host];
    if (until == null) return;
    if (until.isAfter(_now())) {
      throw TwitchRateLimitedException(_endpointOf(url), until);
    }
    _transport.backoffUntil.remove(url.host);
  }

  /// Every URL is built from parts, so a value is always encoded and can never
  /// add a parameter of its own.
  ///
  /// The VOD "Load more" cursor was appended raw while the followed-list
  /// cursor two methods away was encoded, and logins went in unencoded in
  /// both the Helix and DecAPI paths. A cursor with a `+` in it reached Twitch
  /// as a space.
  static Uri _helix(String path, [Map<String, dynamic>? query]) =>
      Uri.https(_helixHost, path, query);

  /// DecAPI takes the login as a path segment, so it is validated by the
  /// caller first: encoding alone would not stop a `/` changing the endpoint.
  static Uri _decapi(String what, String login) =>
      Uri.https('decapi.me', '/twitch/$what/$login');

  /// A request whose failure must not take the rest of the refresh with it.
  static Future<http.Response?> _optional(Future<http.Response> request) async {
    try {
      return await request;
    } catch (_) {
      return null;
    }
  }

  /// The trimmed body of a 200, or null for anything else or an empty body.
  static String? _okBody(http.Response? response) {
    if (response == null || response.statusCode != 200) return null;
    final body = response.body.trim();
    return body.isEmpty ? null : body;
  }

  static bool _isWebUrl(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        !text.contains(RegExp(r'\s'));
  }

  /// DecAPI's uptime reads "2 hours, 13 minutes, 7 seconds" when live and
  /// "`<channel>` is offline" when not. Anything else is an error message.
  static final RegExp _decapiUptimePattern =
      RegExp(r'^\d+\s+(?:day|hour|minute|second)s?\b', caseSensitive: false);

  static _DecapiUptime _readDecapiUptime(String body) {
    final text = body.trim();
    if (_decapiUptimePattern.hasMatch(text)) return _DecapiUptime.live;
    if (text.toLowerCase().contains('offline')) return _DecapiUptime.offline;
    return _DecapiUptime.unreadable;
  }

  /// `helix/streams` for Helix, matching the names [TwitchApiException] has
  /// always carried; host and path for anything else.
  static String _endpointOf(Uri url) => url.host == _helixHost
      ? url.path.replaceFirst(RegExp(r'^/'), '')
      : '${url.host}${url.path}';

  String _getRawOauthToken(String token) {
    String cleanToken = token.trim();
    if (cleanToken.startsWith('oauth:')) {
      cleanToken = cleanToken.substring(6);
    }
    return cleanToken;
  }

  /// Twitch's own web client, used whenever no Client ID is configured.
  static const String _publicClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  /// The Client-Id every Helix request is actually sent with.
  static String _effectiveClientId(String configured) {
    final trimmed = configured.trim();
    return trimmed.isNotEmpty ? trimmed : _publicClientId;
  }

  Map<String, String> _helixHeaders(String token, AppSettings settings) => {
        'Client-Id': _effectiveClientId(settings.twitchClientId),
        'Authorization': 'Bearer $token',
      };

  /// Which token + Client ID pair a Helix request was sent with, for the auth
  /// status to tell repeated evidence from new evidence.
  static int? _credentialOf(Map<String, String>? headers) {
    final authorization = headers?['Authorization'];
    final clientId = headers?['Client-Id'];
    if (authorization == null || clientId == null) return null;
    const bearer = 'Bearer ';
    final token = authorization.startsWith(bearer)
        ? authorization.substring(bearer.length)
        : authorization;
    return helixCredentialFingerprint(token, clientId);
  }

  String _calculateUptime(String startedAtStr) {
    try {
      final startedAt = DateTime.parse(startedAtStr);
      final diff = _now().toUtc().difference(startedAt);
      final hours = diff.inHours;
      final minutes = diff.inMinutes.remainder(60);
      final seconds = diff.inSeconds.remainder(60);
      
      if (hours > 0) {
        return '${hours}h ${minutes}m ${seconds}s';
      } else if (minutes > 0) {
        return '${minutes}m ${seconds}s';
      } else {
        return '${seconds}s';
      }
    } catch (_) {
      return 'Live';
    }
  }

  String _formatNumberString(String value) {
    try {
      final numValue = int.tryParse(value);
      if (numValue == null) return value;
      if (numValue >= 1000000) {
        return '${(numValue / 1000000).toStringAsFixed(1)}M';
      } else if (numValue >= 1000) {
        return '${(numValue / 1000).toStringAsFixed(1)}K';
      }
      return numValue.toString();
    } catch (_) {
      return value;
    }
  }

  int parseDurationToSeconds(String duration) {
    try {
      final hourReg = RegExp(r'(\d+)h');
      final minReg = RegExp(r'(\d+)m');
      final secReg = RegExp(r'(\d+)s');

      int hours = 0;
      int minutes = 0;
      int seconds = 0;

      final hMatch = hourReg.firstMatch(duration);
      if (hMatch != null) {
        hours = int.parse(hMatch.group(1)!);
      }

      final mMatch = minReg.firstMatch(duration);
      if (mMatch != null) {
        minutes = int.parse(mMatch.group(1)!);
      }

      final sMatch = secReg.firstMatch(duration);
      if (sMatch != null) {
        seconds = int.parse(sMatch.group(1)!);
      }

      return (hours * 3600) + (minutes * 60) + seconds;
    } catch (_) {
      return 0;
    }
  }

  /// Refreshes one channel completely: identity, live state and follower
  /// count. For a poll over many channels, [refreshLiveStatus] does the
  /// live-state part in a fraction of the requests.
  Future<ChannelRefreshOutcome> fetchChannelStats(TwitchChannel channel, AppSettings settings) async {
    channel.isLoading = true;
    final previousError = channel.errorMessage;
    channel.errorMessage = null;

    final username = channel.username;
    final token = _getRawOauthToken(settings.twitchOauthToken);

    try {
      // Refused before any request: nothing a server could say about it is
      // more useful than "that is not a username". Helix can still look a
      // channel up by a known id; DecAPI only ever takes the name.
      final canLookUpById = token.isNotEmpty && isValidTwitchUserId(channel.id);
      if (!isValidTwitchLogin(username) && !canLookUpById) {
        throw Exception('"$username" is not a valid Twitch username.');
      }
      if (token.isNotEmpty) {
        // Authenticated: Use Helix API
        final headers = _helixHeaders(token, settings);

        // 1. Resolve ID & Profile Avatar if not cached. A stored id that is
        // not numeric is re-resolved rather than trusted: it is a DecAPI error
        // string saved by an older build.
        if (!isValidTwitchUserId(channel.id) || channel.avatarUrl == null || channel.avatarUrl!.isEmpty) {
          // By id when there is one: ids survive a rename, logins do not.
          final userRes = await _get(
            _helix('/helix/users', isValidTwitchUserId(channel.id)
                ? {'id': channel.id!}
                : {'login': username}),
            headers: headers,
          );
          if (userRes.statusCode == 200) {
            final userData = json.decode(userRes.body);
            if (userData['data'] != null && userData['data'].isNotEmpty) {
              final id = userData['data'][0]['id'];
              if (id is! String || !isValidTwitchUserId(id)) {
                throw Exception('Twitch returned no usable id for "$username".');
              }
              channel.id = id;
              channel.avatarUrl = userData['data'][0]['profile_image_url'] as String?;
            } else {
              throw Exception('Twitch user "$username" not found.');
            }
          } else {
            throw Exception('Helix User API error: status ${userRes.statusCode}');
          }
        }

        // 2. Fetch Stream status
        final streamRes = await _get(
          _helix('/helix/streams', {'user_id': channel.id!}),
          headers: headers,
        );
        if (streamRes.statusCode == 200) {
          final streamData = json.decode(streamRes.body);
          if (streamData['data'] != null && streamData['data'].isNotEmpty) {
            _applyLiveStream(channel, streamData['data'][0] as Map<String, dynamic>);
          } else {
            _applyOffline(channel);
          }
        } else {
          throw Exception('Helix Stream API error: status ${streamRes.statusCode}');
        }

        // 3. Fetch Follower count.
        //
        // Guarded separately: this ran inside the same try as the live-status
        // request, so a failure here (a socket reset, a DNS hiccup - common when
        // many channels refresh at once) jumped to the catch below and marked a
        // genuinely live channel offline, discarding the stream data that had
        // just been fetched successfully.
        try {
          final followsRes = await _get(
            _helix('/helix/channels/followers', {'broadcaster_id': channel.id!}),
            headers: headers,
          );
          if (followsRes.statusCode == 200) {
            final followsData = json.decode(followsRes.body);
            final totalFollowers = followsData['total'] as int?;
            if (totalFollowers != null) {
              channel.followerCount = _formatNumberString(totalFollowers.toString());
            }
          }
        } catch (_) {
          // Follower count is cosmetic; keep the live status we already have.
        }
      } else {
        // Unauthenticated: Fallback to DecAPI.
        //
        // DecAPI answers many errors with status 200 and a sentence of plain
        // text, so a 200 is not an answer until the body looks like one. Any
        // uptime body that did not say "offline" used to read as live - the
        // error text shown as the uptime, plus a "now LIVE" toast - and any id
        // body that did not say "user not found" was saved as the channel id.
        // 1. Verify/Fetch User ID
        final idResponse = await _get(_decapi('id', username));
        if (idResponse.statusCode == 200) {
          final resText = idResponse.body.trim();
          if (resText.toLowerCase().contains('user not found')) {
            throw Exception('Twitch user "$username" not found on Twitch.');
          }
          if (!isValidTwitchUserId(resText)) {
            throw Exception('DecAPI sent an unreadable id for "$username".');
          }
          channel.id = resText;
        } else {
          throw Exception('API returned status code ${idResponse.statusCode}');
        }

        // 2. Uptime decides live or offline, so it alone can fail the
        // refresh. The rest is decoration fetched alongside it: when all six
        // shared one Future.wait, a socket reset on the follower count failed
        // the live check too.
        final results = await Future.wait<http.Response?>([
          _optional(_get(_decapi('avatar', username))),
          _get(_decapi('uptime', username)),
          _optional(_get(_decapi('followcount', username))),
          _optional(_get(_decapi('viewercount', username))),
          _optional(_get(_decapi('game', username))),
          _optional(_get(_decapi('title', username))),
        ]);

        final uptime = results[1]!;
        if (uptime.statusCode != 200) {
          throw Exception('DecAPI uptime returned status ${uptime.statusCode}');
        }
        switch (_readDecapiUptime(uptime.body)) {
          case _DecapiUptime.live:
            channel.isLive = true;
            channel.uptime = uptime.body.trim();
          case _DecapiUptime.offline:
            channel.isLive = false;
            channel.uptime = 'Offline';
          case _DecapiUptime.unreadable:
            throw Exception('DecAPI sent an unreadable live status for "$username".');
        }

        final avatar = _okBody(results[0]);
        if (avatar != null && _isWebUrl(avatar)) {
          channel.avatarUrl = avatar;
        }

        final followers = _okBody(results[2]);
        if (followers != null && int.tryParse(followers) != null) {
          channel.followerCount = _formatNumberString(followers);
        }

        if (channel.isLive) {
          final viewers = _okBody(results[3]);
          if (viewers != null && int.tryParse(viewers) != null) {
            channel.viewerCount = _formatNumberString(viewers);
          }
          final game = _okBody(results[4]);
          if (game != null) channel.game = game;
          final title = _okBody(results[5]);
          if (title != null) channel.streamTitle = title;
        } else {
          channel.viewerCount = '0';
          channel.game = 'Offline';
          channel.streamTitle = 'No active broadcast';
        }
      }

      _recordRefreshed(channel);
      return ChannelRefreshOutcome.updated;
    } on TwitchRateLimitedException catch (e) {
      _recordRateLimited(channel, previousError, e);
      return ChannelRefreshOutcome.rateLimited;
    } catch (e) {
      _recordFailure(channel, e.toString().replaceFirst('Exception: ', ''));
      return ChannelRefreshOutcome.failed;
    } finally {
      channel.isLoading = false;
    }
  }

  /// Helix accepts up to this many ids or logins in one helix/streams or
  /// helix/users request.
  static const int _helixBatchSize = 100;

  /// Live state for many channels, in as few requests as Helix allows.
  ///
  /// The minute poll called [fetchChannelStats] once per favourite and once
  /// per followed channel, all at the same moment: helix/streams for a single
  /// id, the follower count, and helix/users whenever the avatar was missing -
  /// which, for every followed channel, was the first poll. A few hundred
  /// follows came to 600-900 requests a minute against a bucket of about 800.
  /// Here helix/streams takes 100 ids per request and helix/users 100 lookups,
  /// so 300 channels cost three requests once their identities are known.
  ///
  /// Follower counts are left out on purpose: they move slowly, are shown for
  /// the selected channel, and cost one request per channel.
  /// [fetchChannelStats] still fetches them for a single channel.
  ///
  /// Without an account token there is nothing to batch (DecAPI is one
  /// request per field per channel), so each channel goes through
  /// [fetchChannelStats], behind the shared concurrency cap.
  ///
  /// Never throws; every channel comes back with an outcome. A rate-limited
  /// channel is left exactly as it was and must not count as a failure.
  Future<ChannelsRefreshResult> refreshLiveStatus(
      List<TwitchChannel> channels, AppSettings settings) async {
    final unique = channels.toSet().toList();
    final outcomes = <TwitchChannel, ChannelRefreshOutcome>{};
    final token = _getRawOauthToken(settings.twitchOauthToken);

    if (token.isEmpty) {
      final results = await Future.wait(
          unique.map((c) => fetchChannelStats(c, settings)));
      for (var i = 0; i < unique.length; i++) {
        outcomes[unique[i]] = results[i];
      }
      return ChannelsRefreshResult(outcomes,
          rateLimitedUntil: _backingOffUntil('decapi.me'));
    }

    final headers = _helixHeaders(token, settings);
    for (final c in unique) {
      c.isLoading = true;
    }
    try {
      await _resolveIdentities(unique, headers, outcomes);
      final checkable = [
        for (final c in unique)
          if (!outcomes.containsKey(c) && isValidTwitchUserId(c.id)) c,
      ];
      await _checkStreams(checkable, headers, outcomes);
    } finally {
      for (final c in unique) {
        c.isLoading = false;
      }
    }
    return ChannelsRefreshResult(outcomes,
        rateLimitedUntil: helixRateLimitedUntil);
  }

  /// Fills in missing ids and avatars, 100 lookups per request.
  ///
  /// Settles a channel's outcome only when it cannot be stream-checked at all
  /// (no usable id). One that already has its id and only lacks an avatar
  /// goes on to the stream check whatever happens here: the avatar can wait
  /// for the next pass, the live state should not.
  Future<void> _resolveIdentities(
    List<TwitchChannel> channels,
    Map<String, String> headers,
    Map<TwitchChannel, ChannelRefreshOutcome> outcomes,
  ) async {
    final needed = <TwitchChannel>[];
    for (final c in channels) {
      final hasId = isValidTwitchUserId(c.id);
      if (hasId && (c.avatarUrl ?? '').isNotEmpty) continue;
      if (!hasId && !isValidTwitchLogin(c.username)) {
        _recordFailure(c, '"${c.username}" is not a valid Twitch username.');
        outcomes[c] = ChannelRefreshOutcome.failed;
        continue;
      }
      needed.add(c);
    }
    await Future.wait([
      for (var i = 0; i < needed.length; i += _helixBatchSize)
        _resolveIdentityChunk(
            needed.sublist(i, _chunkEnd(i, needed.length)), headers, outcomes),
    ]);
  }

  Future<void> _resolveIdentityChunk(
    List<TwitchChannel> chunk,
    Map<String, String> headers,
    Map<TwitchChannel, ChannelRefreshOutcome> outcomes,
  ) async {
    // By id when there is one: ids survive a rename, logins do not.
    final ids = <String>{
      for (final c in chunk)
        if (isValidTwitchUserId(c.id)) c.id!,
    };
    final logins = <String>{
      for (final c in chunk)
        if (!isValidTwitchUserId(c.id)) c.username.toLowerCase(),
    };

    List<dynamic>? users;
    TwitchRateLimitedException? rateLimited;
    Object? failure;
    try {
      final res = await _get(
        _helix('/helix/users', {
          if (ids.isNotEmpty) 'id': ids.toList(),
          if (logins.isNotEmpty) 'login': logins.toList(),
        }),
        headers: headers,
      );
      if (res.statusCode != 200) {
        throw Exception('Helix User API error: status ${res.statusCode}');
      }
      users = (json.decode(res.body) as Map<String, dynamic>)['data']
              as List<dynamic>? ??
          const <dynamic>[];
    } on TwitchRateLimitedException catch (e) {
      rateLimited = e;
    } catch (e) {
      failure = e;
    }

    final byId = <String, Map<String, dynamic>>{};
    final byLogin = <String, Map<String, dynamic>>{};
    for (final user in users ?? const <dynamic>[]) {
      if (user is! Map<String, dynamic>) continue;
      final id = user['id'];
      if (id is! String || !isValidTwitchUserId(id)) continue;
      byId[id] = user;
      final login = user['login'];
      if (login is String) byLogin[login.toLowerCase()] = user;
    }

    for (final c in chunk) {
      final hadId = isValidTwitchUserId(c.id);
      if (users == null) {
        if (hadId) continue;
        if (rateLimited != null) {
          _recordRateLimited(c, c.errorMessage, rateLimited);
          outcomes[c] = ChannelRefreshOutcome.rateLimited;
        } else {
          _recordFailure(c, '$failure'.replaceFirst('Exception: ', ''));
          outcomes[c] = ChannelRefreshOutcome.failed;
        }
        continue;
      }
      final user = hadId ? byId[c.id] : byLogin[c.username.toLowerCase()];
      if (user == null) {
        if (hadId) continue;
        _recordFailure(c, 'Twitch user "${c.username}" not found.');
        outcomes[c] = ChannelRefreshOutcome.failed;
        continue;
      }
      c.id = user['id'] as String;
      final avatar = user['profile_image_url'];
      if (avatar is String && avatar.isNotEmpty) c.avatarUrl = avatar;
    }
  }

  /// Live or offline for every channel, 100 ids per helix/streams request.
  ///
  /// Grouped by id, so the favourite and the followed-list object for the
  /// same streamer cost one slot and are updated together.
  Future<void> _checkStreams(
    List<TwitchChannel> channels,
    Map<String, String> headers,
    Map<TwitchChannel, ChannelRefreshOutcome> outcomes,
  ) async {
    final byId = <String, List<TwitchChannel>>{};
    for (final c in channels) {
      (byId[c.id!] ??= <TwitchChannel>[]).add(c);
    }
    final ids = byId.keys.toList();
    await Future.wait([
      for (var i = 0; i < ids.length; i += _helixBatchSize)
        _checkStreamChunk(ids.sublist(i, _chunkEnd(i, ids.length)), byId,
            headers, outcomes),
    ]);
  }

  Future<void> _checkStreamChunk(
    List<String> ids,
    Map<String, List<TwitchChannel>> byId,
    Map<String, String> headers,
    Map<TwitchChannel, ChannelRefreshOutcome> outcomes,
  ) async {
    void settle(ChannelRefreshOutcome outcome, void Function(TwitchChannel) apply) {
      for (final id in ids) {
        for (final c in byId[id]!) {
          apply(c);
          outcomes[c] = outcome;
        }
      }
    }

    final live = <String, Map<String, dynamic>>{};
    try {
      // first=100 because the page size defaults to 20: with 100 ids in one
      // request, the 21st live channel would otherwise read as offline.
      final res = await _get(
        _helix('/helix/streams', {'user_id': ids, 'first': '$_helixBatchSize'}),
        headers: headers,
      );
      if (res.statusCode != 200) {
        throw Exception('Helix Stream API error: status ${res.statusCode}');
      }
      final data = (json.decode(res.body) as Map<String, dynamic>)['data']
              as List<dynamic>? ??
          const <dynamic>[];
      for (final stream in data) {
        if (stream is! Map<String, dynamic>) continue;
        final userId = stream['user_id'];
        if (userId is String) live[userId] = stream;
      }
    } on TwitchRateLimitedException catch (e) {
      settle(ChannelRefreshOutcome.rateLimited,
          (c) => _recordRateLimited(c, c.errorMessage, e));
      return;
    } catch (e) {
      final message = '$e'.replaceFirst('Exception: ', '');
      settle(ChannelRefreshOutcome.failed, (c) => _recordFailure(c, message));
      return;
    }

    for (final id in ids) {
      final stream = live[id];
      for (final c in byId[id]!) {
        if (stream != null) {
          _applyLiveStream(c, stream);
        } else {
          _applyOffline(c);
        }
        _recordRefreshed(c);
        outcomes[c] = ChannelRefreshOutcome.updated;
      }
    }
  }

  static int _chunkEnd(int start, int length) =>
      start + _helixBatchSize > length ? length : start + _helixBatchSize;

  /// A helix/streams entry, applied to [channel]. Shared by the single and the
  /// batched refresh so the two cannot drift apart.
  ///
  /// Reads fields without hard casts: this runs outside the batched
  /// refresh's try, and a TypeError from one odd entry would escape
  /// [refreshLiveStatus], which promises never to throw.
  void _applyLiveStream(TwitchChannel channel, Map<String, dynamic> stream) {
    String? text(Object? value) => value is String ? value : null;
    channel.isLive = true;
    // Stable for the whole broadcast; used to identify a live session.
    channel.streamId = stream['id']?.toString();
    channel.streamTitle = text(stream['title']);
    channel.game = text(stream['game_name']);
    channel.viewerCount = stream['viewer_count']?.toString() ?? '0';

    final startedAt = text(stream['started_at']);
    if (startedAt != null) {
      channel.uptime = _calculateUptime(startedAt);
      // Derived from the broadcast itself, so it is correct even for a
      // channel that was already live when the app started - unlike
      // observing an offline->live edge, which never happens then.
      channel.wentLiveTime = DateTime.tryParse(startedAt)?.toLocal();
    } else {
      channel.uptime = 'Live';
    }
  }

  void _applyOffline(TwitchChannel channel) {
    channel.isLive = false;
    channel.streamId = null;
    channel.uptime = 'Offline';
    channel.viewerCount = '0';
    channel.game = 'Offline';
    channel.streamTitle = 'No active broadcast';
  }

  /// How many consecutive refresh failures before a live channel is treated as
  /// offline rather than temporarily unreachable.
  static const int _failuresBeforeOffline = 3;

  /// Nothing was learned about [channel], so nothing about it changes: not
  /// its live state, not its failure count, not the error it showed.
  ///
  /// Except for a channel that has never loaded, which has nothing to keep.
  /// Leaving its error empty would make "Add channel" treat a refused lookup
  /// as success and add a name nobody checked, and show a blank row with no
  /// reason on it.
  void _recordRateLimited(TwitchChannel channel, String? previousError,
      TwitchRateLimitedException error) {
    channel.errorMessage = previousError ??
        (channel.lastUpdated == null ? describeTwitchError(error) : null);
  }

  void _recordRefreshed(TwitchChannel channel) {
    channel.errorMessage = null;
    channel.lastUpdated = _now();
    channel.consecutiveFailures = 0;
  }

  void _recordFailure(TwitchChannel channel, String message) {
    channel.errorMessage = message;
    channel.consecutiveFailures++;

    // Do NOT flip a live channel to offline on the first failure.
    //
    // This catch used to set isLive = false unconditionally, and the caller
    // reads that as a genuine go-offline: it cleared the channel's
    // notification and auto-play session tracking, so the next successful
    // poll looked like a brand-new broadcast and produced a duplicate
    // "<channel> is now LIVE!" toast plus an auto-play relaunch. A single
    // flaky request or a brief Wi-Fi drop was enough.
    if (channel.consecutiveFailures >= _failuresBeforeOffline) {
      channel.isLive = false;
      channel.streamId = null;
      channel.uptime = 'Offline';
    }
  }

  Future<FollowedChannelsResult> fetchFollowedChannels(AppSettings settings) async {
    final token = _getRawOauthToken(settings.twitchOauthToken);
    if (token.isEmpty) {
      throw Exception('OAuth token is empty');
    }

    final headers = _helixHeaders(token, settings);

    final userRes = await _get(_helix('/helix/users'), headers: headers);

    if (userRes.statusCode != 200) {
      throw TwitchApiException(userRes.statusCode, 'helix/users', userRes.body);
    }

    final userData = json.decode(userRes.body);
    if (userData['data'] == null || userData['data'].isEmpty) {
      throw Exception('User data empty');
    }

    final userId = userData['data'][0]['id'] as String;
    final userLogin = userData['data'][0]['login'] as String;
    final userAvatar = userData['data'][0]['profile_image_url'] as String?;

    // Helix returns at most 100 per page. Only the first page used to be
    // requested, so anyone following more than 100 channels silently lost the
    // rest from the Followed tab.
    final List<TwitchChannel> tempFollowed = [];
    final seen = <String>{};
    String? cursor;
    // Bounded so a malformed cursor cannot spin forever.
    const maxPages = 20;
    var isComplete = true;
    Object? pageError;

    for (var page = 0; page < maxPages; page++) {
      final url = _helix('/helix/channels/followed', {
        'user_id': userId,
        'first': '100',
        if (cursor != null && cursor.isNotEmpty) 'after': cursor,
      });

      final Map<String, dynamic> followsData;
      try {
        final followsRes = await _get(url,
            headers: headers, requiredScopes: kRequiredHelixScopes);
        if (followsRes.statusCode != 200) {
          throw TwitchApiException(
              followsRes.statusCode, 'helix/channels/followed', followsRes.body);
        }
        followsData = json.decode(followsRes.body) as Map<String, dynamic>;
      } catch (e) {
        final refused = e is TwitchApiException && e.isAuthFailure;
        if (tempFollowed.isEmpty || refused) rethrow;
        // Keep whatever was already collected rather than losing every page
        // to a failure on the last one - but say it is not the whole list.
        isComplete = false;
        pageError = e;
        break;
      }

      final List<dynamic> data = followsData['data'] ?? [];

      for (final item in data) {
        final name = item['broadcaster_login'] as String?;
        if (name == null || name.trim().isEmpty) continue;
        final clean = name.toLowerCase().trim();
        if (!seen.add(clean)) continue;
        final channel = TwitchChannel(username: clean);
        final id = item['broadcaster_id'];
        channel.id = id is String && isValidTwitchUserId(id) ? id : null;
        channel.game = item['game_name'] as String?;
        tempFollowed.add(channel);
      }

      cursor = followsData['pagination']?['cursor'] as String?;
      if (data.isEmpty || cursor == null || cursor.isEmpty) break;
      // Still holding a cursor after the last allowed page: Twitch had more.
      if (page == maxPages - 1) isComplete = false;
    }

    return FollowedChannelsResult(
      channels: tempFollowed,
      userLogin: userLogin,
      userAvatar: userAvatar,
      isComplete: isComplete,
      pageError: pageError,
    );
  }

  /// Games per VOD id. A past broadcast's chapter list never changes, so this
  /// is cached for the process lifetime: the enrichment below previously re-ran
  /// for every VOD on every fetch, and the automation pass fetches every
  /// auto-download channel's VOD list once a minute.
  static final Map<String, List<String>> _vodGamesCache = {};

  Future<VodsFetchResult> fetchVodsForChannel({
    required TwitchChannel channel,
    required AppSettings settings,
    required Map<String, int> localVodsProgress,
    String? afterCursor,
    /// Games are display-only. The automation pass does not render anything,
    /// so it skips them and halves the request count.
    bool fetchGames = true,
    /// The browser token's watch positions: one GQL request per VOD, so a
    /// page costs twenty. The background prefetch skips them - its list is
    /// fetched again, positions and all, the moment the channel is opened.
    bool fetchWatchProgress = true,
  }) async {
    final token = _getRawOauthToken(settings.twitchOauthToken);
    if (token.isEmpty) {
      throw Exception('OAuth token is empty');
    }

    final headers = _helixHeaders(token, settings);

    // A login that cannot exist is not looked up anywhere: it would only
    // produce a malformed query, or a DecAPI path pointing somewhere else.
    final canLookUp = isValidTwitchLogin(channel.username);

    // Resolve channel ID via Helix if missing (instead of falling back directly
    // to DecAPI). A non-numeric stored id is an old DecAPI error string, and is
    // resolved again rather than sent.
    if (!isValidTwitchUserId(channel.id) && canLookUp) {
      final userRes = await _get(
        _helix('/helix/users', {'login': channel.username}),
        headers: headers,
      );
      if (userRes.statusCode == 200) {
        final userData = json.decode(userRes.body);
        if (userData['data'] != null && userData['data'].isNotEmpty) {
          final id = userData['data'][0]['id'];
          if (id is String && isValidTwitchUserId(id)) {
            channel.id = id;
            channel.avatarUrl = userData['data'][0]['profile_image_url'] as String?;
          }
        }
      }
    }

    // Secondary fallback to DecAPI if Helix resolution failed
    if (!isValidTwitchUserId(channel.id) && canLookUp) {
      final idResponse = await _get(_decapi('id', channel.username));
      if (idResponse.statusCode == 200) {
        final resText = idResponse.body.trim();
        if (isValidTwitchUserId(resText)) {
          channel.id = resText;
        }
      }
    }

    if (!isValidTwitchUserId(channel.id)) {
      throw Exception('Could not resolve Twitch User ID for ${channel.username}');
    }

    final url = _helix('/helix/videos', {
      'user_id': channel.id!,
      'type': 'archive',
      'first': '20',
      if (afterCursor != null && afterCursor.isNotEmpty) 'after': afterCursor,
    });

    final response = await _get(url, headers: headers);

    if (response.statusCode != 200) {
      throw TwitchApiException(
          response.statusCode, 'helix/videos', response.body);
    }

    final data = json.decode(response.body);
    final List<dynamic> videosList = data['data'] ?? [];
    final nextCursor = data['pagination']?['cursor'];

    final newVods = videosList.map((item) => TwitchVideo.fromJson(item)).toList();
    bool isWebTokenExpired = false;

    // Enrich in small batches rather than firing one request per VOD at once.
    // A 20-VOD page previously issued up to 40 simultaneous GQL requests, with
    // no concurrency limit and no 429 handling.
    Future<void> enrich(TwitchVideo vod) async {
      // 1. Games: served from cache when known, and skipped entirely when the
      //    caller does not display them.
      final cachedGames = _vodGamesCache[vod.id];
      if (cachedGames != null) {
        vod.games = cachedGames;
      } else if (fetchGames) {
        try {
        final body = json.encode({
          'operationName': 'VideoPlayer_ChapterSelectButtonVideo',
          'variables': {
            'videoID': vod.id,
          },
          'extensions': {
            'persistedQuery': {
              'version': 1,
              'sha256Hash': '71835d5ef425e154bf282453a926d99b328cdc5e32f36d3a209d0f4778b41203',
            },
          },
        });

        final gResponse = await _post(
          Uri.parse('https://gql.twitch.tv/gql'),
          headers: {
            'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
            'Content-Type': 'application/json',
          },
          body: body,
        );

        if (gResponse.statusCode == 200) {
          final decoded = json.decode(gResponse.body);
          final moments = decoded['data']?['video']?['moments']?['edges'] as List<dynamic>?;
          if (moments != null) {
            final List<String> fetchedGames = [];
            for (final edge in moments) {
              final gameName = edge['node']?['details']?['game']?['displayName'] as String?;
              if (gameName != null && gameName.isNotEmpty) {
                fetchedGames.add(gameName);
              }
            }
            vod.games = fetchedGames.toSet().toList();
            _vodGamesCache[vod.id] = vod.games;
          }
        }
        } catch (_) {}
      }

      // 2. Fetch watch progress via GQL viewingHistory query if web token is present
      String webToken = settings.twitchWebOauthToken.trim();
      if (webToken.startsWith('oauth:')) {
        webToken = webToken.substring(6);
      }
      if (fetchWatchProgress && webToken.isNotEmpty) {
        try {
          final progressBody = json.encode({
            'query': '''
              query(\$videoID: ID!) {
                video(id: \$videoID) {
                  self {
                    viewingHistory {
                      position
                    }
                  }
                }
              }
            ''',
            'variables': {
              'videoID': vod.id,
            },
          });

          final progressResponse = await _post(
            Uri.parse('https://gql.twitch.tv/gql'),
            headers: {
              'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
              'Authorization': 'OAuth $webToken',
              'Content-Type': 'application/json',
            },
            body: progressBody,
          );

          if (progressResponse.statusCode == 200) {
            final decoded = json.decode(progressResponse.body);
            final position = decoded['data']?['video']?['self']?['viewingHistory']?['position'] as int?;
            if (position != null) {
              vod.watchPosition = position;
              final totalSeconds = parseDurationToSeconds(vod.duration);
              if (totalSeconds > 0) {
                vod.watchProgress = position / totalSeconds;
              }
            }
          } else if (progressResponse.statusCode == 401) {
            isWebTokenExpired = true;
            // Same notifier as the account token, different instance - so the
            // UI has to name which credential expired and cannot imply the
            // other one did too.
            _auth.recordBrowserExpired();
          }
        } catch (_) {}
      }

      final localPos = localVodsProgress[vod.id];
      final totalSeconds = parseDurationToSeconds(vod.duration);
      // Defense in depth behind the confirmation gate: a stored position
      // past the end of the video is corruption from before the gate
      // existed, and max-merging it back onto the model would resurrect it
      // forever. (+6s: the gate's own tolerance, for a final segment's
      // rounding.)
      final localPlausible = localPos != null &&
          (totalSeconds <= 0 || localPos <= totalSeconds + 6);
      if (localPlausible &&
          (vod.watchPosition == null || localPos > vod.watchPosition!)) {
        vod.watchPosition = localPos;
        if (totalSeconds > 0) {
          vod.watchProgress = localPos / totalSeconds;
        } else {
          vod.watchProgress = 0.0;
        }
      }

      if (vod.watchPosition != null && vod.watchPosition! > 0) {
        localVodsProgress[vod.id] = vod.watchPosition!;
      }
    }

    const batchSize = 5;
    for (var i = 0; i < newVods.length; i += batchSize) {
      final end = (i + batchSize) > newVods.length ? newVods.length : i + batchSize;
      await Future.wait(newVods.sublist(i, end).map(enrich));
    }

    return VodsFetchResult(
      vods: newVods,
      nextCursor: nextCursor,
      isWebTokenExpired: isWebTokenExpired,
    );
  }

  Future<void> syncSingleVODProgressDirect(String videoID, int position, String webToken) async {
    String token = webToken.trim();
    if (token.startsWith('oauth:')) {
      token = token.substring(6);
    }
    
    final body = json.encode({
      'query': '''
        mutation(\$videoID: ID!, \$position: Int!) {
          updateVideoPlaybackPosition(input: {videoID: \$videoID, position: \$position}) {
            error {
              code
            }
          }
        }
      ''',
      'variables': {
        'videoID': videoID,
        'position': position,
      },
    });

    final response = await _post(
      Uri.parse('https://gql.twitch.tv/gql'),
      headers: {
        'Client-Id': 'kimne78kx3ncx6brgo4mv6wki5h1ko',
        'Authorization': 'OAuth $token',
        'Content-Type': 'application/json',
      },
      body: body,
    );

    if (response.statusCode == 401) {
      _auth.recordBrowserExpired();
      throw Exception('Unauthorized GQL web token');
    }
  }
}
