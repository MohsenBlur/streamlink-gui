import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';

/// TwitchApiService against a scripted Twitch.
///
/// The service had no behavioural tests at all: it appeared in the suite only
/// as a string read by a source scan, so a parsing regression or a change in
/// how a failure is counted could ship with every test green. These pump the
/// real service through a fake `http.Client` and assert on what it sends and
/// what it does to the channels it was handed.
class FakeTwitch {
  FakeTwitch(this.respond);

  FutureOr<http.Response> Function(http.Request request) respond;
  final List<http.Request> requests = <http.Request>[];
  Duration latency = Duration.zero;
  int _inFlight = 0;
  int peakInFlight = 0;

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    try {
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      return await respond(request);
    } finally {
      _inFlight--;
    }
  });

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();
}

/// Headers are lower-case, as package:http delivers them from a real socket.
http.Response jsonResponse(Object body,
        {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(json.encode(body), status,
        headers: {'content-type': 'application/json', ...headers});

Map<String, dynamic> liveStream(String userId, {String title = 'hello'}) => {
      'id': 'stream-$userId',
      'user_id': userId,
      'title': title,
      'game_name': 'Chess',
      'viewer_count': 42,
      'started_at': '2026-10-28T10:00:00Z',
    };

void main() {
  final settings = AppSettings(twitchOauthToken: 'oauth:account-token');
  late TwitchAuth auth;
  late DateTime clock;

  setUp(() {
    auth = TwitchAuth();
    clock = DateTime.utc(2026, 10, 28, 12);
  });

  TwitchApiService serviceFor(FakeTwitch twitch, {int maxConcurrent = 8}) =>
      TwitchApiService(
        client: twitch.client,
        auth: auth,
        clock: () => clock,
        maxConcurrentRequests: maxConcurrent,
      );

  TwitchChannel known(String name, String id) =>
      TwitchChannel(username: name, id: id, avatarUrl: 'https://img/$name.png');

  group('rateLimitBackoff', () {
    final serverNow = DateTime.utc(2026, 10, 28, 12);
    Map<String, String> resetIn(Duration d) => {
          'date': HttpDate.format(serverNow),
          'ratelimit-reset':
              '${serverNow.add(d).millisecondsSinceEpoch ~/ 1000}',
        };

    test('an ordinary success asks for nothing', () {
      expect(
          rateLimitBackoff(
              statusCode: 200,
              headers: {'ratelimit-remaining': '799'},
              now: serverNow),
          isNull);
    });

    test('a 429 waits until Ratelimit-Reset, on Twitch\'s clock', () {
      // The local clock is an hour fast. Measured against it, the reset
      // would already be in the past and the app would hammer a drained
      // bucket; measured against the response's Date header it is 20s away.
      final wait = rateLimitBackoff(
          statusCode: 429,
          headers: resetIn(const Duration(seconds: 20)),
          now: serverNow.add(const Duration(hours: 1)));
      expect(wait, const Duration(seconds: 20));
    });

    test('an exhausted bucket backs off before the 429 happens', () {
      final wait = rateLimitBackoff(
          statusCode: 200,
          headers: {
            ...resetIn(const Duration(seconds: 7)),
            'ratelimit-remaining': '0',
          },
          now: serverNow);
      expect(wait, const Duration(seconds: 7));
    });

    test('an exhausted bucket with no reset time asks for nothing', () {
      expect(
          rateLimitBackoff(
              statusCode: 200,
              headers: {'ratelimit-remaining': '0'},
              now: serverNow),
          isNull);
    });

    test('Retry-After is honoured when there is no reset header', () {
      expect(
          rateLimitBackoff(
              statusCode: 429, headers: {'retry-after': '12'}, now: serverNow),
          const Duration(seconds: 12));
    });

    test('a bare 429 still backs off', () {
      expect(rateLimitBackoff(statusCode: 429, headers: {}, now: serverNow),
          kDefaultRateLimitBackoff);
    });

    test('the wait is bounded both ways', () {
      expect(
          rateLimitBackoff(
              statusCode: 429,
              headers: resetIn(const Duration(seconds: -30)),
              now: serverNow),
          const Duration(seconds: 1),
          reason: 'a reset already passed still gets a breath, not a retry storm');
      expect(
          rateLimitBackoff(
              statusCode: 429,
              headers: resetIn(const Duration(days: 3)),
              now: serverNow),
          kMaxRateLimitBackoff,
          reason: 'one odd header must not silence the app for days');
    });
  });

  group('a 429 is not a channel failure', () {
    test('a rate-limited refresh leaves the channel exactly as it was', () async {
      final twitch = FakeTwitch((_) => jsonResponse(
            {'message': 'Too Many Requests'},
            status: 429,
            headers: {'retry-after': '20'},
          ));
      final api = serviceFor(twitch);
      final channel = known('streamer', '111')
        ..isLive = true
        ..streamId = 'stream-111'
        ..consecutiveFailures = 2
        ..errorMessage = 'earlier problem';

      final outcome = await api.fetchChannelStats(channel, settings);

      expect(outcome, ChannelRefreshOutcome.rateLimited);
      expect(channel.isLive, isTrue,
          reason: 'two failures plus a 429 used to reach the offline threshold');
      expect(channel.streamId, 'stream-111');
      expect(channel.consecutiveFailures, 2);
      expect(channel.errorMessage, 'earlier problem');
      expect(channel.isLoading, isFalse);
    });

    test('an ordinary error still counts, and three go offline', () async {
      final twitch = FakeTwitch((_) => jsonResponse({}, status: 500));
      final api = serviceFor(twitch);
      final channel = known('streamer', '111')..isLive = true;

      expect(await api.fetchChannelStats(channel, settings),
          ChannelRefreshOutcome.failed);
      expect(channel.consecutiveFailures, 1);
      expect(channel.isLive, isTrue);
      expect(channel.errorMessage, 'Helix Stream API error: status 500');

      await api.fetchChannelStats(channel, settings);
      await api.fetchChannelStats(channel, settings);
      expect(channel.isLive, isFalse);
    });

    test('the back-off is honoured: nothing is sent until it expires', () async {
      var limited = true;
      final twitch = FakeTwitch((request) {
        if (limited) {
          return jsonResponse({}, status: 429, headers: {'retry-after': '20'});
        }
        return request.url.path == '/helix/streams'
            ? jsonResponse({'data': [liveStream('111')]})
            : jsonResponse({'total': 5});
      });
      final api = serviceFor(twitch);
      final channel = known('streamer', '111');

      await api.fetchChannelStats(channel, settings);
      expect(twitch.requests, hasLength(1));
      expect(api.helixRateLimitedUntil,
          clock.add(const Duration(seconds: 20)));

      limited = false;
      clock = clock.add(const Duration(seconds: 10));
      expect(await api.fetchChannelStats(channel, settings),
          ChannelRefreshOutcome.rateLimited);
      expect(twitch.requests, hasLength(1),
          reason: 'a request inside the back-off is refused locally');

      clock = clock.add(const Duration(seconds: 11));
      expect(api.helixRateLimitedUntil, isNull);
      expect(await api.fetchChannelStats(channel, settings),
          ChannelRefreshOutcome.updated);
      expect(channel.isLive, isTrue);
    });

    test('a 429 says nothing about the token', () async {
      auth.setHelix(const TwitchAuthStatus(
          state: TwitchAuthState.valid, login: 'mohsenblur'));
      final twitch = FakeTwitch((_) => jsonResponse({}, status: 429));
      await serviceFor(twitch)
          .fetchChannelStats(known('streamer', '111'), settings);
      expect(auth.helix.value.state, TwitchAuthState.valid);
    });

    test('callers that throw get the typed exception, not an auth failure',
        () async {
      final twitch = FakeTwitch((_) => jsonResponse({}, status: 429));
      await expectLater(
        serviceFor(twitch).fetchFollowedChannels(settings),
        throwsA(isA<TwitchRateLimitedException>()
            .having((e) => e.isAuthFailure, 'isAuthFailure', isFalse)
            .having((e) => e.endpoint, 'endpoint', 'helix/users')),
      );
    });
  });

  group('shared transport', () {
    test('concurrency is capped across every caller', () async {
      final twitch = FakeTwitch((request) => request.url.path == '/helix/streams'
          ? jsonResponse({'data': []})
          : jsonResponse({'total': 1}))
        ..latency = const Duration(milliseconds: 5);
      final api = serviceFor(twitch, maxConcurrent: 3);
      final channels = [for (var i = 0; i < 12; i++) known('c$i', '$i')];

      final outcomes = await Future.wait(
          channels.map((c) => api.fetchChannelStats(c, settings)));

      expect(outcomes, everyElement(ChannelRefreshOutcome.updated));
      expect(twitch.requests, hasLength(24));
      expect(twitch.peakInFlight, lessThanOrEqualTo(3),
          reason: 'twelve channels used to open 24 connections at once');
      expect(twitch.peakInFlight, greaterThan(1),
          reason: 'capped, not serialised');
    });

    test('the token test is not queued behind a refresh', () async {
      final gate = Completer<void>();
      final twitch = FakeTwitch((request) async {
        if (request.url.host == 'id.twitch.tv') {
          return jsonResponse({
            'login': 'mohsenblur',
            'client_id': settings.twitchClientId,
            'scopes': ['user:read:follows'],
          });
        }
        await gate.future;
        return jsonResponse({'data': []});
      });
      final api = serviceFor(twitch, maxConcurrent: 1);
      final pending = api.fetchChannelStats(known('busy', '1'), settings);

      final status = await api.validateHelixToken(
          'account-token', settings.twitchClientId);
      expect(status.state, TwitchAuthState.valid);

      gate.complete();
      await pending;
    });
  });
}
