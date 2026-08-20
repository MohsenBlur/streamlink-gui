/// Human-readable "how long ago" formatting.
///
/// Single home for the copies that previously lived in dashboard_header.dart
/// and twitch_video_card.dart.
String timeAgo(DateTime dateTime, {DateTime? now}) {
  final difference = (now ?? DateTime.now()).difference(dateTime);

  if (difference.inDays >= 365) {
    final years = (difference.inDays / 365).floor();
    return '$years year${years > 1 ? "s" : ""} ago';
  } else if (difference.inDays >= 30) {
    final months = (difference.inDays / 30).floor();
    return '$months month${months > 1 ? "s" : ""} ago';
  } else if (difference.inDays >= 7) {
    final weeks = (difference.inDays / 7).floor();
    return '$weeks week${weeks > 1 ? "s" : ""} ago';
  } else if (difference.inDays >= 1) {
    return '${difference.inDays} day${difference.inDays > 1 ? "s" : ""} ago';
  } else if (difference.inHours >= 1) {
    return '${difference.inHours} hour${difference.inHours > 1 ? "s" : ""} ago';
  } else if (difference.inMinutes >= 1) {
    return '${difference.inMinutes} minute${difference.inMinutes > 1 ? "s" : ""} ago';
  } else {
    return 'just now';
  }
}
