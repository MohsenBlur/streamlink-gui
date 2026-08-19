class TwitchVideo {
  final String id;
  final String title;
  final String duration;
  final String thumbnailUrl;
  final String viewCount;
  final DateTime publishedAt;
  List<String> games = [];
  int? watchPosition;
  double? watchProgress;

  TwitchVideo({
    required this.id,
    required this.title,
    required this.duration,
    required this.thumbnailUrl,
    required this.viewCount,
    required this.publishedAt,
    this.games = const [],
    this.watchPosition,
    this.watchProgress,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'duration': duration,
        'thumbnail_url': thumbnailUrl,
        'view_count': int.tryParse(viewCount) ?? 0,
        'published_at': publishedAt.toIso8601String(),
        'games': games,
        'watch_position': watchPosition,
        'watch_progress': watchProgress,
      };

  factory TwitchVideo.fromJson(Map<String, dynamic> json) {
    final rawDuration = json['duration'] as String? ?? '0s';
    final rawViewCount = json['view_count'] as int? ?? 0;

    return TwitchVideo(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'No Title',
      duration: rawDuration,
      thumbnailUrl: json['thumbnail_url'] as String? ?? '',
      viewCount: rawViewCount.toString(),
      // A missing or malformed timestamp must not take down the whole load;
      // the epoch simply sorts such an entry last.
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      games: List<String>.from(json['games'] ?? const []),
      watchPosition: json['watch_position'] as int?,
      watchProgress: (json['watch_progress'] as num?)?.toDouble(),
    );
  }

  /// Lenient parser for persisted entries; returns null rather than throwing so
  /// one bad record cannot abort loading the rest.
  static TwitchVideo? tryFromJson(dynamic raw) {
    try {
      if (raw is Map) {
        final map = Map<String, dynamic>.from(raw);
        if (map['id'] is! String || (map['id'] as String).isEmpty) return null;
        return TwitchVideo.fromJson(map);
      }
    } catch (_) {}
    return null;
  }
}
