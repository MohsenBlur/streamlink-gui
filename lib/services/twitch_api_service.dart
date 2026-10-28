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
  FollowedChannelsResult({required this.channels, required this.userLogin, this.userAvatar});
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
  DateTime? get helixRateLimitedUntil {
    final until = _transport.backoffUntil[_helixHost];
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
      _auth.noteHelixProbeCredential(helixCredentialFingerprint(
          token, _effectiveClientId(configuredClientId)));
      return statusFromValidation(
        statusCode: response.statusCode,
        body: body,
        configuredClientId: configuredClientId,
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
  /// count.
  Future<ChannelRefreshOutcome> fetchChannelStats(TwitchChannel channel, AppSettings settings) async {
    channel.isLoading = true;
    final previousError = channel.errorMessage;
    channel.errorMessage = null;

    final username = channel.username;
    final token = _getRawOauthToken(settings.twitchOauthToken);

    try {
      if (token.isNotEmpty) {
        // Authenticated: Use Helix API
        final headers = _helixHeaders(token, settings);

        // 1. Resolve ID & Profile Avatar if not cached
        if (channel.id == null || channel.id!.isEmpty || channel.avatarUrl == null || channel.avatarUrl!.isEmpty) {
          final userRes = await _get(
            Uri.parse('https://api.twitch.tv/helix/users?login=$username'),
            headers: headers,
          );
          if (userRes.statusCode == 200) {
            final userData = json.decode(userRes.body);
            if (userData['data'] != null && userData['data'].isNotEmpty) {
              channel.id = userData['data'][0]['id'] as String;
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
          Uri.parse('https://api.twitch.tv/helix/streams?user_id=${channel.id}'),
          headers: headers,
        );
        if (streamRes.statusCode == 200) {
          final streamData = json.decode(streamRes.body);
          if (streamData['data'] != null && streamData['data'].isNotEmpty) {
            final stream = streamData['data'][0];
            channel.isLive = true;
            // Stable for the whole broadcast; used to identify a live session.
            channel.streamId = stream['id']?.toString();
            channel.streamTitle = stream['title'] as String?;
            channel.game = stream['game_name'] as String?;
            channel.viewerCount = stream['viewer_count']?.toString() ?? '0';

            final startedAt = stream['started_at'] as String?;
            if (startedAt != null) {
              channel.uptime = _calculateUptime(startedAt);
              // Derived from the broadcast itself, so it is correct even for a
              // channel that was already live when the app started - unlike
              // observing an offline->live edge, which never happens then.
              channel.wentLiveTime = DateTime.tryParse(startedAt)?.toLocal();
            } else {
              channel.uptime = 'Live';
            }
          } else {
            channel.isLive = false;
            channel.streamId = null;
            channel.uptime = 'Offline';
            channel.viewerCount = '0';
            channel.game = 'Offline';
            channel.streamTitle = 'No active broadcast';
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
            Uri.parse('https://api.twitch.tv/helix/channels/followers?broadcaster_id=${channel.id}'),
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
        // Unauthenticated: Fallback to DecAPI
        // 1. Verify/Fetch User ID
        final idResponse = await _get(Uri.parse('https://decapi.me/twitch/id/$username'));
        if (idResponse.statusCode == 200) {
          final resText = idResponse.body.trim();
          if (resText.toLowerCase().contains('user not found')) {
            throw Exception('Twitch user "$username" not found on Twitch.');
          }
          channel.id = resText;
        } else {
          throw Exception('API returned status code ${idResponse.statusCode}');
        }

        // 2. Fetch Uptime, Avatar, Followers, Viewers, Game, and Title in parallel
        final futures = await Future.wait([
          _get(Uri.parse('https://decapi.me/twitch/avatar/$username')),
          _get(Uri.parse('https://decapi.me/twitch/uptime/$username')),
          _get(Uri.parse('https://decapi.me/twitch/followcount/$username')),
          _get(Uri.parse('https://decapi.me/twitch/viewercount/$username')),
          _get(Uri.parse('https://decapi.me/twitch/game/$username')),
          _get(Uri.parse('https://decapi.me/twitch/title/$username')),
        ]);

        if (futures[0].statusCode == 200) {
          channel.avatarUrl = futures[0].body.trim();
        }
        
        if (futures[1].statusCode == 200) {
          final uptimeStr = futures[1].body.trim();
          if (uptimeStr.toLowerCase().contains('offline')) {
            channel.isLive = false;
            channel.uptime = 'Offline';
          } else {
            channel.isLive = true;
            channel.uptime = uptimeStr;
          }
        }

        if (futures[2].statusCode == 200) {
          channel.followerCount = _formatNumberString(futures[2].body.trim());
        }

        if (channel.isLive) {
          if (futures[3].statusCode == 200) {
            channel.viewerCount = _formatNumberString(futures[3].body.trim());
          }
          if (futures[4].statusCode == 200) {
            channel.game = futures[4].body.trim();
          }
          if (futures[5].statusCode == 200) {
            channel.streamTitle = futures[5].body.trim();
          }
        } else {
          channel.viewerCount = '0';
          channel.game = 'Offline';
          channel.streamTitle = 'No active broadcast';
        }
      }

      _recordRefreshed(channel);
      return ChannelRefreshOutcome.updated;
    } on TwitchRateLimitedException {
      // Nothing was learned about this channel, so nothing about it changes:
      // not its live state, not its failure count, not the error it showed.
      channel.errorMessage = previousError;
      return ChannelRefreshOutcome.rateLimited;
    } catch (e) {
      _recordFailure(channel, e.toString().replaceFirst('Exception: ', ''));
      return ChannelRefreshOutcome.failed;
    } finally {
      channel.isLoading = false;
    }
  }

  /// How many consecutive refresh failures before a live channel is treated as
  /// offline rather than temporarily unreachable.
  static const int _failuresBeforeOffline = 3;

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

    final userRes = await _get(
      Uri.parse('https://api.twitch.tv/helix/users'),
      headers: headers,
    );

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

    for (var page = 0; page < maxPages; page++) {
      final url = StringBuffer('https://api.twitch.tv/helix/channels/followed'
          '?user_id=$userId&first=100');
      if (cursor != null && cursor.isNotEmpty) {
        url.write('&after=${Uri.encodeQueryComponent(cursor)}');
      }

      final followsRes = await _get(Uri.parse(url.toString()),
          headers: headers, requiredScopes: kRequiredHelixScopes);
      if (followsRes.statusCode != 200) {
        // Keep whatever was already collected rather than losing every page to
        // a failure on the last one.
        if (tempFollowed.isNotEmpty) break;
        throw TwitchApiException(
            followsRes.statusCode, 'helix/channels/followed', followsRes.body);
      }

      final followsData = json.decode(followsRes.body);
      final List<dynamic> data = followsData['data'] ?? [];

      for (final item in data) {
        final name = item['broadcaster_login'] as String?;
        if (name == null || name.trim().isEmpty) continue;
        final clean = name.toLowerCase().trim();
        if (!seen.add(clean)) continue;
        final channel = TwitchChannel(username: clean);
        channel.id = item['broadcaster_id'] as String?;
        channel.game = item['game_name'] as String?;
        tempFollowed.add(channel);
      }

      cursor = followsData['pagination']?['cursor'] as String?;
      if (data.isEmpty || cursor == null || cursor.isEmpty) break;
    }

    return FollowedChannelsResult(
      channels: tempFollowed,
      userLogin: userLogin,
      userAvatar: userAvatar,
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
  }) async {
    final token = _getRawOauthToken(settings.twitchOauthToken);
    if (token.isEmpty) {
      throw Exception('OAuth token is empty');
    }

    final headers = _helixHeaders(token, settings);

    // Resolve channel ID via Helix if missing (instead of falling back directly to DecAPI)
    if (channel.id == null || channel.id!.isEmpty) {
      final userRes = await _get(
        Uri.parse('https://api.twitch.tv/helix/users?login=${channel.username}'),
        headers: headers,
      );
      if (userRes.statusCode == 200) {
        final userData = json.decode(userRes.body);
        if (userData['data'] != null && userData['data'].isNotEmpty) {
          channel.id = userData['data'][0]['id'] as String;
          channel.avatarUrl = userData['data'][0]['profile_image_url'] as String?;
        }
      }
    }

    // Secondary fallback to DecAPI if Helix resolution failed
    if (channel.id == null || channel.id!.isEmpty) {
      final idResponse = await _get(Uri.parse('https://decapi.me/twitch/id/${channel.username}'));
      if (idResponse.statusCode == 200) {
        final resText = idResponse.body.trim();
        if (!resText.toLowerCase().contains('user not found')) {
          channel.id = resText;
        }
      }
    }

    if (channel.id == null || channel.id!.isEmpty) {
      throw Exception('Could not resolve Twitch User ID for ${channel.username}');
    }

    String url = 'https://api.twitch.tv/helix/videos?user_id=${channel.id}&type=archive&first=20';
    if (afterCursor != null && afterCursor.isNotEmpty) {
      url += '&after=$afterCursor';
    }

    final response = await _get(Uri.parse(url), headers: headers);

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
      if (webToken.isNotEmpty) {
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
