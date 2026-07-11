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
          final userRes = await http.get(
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
        final streamRes = await http.get(
          Uri.parse('https://api.twitch.tv/helix/streams?user_id=${channel.id}'),
          headers: headers,
        );
        if (streamRes.statusCode == 200) {
          final streamData = json.decode(streamRes.body);
          if (streamData['data'] != null && streamData['data'].isNotEmpty) {
            final stream = streamData['data'][0];
            channel.isLive = true;
            channel.streamTitle = stream['title'] as String?;
            channel.game = stream['game_name'] as String?;
            channel.viewerCount = stream['viewer_count']?.toString() ?? '0';
            
            final startedAt = stream['started_at'] as String?;
            if (startedAt != null) {
              channel.uptime = _calculateUptime(startedAt);
            } else {
              channel.uptime = 'Live';
            }
          } else {
            channel.isLive = false;
            channel.uptime = 'Offline';
            channel.viewerCount = '0';
            channel.game = 'Offline';
            channel.streamTitle = 'No active broadcast';
          }
        } else {
          throw Exception('Helix Stream API error: status ${streamRes.statusCode}');
        }

        // 3. Fetch Follower count
        final followsRes = await http.get(
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
      } else {
        // Unauthenticated: Fallback to DecAPI
        // 1. Verify/Fetch User ID
        final idResponse = await http.get(Uri.parse('https://decapi.me/twitch/id/$username'));
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
          http.get(Uri.parse('https://decapi.me/twitch/avatar/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/uptime/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/followcount/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/viewercount/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/game/$username')),
          http.get(Uri.parse('https://decapi.me/twitch/title/$username')),
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
    } catch (e) {
      channel.errorMessage = e.toString().replaceFirst('Exception: ', '');
      channel.isLive = false;
      channel.uptime = 'Offline';
    } finally {
      channel.isLoading = false;
    }
  }

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

    final userRes = await http.get(
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

    final followsRes = await http.get(
      Uri.parse('https://api.twitch.tv/helix/channels/followed?user_id=$userId&first=100'),
      headers: headers,
    );

    if (followsRes.statusCode != 200) {
      throw Exception('Failed to get followed channels: ${followsRes.body}');
    }

    final followsData = json.decode(followsRes.body);
    final List<dynamic> data = followsData['data'] ?? [];

    final List<TwitchChannel> tempFollowed = [];
    for (var item in data) {
      final name = item['broadcaster_login'] as String;
      final channel = TwitchChannel(username: name.toLowerCase().trim());
      channel.id = item['broadcaster_id'] as String;
      channel.game = item['game_name'] as String?;
      tempFollowed.add(channel);
    }

    return FollowedChannelsResult(
      channels: tempFollowed,
      userLogin: userLogin,
      userAvatar: userAvatar,
    );
  }

  Future<VodsFetchResult> fetchVodsForChannel({
    required TwitchChannel channel,
    required AppSettings settings,
    required Map<String, int> localVodsProgress,
    String? afterCursor,
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
      final userRes = await http.get(
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
      final idResponse = await http.get(Uri.parse('https://decapi.me/twitch/id/${channel.username}'));
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

    final response = await http.get(Uri.parse(url), headers: headers);

    if (response.statusCode != 200) {
      throw Exception('Twitch API error: ${response.statusCode} - ${response.body}');
    }

    final data = json.decode(response.body);
    final List<dynamic> videosList = data['data'] ?? [];
    final nextCursor = data['pagination']?['cursor'];

    final newVods = videosList.map((item) => TwitchVideo.fromJson(item)).toList();
    bool isWebTokenExpired = false;

    // Fetch games and watch progress in parallel for each VOD using GQL queries
    await Future.wait(newVods.map((vod) async {
      // 1. Fetch games via persisted GQL query
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

        final gResponse = await http.post(
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
          }
        }
      } catch (_) {}

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

          final progressResponse = await http.post(
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

      if (localVodsProgress.containsKey(vod.id)) {
        final localPos = localVodsProgress[vod.id]!;
        vod.watchPosition = localPos;
        final totalSeconds = parseDurationToSeconds(vod.duration);
        if (totalSeconds > 0) {
          vod.watchProgress = localPos / totalSeconds;
        } else {
          vod.watchProgress = 0.0;
        }
      }
    }));

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

    final response = await http.post(
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
