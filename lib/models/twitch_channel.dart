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
        id: json['id'] as String?,
        avatarUrl: json['avatarUrl'] as String?,
        autoPlayLive: json['autoPlayLive'] as bool? ?? false,
        autoPlayPriority: json['autoPlayPriority'] as int? ?? 0,
        autoDownloadVods: json['autoDownloadVods'] as bool? ?? false,
        maxVodKeepCount: json['maxVodKeepCount'] as int? ?? 1,
        stopAtLastWatchedVod: json['stopAtLastWatchedVod'] as bool? ?? true,
        autoDownloadFastDownload: json['autoDownloadFastDownload'] as bool? ?? false,
      );

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
