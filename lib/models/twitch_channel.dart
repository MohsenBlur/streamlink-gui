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

  TwitchChannel({required this.username});

  Map<String, dynamic> toJson() => {'username': username};
  factory TwitchChannel.fromJson(Map<String, dynamic> json) =>
      TwitchChannel(username: json['username'] as String);
}
