/// Whether [login] can be a Twitch login name: 1-25 letters, digits and
/// underscores.
///
/// Checked before a name goes anywhere near a URL. Names were interpolated
/// raw, so adding "foo&login=bar" as a favourite sent a two-user query and
/// silently bound whichever account came back first to the typed name, and
/// "foo bar" produced a malformed request instead of a clear "that is not a
/// username".
bool isValidTwitchLogin(String login) => _twitchLoginPattern.hasMatch(login);

final RegExp _twitchLoginPattern = RegExp(r'^[A-Za-z0-9_]{1,25}$');

/// Whether [id] is shaped like a Twitch user id: a decimal string.
///
/// DecAPI answers many errors with status 200 and plain text, and that text
/// used to be stored as the channel id, persisted, and reused by every later
/// Helix call - which then failed with a 400 on every poll, forever.
bool isValidTwitchUserId(String? id) =>
    id != null && _twitchUserIdPattern.hasMatch(id);

final RegExp _twitchUserIdPattern = RegExp(r'^\d{1,20}$');

class TwitchChannel {
  final String username;
  String? id;
  String? avatarUrl;
  String? followerCount;
  bool isLive = false;

  /// Helix `stream.id`: stable for the whole broadcast and different for the
  /// next one. Used to recognise a distinct live session, so "auto-play once
  /// per session" cannot re-trigger while a stream is still running.
  /// Null when offline or when running unauthenticated (DecAPI has no equivalent).
  String? streamId;

  String? uptime;
  String? viewerCount;
  String? game;
  String? streamTitle;
  bool isLoading = false;
  String? errorMessage;

  /// Consecutive failed refreshes. A live channel is only treated as offline
  /// once several in a row fail, so one flaky request cannot fake a go-offline
  /// (and then a go-live) event.
  int consecutiveFailures = 0;
  DateTime? lastUpdated;
  DateTime? wentLiveTime;

  bool autoPlayLive;
  int autoPlayPriority;
  bool autoDownloadVods;
  int maxVodKeepCount;
  bool stopAtLastWatchedVod;
  bool autoDownloadFastDownload;

  TwitchChannel({
    required this.username,
    this.id,
    this.avatarUrl,
    this.autoPlayLive = false,
    this.autoPlayPriority = 0,
    this.autoDownloadVods = false,
    this.maxVodKeepCount = 1,
    this.stopAtLastWatchedVod = true,
    this.autoDownloadFastDownload = false,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        // Persisted so the app does not have to re-resolve every channel's id
        // and avatar through the Twitch API on every single launch.
        'id': id,
        'avatarUrl': avatarUrl,
        'autoPlayLive': autoPlayLive,
        'autoPlayPriority': autoPlayPriority,
        'autoDownloadVods': autoDownloadVods,
        'maxVodKeepCount': maxVodKeepCount,
        'stopAtLastWatchedVod': stopAtLastWatchedVod,
        'autoDownloadFastDownload': autoDownloadFastDownload,
      };

  factory TwitchChannel.fromJson(Map<String, dynamic> json) => TwitchChannel(
        username: (json['username'] as String).toLowerCase().trim(),
        id: _persistedUserId(json['id']),
        avatarUrl: json['avatarUrl'] as String?,
        autoPlayLive: json['autoPlayLive'] as bool? ?? false,
        autoPlayPriority: json['autoPlayPriority'] as int? ?? 0,
        autoDownloadVods: json['autoDownloadVods'] as bool? ?? false,
        maxVodKeepCount: json['maxVodKeepCount'] as int? ?? 1,
        stopAtLastWatchedVod: json['stopAtLastWatchedVod'] as bool? ?? true,
        autoDownloadFastDownload: json['autoDownloadFastDownload'] as bool? ?? false,
      );

  /// A stored id, or null when it is not one.
  ///
  /// Null rather than kept, so a config already carrying a DecAPI error
  /// string as an id heals on the next launch: a missing id is re-resolved,
  /// a wrong one was trusted forever. A bare number is accepted too, since a
  /// hand-edited config should not lose the whole channel to a type check.
  static String? _persistedUserId(Object? raw) {
    final text = raw is int ? raw.toString() : (raw is String ? raw.trim() : null);
    return isValidTwitchUserId(text) ? text : null;
  }

  /// Lenient parser for persisted entries.
  ///
  /// Returns null instead of throwing when an entry is unusable. The config
  /// loader has no per-item error handling, so one malformed channel used to
  /// abort the whole load and leave the list empty - which the next autosave
  /// then wrote back over the user's real channel list.
  ///
  /// Also accepts a bare string, which is how very old configs stored channels.
  static TwitchChannel? tryFromJson(dynamic raw) {
    try {
      if (raw is String) {
        final username = raw.toLowerCase().trim();
        return username.isEmpty ? null : TwitchChannel(username: username);
      }
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        final username = map['username'];
        if (username is! String || username.trim().isEmpty) return null;
        return TwitchChannel.fromJson(map);
      }
    } catch (_) {}
    return null;
  }
}
