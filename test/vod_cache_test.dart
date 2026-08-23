import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/state/vod_cache.dart';

TwitchVideo vod(String id) => TwitchVideo(
      id: id,
      title: 'VOD $id',
      duration: '1h',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('VodCache', () {
    test('an unvisited channel reads as null, not as empty', () {
      // The distinction drives the spinner: null means "never fetched", an
      // empty list means "fetched, and this channel has no past broadcasts".
      final cache = VodCache();
      expect(cache.read('shroud'), isNull);
      expect(cache.has('shroud'), isFalse);

      cache.store('shroud', const []);
      expect(cache.read('shroud'), isEmpty);
      expect(cache.has('shroud'), isTrue);
    });

    test('clearing the list you were handed does not empty the cache', () {
      // Regression: the cache handed out its own List, so the channel-switch
      // `_channelVods.clear()` emptied the entry in place and every channel
      // visited once was permanently cached as having no VODs.
      final cache = VodCache()..store('shroud', [vod('1'), vod('2')]);

      final handed = cache.read('shroud')!;
      handed.clear();

      expect(cache.read('shroud'), hasLength(2));
    });

    test('growing the list you were handed does not grow the cache', () {
      // The pagination path appends to the live list.
      final cache = VodCache()..store('shroud', [vod('1')]);

      cache.read('shroud')!.add(vod('2'));

      expect(cache.read('shroud'), hasLength(1));
    });

    test('mutating the list you stored does not reach into the cache', () {
      final source = [vod('1')];
      final cache = VodCache()..store('shroud', source);

      source.clear();

      expect(cache.read('shroud'), hasLength(1));
    });

    test('two reads are independent of each other', () {
      final cache = VodCache()..store('shroud', [vod('1')]);
      final a = cache.read('shroud')!;
      final b = cache.read('shroud')!;

      a.clear();

      expect(b, hasLength(1));
    });

    test('lookups ignore login case and stray whitespace', () {
      // Channels arrive from the API, the followed list and hand-typed input,
      // which disagree about case.
      final cache = VodCache()..store('Shroud', [vod('1')]);
      expect(cache.has('shroud'), isTrue);
      expect(cache.read('  SHROUD '), hasLength(1));

      cache.store('shroud', [vod('1'), vod('2')]);
      expect(cache.length, 1);
    });

    test('remove and clear drop entries', () {
      final cache = VodCache()
        ..store('a', [vod('1')])
        ..store('b', [vod('2')]);

      cache.remove('a');
      expect(cache.has('a'), isFalse);
      expect(cache.length, 1);

      cache.clear();
      expect(cache.length, 0);
    });
  });
}
