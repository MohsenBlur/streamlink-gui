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

/// Stands in for a socket reset on one request.
class SocketLikeException implements Exception {
  const SocketLikeException();
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

  group('values never escape their parameter', () {
    test('a name that cannot be a login is refused before any request',
        () async {
      final twitch = FakeTwitch((_) => jsonResponse({'data': []}));
      final api = serviceFor(twitch);
      for (final s in [settings, AppSettings()]) {
        final channel = TwitchChannel(username: 'foo&login=bar');
        expect(await api.fetchChannelStats(channel, s),
            ChannelRefreshOutcome.failed);
        expect(channel.errorMessage, contains('not a valid Twitch username'));
      }
      expect(twitch.requests, isEmpty,
          reason: 'this used to send a two-user query and bind whichever '
              'account came back first to the typed name');
    });

    test('a login is sent as exactly one value', () async {
      final twitch = FakeTwitch((request) => switch (request.url.path) {
            '/helix/users' => jsonResponse({
                'data': [
                  {'id': '123', 'profile_image_url': 'https://img/a.png'},
                ],
              }),
            '/helix/streams' => jsonResponse({'data': []}),
            _ => jsonResponse({'total': 1}),
          });
      await serviceFor(twitch)
          .fetchChannelStats(TwitchChannel(username: 'some_user'), settings);
      expect(twitch.to('/helix/users').single.url.queryParametersAll,
          {'login': ['some_user']});
      expect(twitch.to('/helix/streams').single.url.queryParameters['user_id'],
          '123');
    });

    test('the Load-more cursor reaches Twitch intact', () async {
      // Base64 cursors can carry + / and =. The raw append delivered the
      // + as a space, so Twitch decoded a different cursor.
      const cursor = 'eyJiIjp7Ik+Zmb3/NldCI6MX19==';
      final twitch = FakeTwitch((_) => jsonResponse({'data': []}));
      await serviceFor(twitch).fetchVodsForChannel(
        channel: known('streamer', '111'),
        settings: settings,
        localVodsProgress: {},
        afterCursor: cursor,
      );
      expect(twitch.to('/helix/videos').single.url.queryParameters['after'],
          cursor);
    });

    test('a stored id that is not a number is resolved again, not sent',
        () async {
      final twitch = FakeTwitch((request) => switch (request.url.path) {
            '/helix/users' => jsonResponse({
                'data': [
                  {'id': '987', 'profile_image_url': 'https://img/a.png'},
                ],
              }),
            '/helix/streams' => jsonResponse({'data': []}),
            _ => jsonResponse({'total': 1}),
          });
      final channel = TwitchChannel(
          username: 'streamer',
          id: 'Error: rate limited',
          avatarUrl: 'https://img/old.png');

      expect(await serviceFor(twitch).fetchChannelStats(channel, settings),
          ChannelRefreshOutcome.updated);
      expect(channel.id, '987');
      expect(twitch.to('/helix/users').single.url.queryParameters['login'],
          'streamer');
      expect(twitch.to('/helix/streams').single.url.queryParameters['user_id'],
          '987',
          reason: 'helix/streams?user_id=<garbage> is a 400 on every poll');
    });
  });

  group('DecAPI answers are read, not trusted', () {
    // Without an account token the app falls back to DecAPI, which answers
    // many errors with status 200 and a sentence of plain text.
    final anonymous = AppSettings();

    FakeTwitch decapi(Map<String, Object> bodies) => FakeTwitch((request) {
          final what = request.url.pathSegments[1];
          final body = bodies[what];
          if (body is Exception) throw body;
          return http.Response('${body ?? ''}', 200);
        });

    Map<String, Object> liveBodies() => {
          'id': '4242',
          'avatar': 'https://img/streamer.png',
          'uptime': '2 hours, 13 minutes, 7 seconds',
          'followcount': '12345',
          'viewercount': '678',
          'game': 'Chess',
          'title': 'Endgames',
        };

    test('a live answer is applied', () async {
      final channel = TwitchChannel(username: 'streamer');
      expect(
          await serviceFor(decapi(liveBodies()))
              .fetchChannelStats(channel, anonymous),
          ChannelRefreshOutcome.updated);
      expect(channel.isLive, isTrue);
      expect(channel.uptime, '2 hours, 13 minutes, 7 seconds');
      expect(channel.id, '4242');
      expect(channel.avatarUrl, 'https://img/streamer.png');
      expect(channel.followerCount, '12.3K');
      expect(channel.viewerCount, '678');
      expect(channel.streamTitle, 'Endgames');
    });

    test('an offline answer is applied', () async {
      final channel = TwitchChannel(username: 'streamer')..isLive = true;
      await serviceFor(decapi({...liveBodies(), 'uptime': 'streamer is offline'}))
          .fetchChannelStats(channel, anonymous);
      expect(channel.isLive, isFalse);
      expect(channel.uptime, 'Offline');
    });

    test('an error sentence in the uptime is not a live stream', () async {
      // Every non-"offline" body used to mean live: the error text became the
      // uptime and fired a "now LIVE" toast.
      final channel = TwitchChannel(username: 'streamer');
      final outcome = await serviceFor(decapi({
        ...liveBodies(),
        'uptime': 'An error occurred retrieving uptime for streamer',
      })).fetchChannelStats(channel, anonymous);
      expect(outcome, ChannelRefreshOutcome.failed);
      expect(channel.isLive, isFalse);
      expect(channel.errorMessage, contains('unreadable live status'));
    });

    test('an error sentence is never stored as the channel id', () async {
      final channel = TwitchChannel(username: 'streamer');
      final outcome = await serviceFor(
              decapi({...liveBodies(), 'id': 'Rate limit exceeded, slow down'}))
          .fetchChannelStats(channel, anonymous);
      expect(outcome, ChannelRefreshOutcome.failed);
      expect(channel.id, isNull,
          reason: 'it was persisted and sent to Helix forever after');
    });

    test('a failed cosmetic request does not fail the live check', () async {
      final channel = TwitchChannel(username: 'streamer');
      final outcome = await serviceFor(decapi({
        ...liveBodies(),
        'followcount': const SocketLikeException(),
      })).fetchChannelStats(channel, anonymous);
      expect(outcome, ChannelRefreshOutcome.updated);
      expect(channel.isLive, isTrue);
    });

    test('decoration that is not what it claims to be is ignored', () async {
      final channel = TwitchChannel(
          username: 'streamer', avatarUrl: 'https://img/kept.png')
        ..followerCount = '1.0K';
      await serviceFor(decapi({
        ...liveBodies(),
        'avatar': 'User not found: streamer',
        'followcount': 'Error retrieving follow count',
        'viewercount': 'Something went wrong',
      })).fetchChannelStats(channel, anonymous);
      expect(channel.avatarUrl, 'https://img/kept.png');
      expect(channel.followerCount, '1.0K');
      expect(channel.viewerCount, isNull);
    });

    test('the VOD path does not adopt a DecAPI error as the id', () async {
      final twitch = FakeTwitch((request) => request.url.host == 'decapi.me'
          ? http.Response('An error occurred', 200)
          : jsonResponse({'data': []}));
      final channel = TwitchChannel(username: 'streamer');
      await expectLater(
        serviceFor(twitch).fetchVodsForChannel(
            channel: channel, settings: settings, localVodsProgress: {}),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('Could not resolve'))),
      );
      expect(channel.id, isNull);
      expect(twitch.to('/helix/videos'), isEmpty);
    });
  });

  group('the followed list never shrinks silently', () {
    /// Pages of [perPage] follows, named p<page>_<n>; [failPage] answers with
    /// [failure] instead.
    FakeTwitch followed({
      int pages = 3,
      int perPage = 100,
      int? failPage,
      FutureOr<http.Response> Function()? failure,
    }) =>
        FakeTwitch((request) {
          if (request.url.path == '/helix/users') {
            return jsonResponse({
              'data': [
                {'id': '1', 'login': 'me', 'profile_image_url': 'https://img/me.png'},
              ],
            });
          }
          final after = request.url.queryParameters['after'];
          final page = after == null ? 0 : int.parse(after.substring(4));
          if (page == failPage) return failure!();
          final last = page == pages - 1;
          return jsonResponse({
            'data': [
              for (var n = 0; n < perPage; n++)
                {
                  'broadcaster_id': '${page * 1000 + n + 10}',
                  'broadcaster_login': 'p${page}_$n',
                },
            ],
            'pagination': last ? {} : {'cursor': 'page${page + 1}'},
          });
        });

    test('a complete walk says so', () async {
      final result =
          await serviceFor(followed()).fetchFollowedChannels(settings);
      expect(result.channels, hasLength(300));
      expect(result.isComplete, isTrue);
      expect(result.pageError, isNull);
    });

    test('a failed later page is reported, not swallowed', () async {
      final result = await serviceFor(followed(
              failPage: 2, failure: () => jsonResponse({}, status: 503)))
          .fetchFollowedChannels(settings);
      expect(result.channels, hasLength(200),
          reason: 'the pages that did arrive are still real');
      expect(result.isComplete, isFalse);
      expect(result.pageError,
          isA<TwitchApiException>().having((e) => e.statusCode, 'status', 503));
    });

    test('a rate limit or a dropped connection part-way is partial too',
        () async {
      final limited = await serviceFor(followed(
              failPage: 1, failure: () => jsonResponse({}, status: 429)))
          .fetchFollowedChannels(settings);
      expect(limited.isComplete, isFalse);
      expect(limited.pageError, isA<TwitchRateLimitedException>());

      final dropped = await serviceFor(followed(
              failPage: 1, failure: () => throw const SocketLikeException()))
          .fetchFollowedChannels(settings);
      expect(dropped.channels, hasLength(100));
      expect(dropped.isComplete, isFalse);
      expect(dropped.pageError, isA<SocketLikeException>());
    });

    test('a refused token on a later page throws for the banner', () async {
      await expectLater(
        serviceFor(followed(
                failPage: 1, failure: () => jsonResponse({}, status: 401)))
            .fetchFollowedChannels(settings),
        throwsA(isA<TwitchApiException>()
            .having((e) => e.isAuthFailure, 'isAuthFailure', isTrue)),
      );
    });

    test('a failure on the first page still throws', () async {
      await expectLater(
        serviceFor(followed(
                failPage: 0, failure: () => jsonResponse({}, status: 503)))
            .fetchFollowedChannels(settings),
        throwsA(isA<TwitchApiException>()),
      );
    });

    test('running into the page cap is incomplete, with no error', () async {
      final result = await serviceFor(followed(pages: 25, perPage: 1))
          .fetchFollowedChannels(settings);
      expect(result.channels, hasLength(20));
      expect(result.isComplete, isFalse);
      expect(result.pageError, isNull);
    });

    group('reconcileWith', () {
      TwitchChannel fresh(String name, String id) =>
          TwitchChannel(username: name, id: id);

      test('a complete result keeps existing objects and drops unfollows', () {
        final kept = TwitchChannel(
            username: 'kept', id: '1', avatarUrl: 'https://img/kept.png')
          ..isLive = true;
        final unfollowed = TwitchChannel(username: 'gone', id: '2');
        final result = FollowedChannelsResult(
          channels: [fresh('newcomer', '3'), fresh('kept', '1')],
          userLogin: 'me',
        );

        final merged = result.reconcileWith([kept, unfollowed]);

        expect(merged.map((c) => c.username), ['newcomer', 'kept']);
        expect(identical(merged[1], kept), isTrue,
            reason: 'a reload used to swap in blank objects: avatars lost, '
                'live state reset, the selected channel orphaned');
        expect(merged[1].isLive, isTrue);
        expect(merged[1].avatarUrl, 'https://img/kept.png');
      });

      test('an incomplete result keeps the channels it never reached', () {
        final unreached = TwitchChannel(username: 'page_three', id: '9');
        final result = FollowedChannelsResult(
          channels: [fresh('page_one', '1')],
          userLogin: 'me',
          isComplete: false,
        );
        final merged = result.reconcileWith([unreached]);
        expect(merged.map((c) => c.username), ['page_one', 'page_three']);
        expect(identical(merged[1], unreached), isTrue);
      });
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
