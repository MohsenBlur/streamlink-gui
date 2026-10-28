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
http.Response jsonResponse(
  Object body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.Response(
  json.encode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

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
      'ratelimit-reset': '${serverNow.add(d).millisecondsSinceEpoch ~/ 1000}',
    };

    test('an ordinary success asks for nothing', () {
      expect(
        rateLimitBackoff(
          statusCode: 200,
          headers: {'ratelimit-remaining': '799'},
          now: serverNow,
        ),
        isNull,
      );
    });

    test('a 429 waits until Ratelimit-Reset, on Twitch\'s clock', () {
      // The local clock is an hour fast. Measured against it, the reset
      // would already be in the past and the app would hammer a drained
      // bucket; measured against the response's Date header it is 20s away.
      final wait = rateLimitBackoff(
        statusCode: 429,
        headers: resetIn(const Duration(seconds: 20)),
        now: serverNow.add(const Duration(hours: 1)),
      );
      expect(wait, const Duration(seconds: 20));
    });

    test('an exhausted bucket backs off before the 429 happens', () {
      final wait = rateLimitBackoff(
        statusCode: 200,
        headers: {
          ...resetIn(const Duration(seconds: 7)),
          'ratelimit-remaining': '0',
        },
        now: serverNow,
      );
      expect(wait, const Duration(seconds: 7));
    });

    test('an exhausted bucket with no reset time asks for nothing', () {
      expect(
        rateLimitBackoff(
          statusCode: 200,
          headers: {'ratelimit-remaining': '0'},
          now: serverNow,
        ),
        isNull,
      );
    });

    test('Retry-After is honoured when there is no reset header', () {
      expect(
        rateLimitBackoff(
          statusCode: 429,
          headers: {'retry-after': '12'},
          now: serverNow,
        ),
        const Duration(seconds: 12),
      );
    });

    test('a bare 429 still backs off', () {
      expect(
        rateLimitBackoff(statusCode: 429, headers: {}, now: serverNow),
        kDefaultRateLimitBackoff,
      );
    });

    test('the wait is bounded both ways', () {
      expect(
        rateLimitBackoff(
          statusCode: 429,
          headers: resetIn(const Duration(seconds: -30)),
          now: serverNow,
        ),
        const Duration(seconds: 1),
        reason: 'a reset already passed still gets a breath, not a retry storm',
      );
      expect(
        rateLimitBackoff(
          statusCode: 429,
          headers: resetIn(const Duration(days: 3)),
          now: serverNow,
        ),
        kMaxRateLimitBackoff,
        reason: 'one odd header must not silence the app for days',
      );
    });
  });

  group('a 429 is not a channel failure', () {
    test(
      'a rate-limited refresh leaves the channel exactly as it was',
      () async {
        final twitch = FakeTwitch(
          (_) => jsonResponse(
            {'message': 'Too Many Requests'},
            status: 429,
            headers: {'retry-after': '20'},
          ),
        );
        final api = serviceFor(twitch);
        final channel = known('streamer', '111')
          ..isLive = true
          ..streamId = 'stream-111'
          ..consecutiveFailures = 2
          ..errorMessage = 'earlier problem';

        final outcome = await api.fetchChannelStats(channel, settings);

        expect(outcome, ChannelRefreshOutcome.rateLimited);
        expect(
          channel.isLive,
          isTrue,
          reason: 'two failures plus a 429 used to reach the offline threshold',
        );
        expect(channel.streamId, 'stream-111');
        expect(channel.consecutiveFailures, 2);
        expect(channel.errorMessage, 'earlier problem');
        expect(channel.isLoading, isFalse);
      },
    );

    test('a channel that never loaded is told why, so Add refuses it', () async {
      // main.dart's _addChannel adds the channel unless errorMessage is set.
      // Restoring an empty error here would add a name nobody had checked.
      final twitch = FakeTwitch((_) => jsonResponse({}, status: 429));
      final api = serviceFor(twitch);
      final brandNew = TwitchChannel(username: 'newcomer');
      final loadedBefore = known('regular', '5')
        ..lastUpdated = clock.subtract(const Duration(minutes: 1));

      expect(await api.fetchChannelStats(brandNew, settings),
          ChannelRefreshOutcome.rateLimited);
      expect(brandNew.errorMessage, contains('rate limiting'));
      expect(brandNew.consecutiveFailures, 0);

      final batch = await api.refreshLiveStatus([loadedBefore], settings);
      expect(batch.outcomes[loadedBefore], ChannelRefreshOutcome.rateLimited);
      expect(loadedBefore.errorMessage, isNull,
          reason: 'a channel with good data keeps showing it, unannotated');
    });

    test('an ordinary error still counts, and three go offline', () async {
      final twitch = FakeTwitch((_) => jsonResponse({}, status: 500));
      final api = serviceFor(twitch);
      final channel = known('streamer', '111')..isLive = true;

      expect(
        await api.fetchChannelStats(channel, settings),
        ChannelRefreshOutcome.failed,
      );
      expect(channel.consecutiveFailures, 1);
      expect(channel.isLive, isTrue);
      expect(channel.errorMessage, 'Helix Stream API error: status 500');

      await api.fetchChannelStats(channel, settings);
      await api.fetchChannelStats(channel, settings);
      expect(channel.isLive, isFalse);
    });

    test(
      'the back-off is honoured: nothing is sent until it expires',
      () async {
        var limited = true;
        final twitch = FakeTwitch((request) {
          if (limited) {
            return jsonResponse(
              {},
              status: 429,
              headers: {'retry-after': '20'},
            );
          }
          return request.url.path == '/helix/streams'
              ? jsonResponse({
                  'data': [liveStream('111')],
                })
              : jsonResponse({'total': 5});
        });
        final api = serviceFor(twitch);
        final channel = known('streamer', '111');

        await api.fetchChannelStats(channel, settings);
        expect(twitch.requests, hasLength(1));
        expect(
          api.helixRateLimitedUntil,
          clock.add(const Duration(seconds: 20)),
        );

        limited = false;
        clock = clock.add(const Duration(seconds: 10));
        expect(
          await api.fetchChannelStats(channel, settings),
          ChannelRefreshOutcome.rateLimited,
        );
        expect(
          twitch.requests,
          hasLength(1),
          reason: 'a request inside the back-off is refused locally',
        );

        clock = clock.add(const Duration(seconds: 11));
        expect(api.helixRateLimitedUntil, isNull);
        expect(
          await api.fetchChannelStats(channel, settings),
          ChannelRefreshOutcome.updated,
        );
        expect(channel.isLive, isTrue);
      },
    );

    test('a 429 says nothing about the token', () async {
      auth.setHelix(
        const TwitchAuthStatus(
          state: TwitchAuthState.valid,
          login: 'mohsenblur',
        ),
      );
      final twitch = FakeTwitch((_) => jsonResponse({}, status: 429));
      await serviceFor(
        twitch,
      ).fetchChannelStats(known('streamer', '111'), settings);
      expect(auth.helix.value.state, TwitchAuthState.valid);
    });

    test(
      'callers that throw get the typed exception, not an auth failure',
      () async {
        final twitch = FakeTwitch((_) => jsonResponse({}, status: 429));
        await expectLater(
          serviceFor(twitch).fetchFollowedChannels(settings),
          throwsA(
            isA<TwitchRateLimitedException>()
                .having((e) => e.isAuthFailure, 'isAuthFailure', isFalse)
                .having((e) => e.endpoint, 'endpoint', 'helix/users'),
          ),
        );
      },
    );
  });

  group('values never escape their parameter', () {
    test(
      'a name that cannot be a login is refused before any request',
      () async {
        final twitch = FakeTwitch((_) => jsonResponse({'data': []}));
        final api = serviceFor(twitch);
        for (final s in [settings, AppSettings()]) {
          final channel = TwitchChannel(username: 'foo&login=bar');
          expect(
            await api.fetchChannelStats(channel, s),
            ChannelRefreshOutcome.failed,
          );
          expect(channel.errorMessage, contains('not a valid Twitch username'));
        }
        expect(
          twitch.requests,
          isEmpty,
          reason:
              'this used to send a two-user query and bind whichever '
              'account came back first to the typed name',
        );
      },
    );

    test('a login is sent as exactly one value', () async {
      final twitch = FakeTwitch(
        (request) => switch (request.url.path) {
          '/helix/users' => jsonResponse({
            'data': [
              {'id': '123', 'profile_image_url': 'https://img/a.png'},
            ],
          }),
          '/helix/streams' => jsonResponse({'data': []}),
          _ => jsonResponse({'total': 1}),
        },
      );
      await serviceFor(
        twitch,
      ).fetchChannelStats(TwitchChannel(username: 'some_user'), settings);
      expect(twitch.to('/helix/users').single.url.queryParametersAll, {
        'login': ['some_user'],
      });
      expect(
        twitch.to('/helix/streams').single.url.queryParameters['user_id'],
        '123',
      );
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
      expect(
        twitch.to('/helix/videos').single.url.queryParameters['after'],
        cursor,
      );
    });

    test(
      'a stored id that is not a number is resolved again, not sent',
      () async {
        final twitch = FakeTwitch(
          (request) => switch (request.url.path) {
            '/helix/users' => jsonResponse({
              'data': [
                {'id': '987', 'profile_image_url': 'https://img/a.png'},
              ],
            }),
            '/helix/streams' => jsonResponse({'data': []}),
            _ => jsonResponse({'total': 1}),
          },
        );
        final channel = TwitchChannel(
          username: 'streamer',
          id: 'Error: rate limited',
          avatarUrl: 'https://img/old.png',
        );

        expect(
          await serviceFor(twitch).fetchChannelStats(channel, settings),
          ChannelRefreshOutcome.updated,
        );
        expect(channel.id, '987');
        expect(
          twitch.to('/helix/users').single.url.queryParameters['login'],
          'streamer',
        );
        expect(
          twitch.to('/helix/streams').single.url.queryParameters['user_id'],
          '987',
          reason: 'helix/streams?user_id=<garbage> is a 400 on every poll',
        );
      },
    );
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
        await serviceFor(
          decapi(liveBodies()),
        ).fetchChannelStats(channel, anonymous),
        ChannelRefreshOutcome.updated,
      );
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
      await serviceFor(
        decapi({...liveBodies(), 'uptime': 'streamer is offline'}),
      ).fetchChannelStats(channel, anonymous);
      expect(channel.isLive, isFalse);
      expect(channel.uptime, 'Offline');
    });

    test('an error sentence in the uptime is not a live stream', () async {
      // Every non-"offline" body used to mean live: the error text became the
      // uptime and fired a "now LIVE" toast.
      final channel = TwitchChannel(username: 'streamer');
      final outcome = await serviceFor(
        decapi({
          ...liveBodies(),
          'uptime': 'An error occurred retrieving uptime for streamer',
        }),
      ).fetchChannelStats(channel, anonymous);
      expect(outcome, ChannelRefreshOutcome.failed);
      expect(channel.isLive, isFalse);
      expect(channel.errorMessage, contains('unreadable live status'));
    });

    test('an error sentence is never stored as the channel id', () async {
      final channel = TwitchChannel(username: 'streamer');
      final outcome = await serviceFor(
        decapi({...liveBodies(), 'id': 'Rate limit exceeded, slow down'}),
      ).fetchChannelStats(channel, anonymous);
      expect(outcome, ChannelRefreshOutcome.failed);
      expect(
        channel.id,
        isNull,
        reason: 'it was persisted and sent to Helix forever after',
      );
    });

    test('a failed cosmetic request does not fail the live check', () async {
      final channel = TwitchChannel(username: 'streamer');
      final outcome = await serviceFor(
        decapi({...liveBodies(), 'followcount': const SocketLikeException()}),
      ).fetchChannelStats(channel, anonymous);
      expect(outcome, ChannelRefreshOutcome.updated);
      expect(channel.isLive, isTrue);
    });

    test('decoration that is not what it claims to be is ignored', () async {
      final channel = TwitchChannel(
        username: 'streamer',
        avatarUrl: 'https://img/kept.png',
      )..followerCount = '1.0K';
      await serviceFor(
        decapi({
          ...liveBodies(),
          'avatar': 'User not found: streamer',
          'followcount': 'Error retrieving follow count',
          'viewercount': 'Something went wrong',
        }),
      ).fetchChannelStats(channel, anonymous);
      expect(channel.avatarUrl, 'https://img/kept.png');
      expect(channel.followerCount, '1.0K');
      expect(channel.viewerCount, isNull);
    });

    test('the VOD path does not adopt a DecAPI error as the id', () async {
      final twitch = FakeTwitch(
        (request) => request.url.host == 'decapi.me'
            ? http.Response('An error occurred', 200)
            : jsonResponse({'data': []}),
      );
      final channel = TwitchChannel(username: 'streamer');
      await expectLater(
        serviceFor(twitch).fetchVodsForChannel(
          channel: channel,
          settings: settings,
          localVodsProgress: {},
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Could not resolve'),
          ),
        ),
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
    }) => FakeTwitch((request) {
      if (request.url.path == '/helix/users') {
        return jsonResponse({
          'data': [
            {
              'id': '1',
              'login': 'me',
              'profile_image_url': 'https://img/me.png',
            },
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
      final result = await serviceFor(
        followed(),
      ).fetchFollowedChannels(settings);
      expect(result.channels, hasLength(300));
      expect(result.isComplete, isTrue);
      expect(result.pageError, isNull);
    });

    test('a failed later page is reported, not swallowed', () async {
      final result = await serviceFor(
        followed(failPage: 2, failure: () => jsonResponse({}, status: 503)),
      ).fetchFollowedChannels(settings);
      expect(
        result.channels,
        hasLength(200),
        reason: 'the pages that did arrive are still real',
      );
      expect(result.isComplete, isFalse);
      expect(
        result.pageError,
        isA<TwitchApiException>().having((e) => e.statusCode, 'status', 503),
      );
    });

    test(
      'a rate limit or a dropped connection part-way is partial too',
      () async {
        final limited = await serviceFor(
          followed(failPage: 1, failure: () => jsonResponse({}, status: 429)),
        ).fetchFollowedChannels(settings);
        expect(limited.isComplete, isFalse);
        expect(limited.pageError, isA<TwitchRateLimitedException>());

        final dropped = await serviceFor(
          followed(
            failPage: 1,
            failure: () => throw const SocketLikeException(),
          ),
        ).fetchFollowedChannels(settings);
        expect(dropped.channels, hasLength(100));
        expect(dropped.isComplete, isFalse);
        expect(dropped.pageError, isA<SocketLikeException>());
      },
    );

    test('a refused token on a later page throws for the banner', () async {
      await expectLater(
        serviceFor(
          followed(failPage: 1, failure: () => jsonResponse({}, status: 401)),
        ).fetchFollowedChannels(settings),
        throwsA(
          isA<TwitchApiException>().having(
            (e) => e.isAuthFailure,
            'isAuthFailure',
            isTrue,
          ),
        ),
      );
    });

    test('a failure on the first page still throws', () async {
      await expectLater(
        serviceFor(
          followed(failPage: 0, failure: () => jsonResponse({}, status: 503)),
        ).fetchFollowedChannels(settings),
        throwsA(isA<TwitchApiException>()),
      );
    });

    test('running into the page cap is incomplete, with no error', () async {
      final result = await serviceFor(
        followed(pages: 25, perPage: 1),
      ).fetchFollowedChannels(settings);
      expect(result.channels, hasLength(20));
      expect(result.isComplete, isFalse);
      expect(result.pageError, isNull);
    });

    group('reconcileWith', () {
      TwitchChannel fresh(String name, String id) =>
          TwitchChannel(username: name, id: id);

      test('a complete result keeps existing objects and drops unfollows', () {
        final kept = TwitchChannel(
          username: 'kept',
          id: '1',
          avatarUrl: 'https://img/kept.png',
        )..isLive = true;
        final unfollowed = TwitchChannel(username: 'gone', id: '2');
        final result = FollowedChannelsResult(
          channels: [fresh('newcomer', '3'), fresh('kept', '1')],
          userLogin: 'me',
        );

        final merged = result.reconcileWith([kept, unfollowed]);

        expect(merged.map((c) => c.username), ['newcomer', 'kept']);
        expect(
          identical(merged[1], kept),
          isTrue,
          reason:
              'a reload used to swap in blank objects: avatars lost, '
              'live state reset, the selected channel orphaned',
        );
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

  group('refreshLiveStatus batches the poll', () {
    /// A Helix that knows [users] (login -> id) and treats [liveIds] as live.
    /// helix/streams honours `first` with Twitch's default page size of 20.
    FakeTwitch helix({
      Map<String, String> users = const {},
      Set<String> liveIds = const {},
      FutureOr<http.Response>? Function(http.Request request)? override,
    }) => FakeTwitch((request) {
      final special = override?.call(request);
      if (special != null) return special;
      final q = request.url.queryParametersAll;
      switch (request.url.path) {
        case '/helix/users':
          final wantedIds = q['id'] ?? const <String>[];
          final wantedLogins = q['login'] ?? const <String>[];
          return jsonResponse({
            'data': [
              for (final e in users.entries)
                if (wantedIds.contains(e.value) || wantedLogins.contains(e.key))
                  {
                    'id': e.value,
                    'login': e.key,
                    'profile_image_url': 'https://img/${e.key}.png',
                  },
            ],
          });
        case '/helix/streams':
          final first = int.parse(request.url.queryParameters['first'] ?? '20');
          return jsonResponse({
            'data': [
              for (final id in q['user_id'] ?? const <String>[])
                if (liveIds.contains(id)) liveStream(id),
            ].take(first).toList(),
          });
      }
      return jsonResponse({}, status: 404);
    });

    test('250 known channels cost three requests, not five hundred', () async {
      final channels = [for (var i = 0; i < 250; i++) known('c$i', '${i + 1}')];
      final twitch = helix(liveIds: {'5', '150', '250'});

      final result = await serviceFor(
        twitch,
      ).refreshLiveStatus(channels, settings);

      expect(twitch.requests, hasLength(3));
      expect(
        twitch
            .to('/helix/streams')
            .map((r) => r.url.queryParametersAll['user_id']!.length),
        unorderedEquals([100, 100, 50]),
      );
      expect(
        twitch.to('/helix/channels/followers'),
        isEmpty,
        reason: 'follower counts are not a per-minute concern',
      );
      expect(
        result.outcomes.values,
        everyElement(ChannelRefreshOutcome.updated),
      );
      expect(result.wasRateLimited, isFalse);

      final live = channels.where((c) => c.isLive).map((c) => c.id);
      expect(live, unorderedEquals(['5', '150', '250']));
      final c5 = channels[4];
      expect(c5.streamId, 'stream-5');
      expect(c5.viewerCount, '42');
      expect(c5.wentLiveTime, DateTime.utc(2026, 10, 28, 10).toLocal());
      expect(channels[0].uptime, 'Offline');
    });

    test('more than 20 live channels in one request are all seen', () async {
      final channels = [for (var i = 0; i < 40; i++) known('c$i', '${i + 1}')];
      final twitch = helix(liveIds: {for (var i = 1; i <= 30; i++) '$i'});

      await serviceFor(twitch).refreshLiveStatus(channels, settings);

      expect(
        channels.where((c) => c.isLive),
        hasLength(30),
        reason: 'helix/streams pages at 20 unless asked for more',
      );
    });

    test('missing identities are resolved in one lookup first', () async {
      final noId = [
        TwitchChannel(username: 'alpha'),
        TwitchChannel(username: 'beta', id: 'Error: rate limited'),
        TwitchChannel(username: 'ghost'),
      ];
      final noAvatar = TwitchChannel(username: 'gamma', id: '3');
      final twitch = helix(
        users: {'alpha': '1', 'beta': '2', 'gamma': '3'},
        liveIds: {'2'},
      );

      final result = await serviceFor(
        twitch,
      ).refreshLiveStatus([...noId, noAvatar], settings);

      final lookup = twitch.to('/helix/users').single.url.queryParametersAll;
      expect(lookup['login'], unorderedEquals(['alpha', 'beta', 'ghost']));
      expect(lookup['id'], ['3'], reason: 'by id when the id is known');
      expect(noId[0].id, '1');
      expect(noId[1].id, '2');
      expect(noId[1].isLive, isTrue);
      expect(noAvatar.avatarUrl, 'https://img/gamma.png');

      expect(result.outcomes[noId[2]], ChannelRefreshOutcome.failed);
      expect(noId[2].errorMessage, contains('not found'));
      expect(
        twitch.to('/helix/streams').single.url.queryParametersAll['user_id'],
        unorderedEquals(['1', '2', '3']),
        reason: 'an unresolved channel is never sent as user_id',
      );
    });

    test('a name that cannot be a login is failed without a request', () async {
      final twitch = helix();
      final bad = TwitchChannel(username: 'foo&login=bar');
      final result = await serviceFor(
        twitch,
      ).refreshLiveStatus([bad], settings);
      expect(result.outcomes[bad], ChannelRefreshOutcome.failed);
      expect(twitch.requests, isEmpty);
    });

    test('a favourite and its followed-list twin share one id slot', () async {
      final favourite = known('streamer', '7');
      final followedTwin = known('streamer', '7');
      final twitch = helix(liveIds: {'7'});

      final result = await serviceFor(
        twitch,
      ).refreshLiveStatus([favourite, followedTwin, favourite], settings);

      expect(result.outcomes, hasLength(2));
      expect(
        twitch.to('/helix/streams').single.url.queryParametersAll['user_id'],
        ['7'],
      );
      expect(favourite.isLive && followedTwin.isLive, isTrue);
    });

    test('a failed chunk counts against only the channels in it', () async {
      final channels = [
        for (var i = 0; i < 150; i++) known('c$i', '${i + 1}')..isLive = true,
      ];
      final twitch = helix(
        liveIds: {for (var i = 1; i <= 150; i++) '$i'},
        override: (request) =>
            request.url.queryParametersAll['user_id']?.contains('150') == true
            ? jsonResponse({}, status: 503)
            : null,
      );

      final result = await serviceFor(
        twitch,
      ).refreshLiveStatus(channels, settings);

      expect(result.failed, hasLength(50));
      final failedChannel = result.failed.first;
      expect(failedChannel.consecutiveFailures, 1);
      expect(
        failedChannel.isLive,
        isTrue,
        reason: 'one failure is not a go-offline',
      );
      expect(failedChannel.errorMessage, 'Helix Stream API error: status 503');
      expect(channels.first.consecutiveFailures, 0);
    });

    test('a failed identity lookup still checks the channels it can', () async {
      final hasId = TwitchChannel(username: 'known', id: '1');
      final noId = TwitchChannel(username: 'unknown');
      final twitch = helix(
        liveIds: {'1'},
        override: (request) => request.url.path == '/helix/users'
            ? jsonResponse({}, status: 500)
            : null,
      );

      final result = await serviceFor(
        twitch,
      ).refreshLiveStatus([hasId, noId], settings);

      expect(
        result.outcomes[hasId],
        ChannelRefreshOutcome.updated,
        reason: 'it only wanted an avatar; the live state should not wait',
      );
      expect(hasId.isLive, isTrue);
      expect(result.outcomes[noId], ChannelRefreshOutcome.failed);
      expect(noId.errorMessage, 'Helix User API error: status 500');
    });

    test(
      'a 429 leaves every channel as it was and reports when to retry',
      () async {
        final channels = [
          known('a', '1')
            ..isLive = true
            ..consecutiveFailures = 2,
          known('b', '2'),
          TwitchChannel(username: 'c'),
        ];
        final twitch = FakeTwitch(
          (_) => jsonResponse({}, status: 429, headers: {'retry-after': '15'}),
        );
        final api = serviceFor(twitch);

        final result = await api.refreshLiveStatus(channels, settings);

        expect(
          result.outcomes.values,
          everyElement(ChannelRefreshOutcome.rateLimited),
        );
        expect(result.wasRateLimited, isTrue);
        expect(result.failed, isEmpty);
        expect(result.rateLimitedUntil, clock.add(const Duration(seconds: 15)));
        expect(channels[0].isLive, isTrue);
        expect(
          channels[0].consecutiveFailures,
          2,
          reason: 'a 429 used to be the third strike that flipped it offline',
        );
        expect(channels.every((c) => !c.isLoading), isTrue);
        expect(
          twitch.requests,
          hasLength(1),
          reason:
              'the stream check behind the failed lookup was refused '
              'locally instead of spending another request',
        );

        final again = await api.refreshLiveStatus(channels, settings);
        expect(again.wasRateLimited, isTrue);
        expect(twitch.requests, hasLength(1));
      },
    );

    test('an oddly typed stream entry does not escape as an exception', () async {
      // refreshLiveStatus promises an outcome per channel and never a throw;
      // the entries are applied outside its try, so a hard cast there broke
      // that promise for every channel in the pass.
      final channel = known('streamer', '7');
      final other = known('other', '8');
      final twitch = FakeTwitch((_) => jsonResponse({
            'data': [
              {
                'id': 99,
                'user_id': '7',
                'title': 123,
                'game_name': null,
                'viewer_count': 5,
                'started_at': 1700000000,
              },
            ],
          }));

      final result =
          await serviceFor(twitch).refreshLiveStatus([channel, other], settings);

      expect(result.outcomes[channel], ChannelRefreshOutcome.updated);
      expect(result.outcomes[other], ChannelRefreshOutcome.updated);
      expect(channel.isLive, isTrue);
      expect(channel.streamTitle, isNull);
      expect(channel.uptime, 'Live');
      expect(other.isLive, isFalse);
    });

    test('an empty list costs nothing', () async {
      final twitch = helix();
      final result = await serviceFor(twitch).refreshLiveStatus([], settings);
      expect(result.outcomes, isEmpty);
      expect(twitch.requests, isEmpty);
    });

    test('without a token each channel takes the DecAPI path', () async {
      final twitch = FakeTwitch((request) {
        final what = request.url.pathSegments[1];
        return http.Response(
          what == 'id' ? '99' : (what == 'uptime' ? 'x is offline' : ''),
          200,
        );
      });
      final channel = TwitchChannel(username: 'streamer');
      final result = await serviceFor(
        twitch,
      ).refreshLiveStatus([channel], AppSettings());
      expect(result.outcomes[channel], ChannelRefreshOutcome.updated);
      expect(twitch.requests.every((r) => r.url.host == 'decapi.me'), isTrue);
    });
  });

  group('the token probe', () {
    FakeTwitch validate(String mintedFor) => FakeTwitch(
          (_) => jsonResponse({
            'login': 'mohsenblur',
            'client_id': mintedFor,
            'scopes': ['user:read:follows'],
          }),
        );
    const publicClient = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    test('a blank Client ID is judged as the client actually sent', () async {
      // Helix gets Twitch's public client when the field is blank. A token
      // minted elsewhere 401s on every request, so the probe calling it
      // valid set up a valid/rejected flip on every refresh.
      final status = await serviceFor(validate('some-other-client'))
          .validateHelixToken('account-token', '   ');
      expect(status.state, TwitchAuthState.invalid);
      expect(status.fault, TwitchAuthFault.clientIdMismatch);
    });

    test('a token minted for the public client still passes blank', () async {
      final status = await serviceFor(validate(publicClient))
          .validateHelixToken('account-token', '');
      expect(status.state, TwitchAuthState.valid);
    });

    test('the probe stamps the pair it judged', () async {
      // So the first Helix 200 sent with a different pair afterwards is
      // recognised as new evidence rather than a repeat.
      auth.recordHelixProbe(await serviceFor(validate('other'))
          .validateHelixToken('account-token', 'mine'));
      expect(auth.helix.value.fault, TwitchAuthFault.clientIdMismatch);
      auth.recordHelixResponse(200,
          credential: helixCredentialFingerprint('account-token', 'mine'));
      expect(auth.helix.value.fault, TwitchAuthFault.clientIdMismatch,
          reason: 'the same pair succeeding proves nothing new');
      auth.recordHelixResponse(200,
          credential: helixCredentialFingerprint('account-token', 'other'));
      expect(auth.helix.value.isUsable, isTrue,
          reason: 'a corrected Client ID clears it on its first success');
    });
  });

  group('shared transport', () {
    test('concurrency is capped across every caller', () async {
      final twitch = FakeTwitch(
        (request) => request.url.path == '/helix/streams'
            ? jsonResponse({'data': []})
            : jsonResponse({'total': 1}),
      )..latency = const Duration(milliseconds: 5);
      final api = serviceFor(twitch, maxConcurrent: 3);
      final channels = [for (var i = 0; i < 12; i++) known('c$i', '$i')];

      final outcomes = await Future.wait(
        channels.map((c) => api.fetchChannelStats(c, settings)),
      );

      expect(outcomes, everyElement(ChannelRefreshOutcome.updated));
      expect(twitch.requests, hasLength(24));
      expect(
        twitch.peakInFlight,
        lessThanOrEqualTo(3),
        reason: 'twelve channels used to open 24 connections at once',
      );
      expect(
        twitch.peakInFlight,
        greaterThan(1),
        reason: 'capped, not serialised',
      );
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
        'account-token',
        settings.twitchClientId,
      );
      expect(status.state, TwitchAuthState.valid);

      gate.complete();
      await pending;
    });
  });
}
