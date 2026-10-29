import 'package:flutter/widgets.dart';

import '../models/twitch_video.dart';

/// What the open channel's grid is narrowed to, and what is picked in it:
/// the game filter, the search, selection mode and the selected VODs.
///
/// Moved out of the main screen as it was, with the setState closures the
/// dashboard's buttons were wired to. The dashboard reads it, and repaints
/// with it - not the whole screen, which is what each of those setStates
/// rebuilt.
class VodSelection extends ChangeNotifier {
  /// The search text, from the Display menu.
  final TextEditingController search = TextEditingController();

  /// The games the grid is narrowed to; none is every game.
  final Set<String> games = <String>{};

  /// The selected VODs' ids, in the order they were picked.
  final Set<String> picked = <String>{};

  bool _selecting = false;
  bool _disposed = false;

  /// Selection mode: the cards are checkboxes, and the selection bar
  /// replaces the toolbar.
  bool get isSelecting => _selecting;

  /// [vods] narrowed to [query] - in a title or a game name, in any case -
  /// and to any of [games].
  static List<TwitchVideo> filter(List<TwitchVideo> vods,
      {required String query, required Set<String> games}) {
    final q = query.trim().toLowerCase();
    return vods.where((vod) {
      final matchesSearch = q.isEmpty ||
          vod.title.toLowerCase().contains(q) ||
          vod.games.any((game) => game.toLowerCase().contains(q));
      final matchesGames =
          games.isEmpty || vod.games.any((game) => games.contains(game));
      return matchesSearch && matchesGames;
    }).toList();
  }

  /// The VODs of [vods] the grid shows, i.e. what "All" selects.
  List<TwitchVideo> shown(List<TwitchVideo> vods) =>
      filter(vods, query: search.text, games: games);

  /// The selected VODs, in the selection's order, and only those [vods]
  /// still holds: a selection can outlive a refresh.
  List<TwitchVideo> pickedOf(List<TwitchVideo> vods) => [
        for (final id in picked) ...vods.where((v) => v.id == id).take(1),
      ];

  /// The selected VODs in [vods]' own order, the grid's.
  List<TwitchVideo> pickedInOrderOf(List<TwitchVideo> vods) =>
      vods.where((v) => picked.contains(v.id)).toList();

  /// Into selection mode, with nothing selected.
  void enter() {
    _selecting = true;
    picked.clear();
    _notify();
  }

  /// Out of selection mode, with nothing selected.
  void end() {
    _selecting = false;
    picked.clear();
    _notify();
  }

  /// Selects [vodId], or no longer.
  void pick(String vodId, bool selected) {
    if (selected) {
      picked.add(vodId);
    } else {
      picked.remove(vodId);
    }
    _notify();
  }

  /// Adds every VOD of [vods] on show ([shown]) to the selection.
  void pickAllShown(List<TwitchVideo> vods) {
    picked.addAll(shown(vods).map((v) => v.id));
    _notify();
  }

  /// Nothing selected; selection mode stays.
  void clearPicked() {
    picked.clear();
    _notify();
  }

  /// Narrows the grid to [game] too, or no longer.
  void toggleGame(String game) {
    if (!games.remove(game)) games.add(game);
    _notify();
  }

  /// Every game again.
  void clearGames() {
    games.clear();
    _notify();
  }

  /// Another channel opened: its grid starts with every game and nothing
  /// selected. Selection mode and the search stay, as they always have.
  void channelChanged() {
    games.clear();
    picked.clear();
    _notify();
  }

  /// [change], made by the Display menu - to [search], [games] or how the
  /// cards show their games - and the dashboard's repaint for it.
  void update(VoidCallback change) {
    change();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    search.dispose();
    super.dispose();
  }
}
