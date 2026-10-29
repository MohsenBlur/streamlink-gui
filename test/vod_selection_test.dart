import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/state/vod_selection.dart';

/// The open channel's game filter, search and selection. Through the
/// screen, main_screen_vods_test's 'narrowing and selecting'; these are the
/// rules on their own.
void main() {
  TwitchVideo vod(String id, String title, List<String> games) => TwitchVideo(
        id: id,
        title: title,
        duration: '1h0m0s',
        thumbnailUrl: '',
        viewCount: '0',
        publishedAt: DateTime(2026),
        games: games,
      );

  final vods = [
    vod('1', 'Opening prep', ['Chess']),
    vod('2', 'Any% run', ['Mario']),
    vod('3', 'Mixed night', ['Chess', 'Mario']),
  ];

  List<String> ids(List<TwitchVideo> list) => [for (final v in list) v.id];

  test('the search matches a title or a game, in any case, and a game '
      'filter keeps a VOD with any of its games', () {
    expect(ids(VodSelection.filter(vods, query: ' NIGHT ', games: {})), ['3']);
    expect(ids(VodSelection.filter(vods, query: 'mario', games: {})),
        ['2', '3']);
    expect(ids(VodSelection.filter(vods, query: '', games: {'Chess'})),
        ['1', '3']);
    expect(
        ids(VodSelection.filter(vods, query: 'run', games: {'Chess'})), isEmpty);
  });

  test('All adds what is on show; the selection keeps its own order, and '
      'only what the list still holds', () {
    final selection = VodSelection()..enter();
    addTearDown(selection.dispose);
    selection
      ..pick('3', true)
      ..toggleGame('Chess')
      ..pickAllShown(vods);
    expect(selection.picked, {'3', '1'});
    expect(ids(selection.pickedOf(vods)), ['3', '1']);
    expect(ids(selection.pickedInOrderOf(vods)), ['1', '3']);
    expect(ids(selection.pickedOf(vods.sublist(1))), ['3'],
        reason: 'a refresh dropped VOD 1');
  });

  test('another channel clears the games and the selection, not the mode '
      'or the search', () {
    final selection = VodSelection()..enter();
    addTearDown(selection.dispose);
    selection.search.text = 'night';
    selection
      ..toggleGame('Mario')
      ..pick('3', true);
    var notified = 0;
    selection.addListener(() => notified++);

    selection.channelChanged();
    expect(selection.games, isEmpty);
    expect(selection.picked, isEmpty);
    expect(selection.isSelecting, isTrue);
    expect(selection.search.text, 'night');
    expect(notified, 1);

    selection.end();
    expect(selection.isSelecting, isFalse);
  });

  test('ending a selection after the screen has gone does nothing', () {
    // A selection's download or delete ends it after awaits of its own.
    final selection = VodSelection()..enter();
    selection.dispose();
    expect(selection.end, returnsNormally);
  });
}
