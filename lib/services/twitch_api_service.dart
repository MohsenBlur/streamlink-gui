import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
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

class TwitchApiService {
  /// Every Twitch/DecAPI request goes through these wrappers.
  ///
  /// None of the calls in this file had a timeout: a request that never
  /// completes stalled the whole refresh, and because the favourites poll had
  /// no re-entrancy guard the stalled passes accumulated.
  static const Duration _requestTimeout = Duration(seconds: 12);

  Future<http.Response> _get(Uri url, {Map<String, String>? headers}) {
    return http.get(url, headers: headers).timeout(_requestTimeout);
  }

  Future<http.Response> _post(Uri url, {Map<String, String>? headers, Object? body}) {
    return http.post(url, headers: headers, body: body).timeout(_requestTimeout);
  }

  String _getRawOauthToken(String token) {
    String cleanToken = token.trim();
    if (cleanToken.startsWith('oauth:')) {
      cleanToken = cleanToken.substring(6);
    }
    return cleanToken;
  }

  String _calculateUptime(String startedAtStr) {
    try {
      final startedAt = DateTime.parse(startedAtStr);
      final diff = DateTime.now().toUtc().difference(startedAt);
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

  Future<void> fetchChannelStats(TwitchChannel channel, AppSettings settings) async {
    channel.isLoading = true;
    channel.errorMessage = null;

    final username = channel.username;
    final token = _getRawOauthToken(settings.twitchOauthToken);
    final clientId = settings.twitchClientId.trim().isNotEmpty
        ? settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    try {
      if (token.isNotEmpty) {
        // Authenticated: Use Helix API
        final headers = {
          'Client-Id': clientId,
          'Authorization': 'Bearer $token',
        };

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

      channel.lastUpdated = DateTime.now();
      channel.consecutiveFailures = 0;
    } catch (e) {
      channel.errorMessage = e.toString().replaceFirst('Exception: ', '');
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
    } finally {
      channel.isLoading = false;
    }
  }

  /// How many consecutive refresh failures before a live channel is treated as
  /// offline rather than temporarily unreachable.
  static const int _failuresBeforeOffline = 3;

  Future<FollowedChannelsResult> fetchFollowedChannels(AppSettings settings) async {
    final token = _getRawOauthToken(settings.twitchOauthToken);
    if (token.isEmpty) {
      throw Exception('OAuth token is empty');
    }

    final clientId = settings.twitchClientId.trim().isNotEmpty
        ? settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    final headers = {
      'Client-Id': clientId,
      'Authorization': 'Bearer $token',
    };

    final userRes = await _get(
      Uri.parse('https://api.twitch.tv/helix/users'),
      headers: headers,
    );

    if (userRes.statusCode != 200) {
      throw Exception('Failed to get user profile: ${userRes.body}');
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

      final followsRes = await _get(Uri.parse(url.toString()), headers: headers);
      if (followsRes.statusCode != 200) {
        // Keep whatever was already collected rather than losing every page to
        // a failure on the last one.
        if (tempFollowed.isNotEmpty) break;
        throw Exception('Failed to get followed channels: ${followsRes.body}');
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

    final clientId = settings.twitchClientId.trim().isNotEmpty
        ? settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    final headers = {
      'Client-Id': clientId,
      'Authorization': 'Bearer $token',
    };

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
      throw Exception('Twitch API error: ${response.statusCode} - ${response.body}');
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
          }
        } catch (_) {}
      }

      final localPos = localVodsProgress[vod.id];
      if (localPos != null && (vod.watchPosition == null || localPos > vod.watchPosition!)) {
        vod.watchPosition = localPos;
        final totalSeconds = parseDurationToSeconds(vod.duration);
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
      throw Exception('Unauthorized GQL web token');
    }
  }
}
