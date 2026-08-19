import '../models/twitch_channel.dart';

/// Pure logic behind the sidebar search box.
///
/// The field was previously labelled "Search or add username..." but never
/// filtered anything: the query only drove an "Add to Favorites" prompt on the
/// Favorites tab, and pressing Enter on the Followed or Live tabs silently
/// ADDED a stranger to Favorites. These functions define what search actually
/// does, and are pure so the behavior is directly testable.

/// Case-insensitive substring filter on the username. An empty or blank query
/// returns the input unchanged (same order).
List<TwitchChannel> filterChannels(List<TwitchChannel> channels, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return channels;
  return channels
      .where((c) => c.username.toLowerCase().contains(q))
      .toList();
}

/// Best match for a query: exact beats prefix beats substring; within a rank a
/// live channel beats an offline one; ties keep input order. Null when nothing
/// matches or the query is blank.
TwitchChannel? findBestMatch(List<TwitchChannel> channels, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return null;

  TwitchChannel? best;
  var bestScore = -1;

  for (final channel in channels) {
    final name = channel.username.toLowerCase();
    int score;
    if (name == q) {
      score = 4;
    } else if (name.startsWith(q)) {
      score = 2;
    } else if (name.contains(q)) {
      score = 0;
    } else {
      continue;
    }
    if (channel.isLive) score += 1;

    if (score > bestScore) {
      bestScore = score;
      best = channel;
    }
  }
  return best;
}

enum SubmitActionType {
  /// Nothing to do (blank query, or no match on a tab that cannot add).
  none,

  /// Offer/perform adding [SearchSubmitAction.query] as a new favorite.
  addFavorite,

  /// Launch [SearchSubmitAction.channel]'s live stream.
  launchLive,

  /// Select [SearchSubmitAction.channel] (it matched but is offline).
  selectOnly,
}

class SearchSubmitAction {
  const SearchSubmitAction(this.type, {this.channel, this.query = ''});

  final SubmitActionType type;
  final TwitchChannel? channel;
  final String query;
}

/// What pressing Enter in the search field should do.
///
/// Tab semantics: 0 = Favorites, 1 = Followed, 2 = Live.
/// - Favorites keeps its add-affordance: an unmatched query becomes an
///   add-favorite action (matching the visible "Add 'x'" prompt row).
/// - Followed and Live NEVER add — an unmatched query is a no-op. Enter there
///   previously added whatever was typed to Favorites with no visible prompt.
SearchSubmitAction resolveSearchSubmit({
  required int tab,
  required String query,
  required List<TwitchChannel> visible,
}) {
  final q = query.trim();
  if (q.isEmpty) return const SearchSubmitAction(SubmitActionType.none);

  final match = findBestMatch(visible, q);
  if (match != null) {
    return SearchSubmitAction(
      match.isLive ? SubmitActionType.launchLive : SubmitActionType.selectOnly,
      channel: match,
      query: q,
    );
  }

  if (tab == 0) {
    return SearchSubmitAction(SubmitActionType.addFavorite, query: q);
  }
  return SearchSubmitAction(SubmitActionType.none, query: q);
}
