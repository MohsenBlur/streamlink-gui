import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';

/// A small, stateful Twitch for the refresh tests: channels that go live and
/// offline, archives that grow, a followed list, and a rate limit that can be
/// switched on. The real [TwitchApiService] talks to it through a fake
/// `http.Client`, so what is tested is the app's own request and parsing
/// code, not a stand-in for it.
class FakeHelix {
  FakeHelix({DateTime? now}) : now = now ?? DateTime.utc(2026, 10, 28, 12);

  /// The clock shared with the service, so back-offs and the controllers'
  /// "how old is this" checks agree.
  DateTime now;

  final Map<String, String> _ids = <String, String>{};
  final Map<String, Map<String, dynamic>> _streams = <String, Map<String, dynamic>>{};
  final Map<String, List<Map<String, dynamic>>> _videos =
      <String, List<Map<String, dynamic>>>{};
  final List<String> followed = <String>[];

  /// Every request, in arrival order.
  final List<http.Request> requests = <http.Request>[];

  /// helix/streams answers 429 while set.
  bool rateLimitStreams = false;

  /// helix/videos answers 500 while set.
  bool failVideos = false;

  /// When set, helix/videos waits for it before answering.
  Completer<void>? holdVideos;

  /// When set, helix/streams waits for it before answering.
  Completer<void>? holdStreams;

  /// When set, helix/channels/followed waits for it before answering.
  Completer<void>? holdFollowed;

  /// Tokens Twitch refuses, without the `oauth:` prefix: `/oauth2/validate`
  /// and every Helix endpoint answer 401. Every other token is valid, with
  /// the followed-list scope, minted by [validClientId].
  final Set<String> revokedTokens = <String>{};

  /// The account each token belongs to; 'viewer' for any not listed.
  final Map<String, String> tokenLogins = <String, String>{};

  /// When set, `/oauth2/validate` waits for it before answering.
  Completer<void>? holdValidate;

  /// When set, helix/users waits for it before answering.
  Completer<void>? holdUsers;

  /// The Client ID `/oauth2/validate` says a valid token was minted by:
  /// Twitch's public client, which is what a blank Client ID field sends.
  String validClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

  /// The token each `/oauth2/validate` probe carried, in order.
  List<String> get validatedTokens => [
        for (final r in to('/oauth2/validate'))
          (r.headers['Authorization'] ?? '').replaceFirst('OAuth ', ''),
      ];

  int _nextId = 1000;
  int _nextVideo = 1;

  /// Makes [login] exist, with a numeric id.
  String user(String login) => _ids.putIfAbsent(login, () => '${_nextId++}');

  /// Starts a broadcast on [login] at [at] (default: now). With [archive], the
  /// in-progress archive appears at the top of its videos, as on Twitch.
  void goLive(String login, {DateTime? at, bool archive = true, String title = 'live now'}) {
    final id = user(login);
    final startedAt = at ?? now;
    _streams[id] = {
      'id': 'stream-$id-${startedAt.millisecondsSinceEpoch}',
      'user_id': id,
      'user_login': login,
      'title': title,
      'game_name': 'Chess',
      'viewer_count': 42,
      'started_at': startedAt.toUtc().toIso8601String(),
    };
    if (archive) addVideo(login, publishedAt: startedAt, title: title, duration: '1m');
  }

  /// Ends [login]'s broadcast.
  void goOffline(String login) => _streams.remove(user(login));

  /// Publishes a VOD at the top of [login]'s archive. Returns its id.
  String addVideo(
    String login, {
    DateTime? publishedAt,
    String? title,
    String duration = '1h0m0s',
  }) {
    final videoId = 'v${_nextVideo++}';
    final at = publishedAt ?? now;
    (_videos[user(login)] ??= <Map<String, dynamic>>[]).insert(0, {
      'id': videoId,
      'title': title ?? 'VOD $videoId',
      'duration': duration,
      'thumbnail_url': 'https://img/$videoId-%{width}x%{height}.jpg',
      'view_count': 7,
      'published_at': at.toUtc().toIso8601String(),
    });
    return videoId;
  }

  /// Edits a VOD in place, as Twitch does while a broadcast is still running.
  void updateVideo(String login, String videoId, {String? duration, String? title}) {
    final entry = _videos[user(login)]!.firstWhere((v) => v['id'] == videoId);
    if (duration != null) entry['duration'] = duration;
    if (title != null) entry['title'] = title;
  }

  void deleteVideo(String login, String videoId) =>
      _videos[user(login)]!.removeWhere((v) => v['id'] == videoId);

  /// [count] older VODs at once, oldest last, an hour apart.
  void backfill(String login, int count) {
    for (var i = 0; i < count; i++) {
      final list = _videos[user(login)] ??= <Map<String, dynamic>>[];
      final oldest = list.isEmpty
          ? now
          : DateTime.parse(list.last['published_at'] as String);
      final videoId = 'v${_nextVideo++}';
      list.add({
        'id': videoId,
        'title': 'VOD $videoId',
        'duration': '1h0m0s',
        'thumbnail_url': '',
        'view_count': 1,
        'published_at':
            oldest.subtract(const Duration(hours: 1)).toUtc().toIso8601String(),
      });
    }
  }

  List<http.Request> to(String path) =>
      requests.where((r) => r.url.path == path).toList();

  late final http.Client client = MockClient(_handle);

  /// A service wired to this fake, with its own auth notifier and clock.
  TwitchApiService service({TwitchAuth? auth}) =>
      TwitchApiService(client: client, auth: auth ?? TwitchAuth(), clock: () => now);

  static final AppSettings settings =
      AppSettings(twitchOauthToken: 'oauth:account-token');

  /// A favourite as the config would load it: a name and nothing else.
  static TwitchChannel channel(String login) => TwitchChannel(username: login);

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    final query = request.url.queryParametersAll;
    final bearer =
        (request.headers['Authorization'] ?? '').replaceFirst('Bearer ', '');
    if (path.startsWith('/helix/') && revokedTokens.contains(bearer)) {
      return _json({'error': 'Unauthorized', 'status': 401}, status: 401);
    }
    switch (path) {
      case '/oauth2/validate':
        if (holdValidate != null) await holdValidate!.future;
        final token =
            (request.headers['Authorization'] ?? '').replaceFirst('OAuth ', '');
        if (revokedTokens.contains(token)) {
          return _json({'status': 401, 'message': 'invalid access token'},
              status: 401);
        }
        return _json({
          'client_id': validClientId,
          'login': tokenLogins[token] ?? 'viewer',
          'user_id': '999',
          'scopes': ['user:read:follows'],
          'expires_in': 5000000,
        });
      case '/helix/users':
        if (holdUsers != null) await holdUsers!.future;
        final ids = query['id'] ?? const <String>[];
        final logins = query['login'] ?? const <String>[];
        if (ids.isEmpty && logins.isEmpty) {
          // The token's own account.
          return _json({
            'data': [
              {'id': '999', 'login': 'viewer', 'profile_image_url': 'https://img/viewer.png'},
            ],
          });
        }
        final data = <Map<String, dynamic>>[];
        _ids.forEach((login, id) {
          if (ids.contains(id) || logins.contains(login)) {
            data.add({'id': id, 'login': login, 'profile_image_url': 'https://img/$login.png'});
          }
        });
        return _json({'data': data});
      case '/helix/streams':
        if (holdStreams != null) await holdStreams!.future;
        if (rateLimitStreams) {
          return _json(
            {'error': 'Too Many Requests'},
            status: 429,
            headers: {'retry-after': '30'},
          );
        }
        final wanted = query['user_id'] ?? const <String>[];
        return _json({
          'data': [
            for (final id in wanted)
              if (_streams[id] != null) _streams[id],
          ],
        });
      case '/helix/channels/followers':
        return _json({'total': 1234});
      case '/helix/channels/followed':
        if (holdFollowed != null) await holdFollowed!.future;
        return _json({
          'data': [
            for (final login in followed)
              {'broadcaster_login': login, 'broadcaster_id': user(login), 'game_name': 'Chess'},
          ],
          'pagination': <String, dynamic>{},
        });
      case '/helix/videos':
        if (holdVideos != null) await holdVideos!.future;
        if (failVideos) return _json({'error': 'oops'}, status: 500);
        return _videosPage(request.url.queryParameters);
      case '/gql':
        // Chapter (games) lookups; watch progress needs a browser token, and
        // the tests have none.
        return _json({
          'data': {
            'video': {
              'moments': {
                'edges': [
                  {
                    'node': {
                      'details': {
                        'game': {'displayName': 'Chess'},
                      },
                    },
                  },
                ],
              },
            },
          },
        });
    }
    return _json({'error': 'unexpected $path'}, status: 404);
  }

  http.Response _videosPage(Map<String, String> params) {
    final all = _videos[params['user_id']] ?? const <Map<String, dynamic>>[];
    final size = int.parse(params['first'] ?? '20');
    final start = int.tryParse(params['after'] ?? '') ?? 0;
    final end = start + size > all.length ? all.length : start + size;
    final page = start >= all.length ? const <Map<String, dynamic>>[] : all.sublist(start, end);
    return _json({
      'data': page,
      'pagination': end < all.length ? {'cursor': '$end'} : <String, dynamic>{},
    });
  }

  static http.Response _json(
    Object body, {
    int status = 200,
    Map<String, String> headers = const {},
  }) =>
      http.Response(json.encode(body), status,
          headers: {'content-type': 'application/json', ...headers});
}

/// Waits for every pending microtask and zero-delay timer, so a chain of
/// awaits against the fake client settles.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

List<String> idsOf(List<TwitchVideo> vods) => [for (final v in vods) v.id];
