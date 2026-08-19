import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/state/channel_search.dart';

TwitchChannel ch(String name, {bool live = false}) {
  final c = TwitchChannel(username: name);
  c.isLive = live;
  return c;
}

void main() {
  final channels = [
    ch('alpha', live: true),
    ch('alphabet'),
    ch('beta_alpha'),
    ch('gamma', live: true),
  ];

  group('filterChannels', () {
    test('blank query returns the input unchanged', () {
      expect(filterChannels(channels, ''), same(channels));
      expect(filterChannels(channels, '   '), same(channels));
    });

    test('case-insensitive substring match, order preserved', () {
      final result = filterChannels(channels, 'ALPHA');
      expect(result.map((c) => c.username),
          ['alpha', 'alphabet', 'beta_alpha']);
    });

    test('trims the query', () {
      expect(filterChannels(channels, '  gamma '), hasLength(1));
    });

    test('no match yields empty', () {
      expect(filterChannels(channels, 'zzz'), isEmpty);
    });
  });

  group('findBestMatch', () {
    test('exact beats prefix beats substring', () {
      expect(findBestMatch(channels, 'alpha')!.username, 'alpha');
      expect(findBestMatch(channels, 'alphab')!.username, 'alphabet');
      expect(findBestMatch(channels, 'a_alp')!.username, 'beta_alpha');
    });

    test('live beats offline within the same rank', () {
      final list = [ch('streamer_a'), ch('streamer_b', live: true)];
      expect(findBestMatch(list, 'streamer')!.username, 'streamer_b');
    });

    test('an offline exact match still beats a live prefix match', () {
      final list = [ch('cat'), ch('cats_live', live: true)];
      expect(findBestMatch(list, 'cat')!.username, 'cat');
    });

    test('null for blank or unmatched queries', () {
      expect(findBestMatch(channels, ''), isNull);
      expect(findBestMatch(channels, 'zzz'), isNull);
    });
  });

  group('resolveSearchSubmit', () {
    test('blank query does nothing on every tab', () {
      for (final tab in [0, 1, 2]) {
        expect(
          resolveSearchSubmit(tab: tab, query: '  ', visible: channels).type,
          SubmitActionType.none,
        );
      }
    });

    test('live match launches, offline match selects', () {
      final live = resolveSearchSubmit(tab: 1, query: 'gamma', visible: channels);
      expect(live.type, SubmitActionType.launchLive);
      expect(live.channel!.username, 'gamma');

      final offline =
          resolveSearchSubmit(tab: 1, query: 'alphabet', visible: channels);
      expect(offline.type, SubmitActionType.selectOnly);
      expect(offline.channel!.username, 'alphabet');
    });

    test('Favorites falls back to addFavorite when nothing matches', () {
      final action =
          resolveSearchSubmit(tab: 0, query: 'newstreamer', visible: channels);
      expect(action.type, SubmitActionType.addFavorite);
      expect(action.query, 'newstreamer');
    });

    test('Followed and Live NEVER add on an unmatched query', () {
      // Regression: Enter on those tabs used to silently add a favorite.
      for (final tab in [1, 2]) {
        final action =
            resolveSearchSubmit(tab: tab, query: 'newstreamer', visible: channels);
        expect(action.type, SubmitActionType.none,
            reason: 'tab $tab must not add favorites from search');
      }
    });

    test('a match on Favorites wins over the add fallback', () {
      final action =
          resolveSearchSubmit(tab: 0, query: 'alpha', visible: channels);
      expect(action.type, SubmitActionType.launchLive);
    });
  });
}
