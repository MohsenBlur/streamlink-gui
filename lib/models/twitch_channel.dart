class TwitchChannel {
  final String username;
  String? id;
  String? avatarUrl;
  String? followerCount;
  bool isLive = false;
  String? uptime;
  String? viewerCount;
  String? game;
  String? streamTitle;
  bool isLoading = false;
  String? errorMessage;
  DateTime? lastUpdated;
  DateTime? wentLiveTime;

  bool autoPlayLive;
  int autoPlayPriority;
  bool autoDownloadVods;
  int maxVodKeepCount;
  bool stopAtLastWatchedVod;

  TwitchChannel({
    required this.username,
    this.autoPlayLive = false,
    this.autoPlayPriority = 0,
    this.autoDownloadVods = false,
    this.maxVodKeepCount = 1,
    this.stopAtLastWatchedVod = true,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'autoPlayLive': autoPlayLive,
        'autoPlayPriority': autoPlayPriority,
        'autoDownloadVods': autoDownloadVods,
        'maxVodKeepCount': maxVodKeepCount,
        'stopAtLastWatchedVod': stopAtLastWatchedVod,
      };

  factory TwitchChannel.fromJson(Map<String, dynamic> json) => TwitchChannel(
        username: json['username'] as String,
        autoPlayLive: json['autoPlayLive'] as bool? ?? false,
        autoPlayPriority: json['autoPlayPriority'] as int? ?? 0,
        autoDownloadVods: json['autoDownloadVods'] as bool? ?? false,
        maxVodKeepCount: json['maxVodKeepCount'] as int? ?? 1,
        stopAtLastWatchedVod: json['stopAtLastWatchedVod'] as bool? ?? true,
      );
}
