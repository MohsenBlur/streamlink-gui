import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/state/vod_merge.dart';

/// The merge that lets the open channel's VOD grid refresh in place.
///
/// The grid was only ever fetched on selection, so the user's report - "a
/// new VOD does not show up unless I click another channel and back" - was
/// the design. Refreshing has to keep what the user built up on screen: the
/// pages loaded with Load more and the cursor that continues them.
final DateTime t0 = DateTime.utc(2026, 10, 28, 12);

TwitchVideo vod(
  String id, {
  required int hoursAgo,
  String? title,
  String duration = '1h0m0s',
  List<String> games = const [],
  int? position,
}) =>
    TwitchVideo(
      id: id,
      title: title ?? 'VOD $id',
      duration: duration,
      thumbnailUrl: 'https://img/$id.jpg',
      viewCount: '1',
      publishedAt: t0.subtract(Duration(hours: hoursAgo)),
      games: games,
      watchPosition: position,
    );

List<String> ids(List<TwitchVideo> vods) => [for (final v in vods) v.id];

void main() {
  group('mergeFirstPage', () {
    test('a new VOD appears at the top', () {
      final current = [vod('b', hoursAgo: 5), vod('a', hoursAgo: 9)];
      final fresh = [vod('c', hoursAgo: 1), vod('b', hoursAgo: 5), vod('a', hoursAgo: 9)];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: null,
        hasLoadedMore: false,
        fresh: fresh,
        freshCursor: null,
      );

      expect(ids(merged.vods), ['c', 'b', 'a']);
      expect(ids(merged.added), ['c']);
      expect(merged.changed, isTrue);
    });

    test('a VOD already shown takes its new duration, title and thumbnail', () {
      // An in-progress broadcast's archive grows while the channel is open;
      // the grid used to keep the duration it had when the channel was picked.
      final current = [vod('a', hoursAgo: 1, duration: '10m0s', title: 'Live!')];
      final fresh = [vod('a', hoursAgo: 1, duration: '2h4m0s', title: 'Ranked grind')];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: null,
        hasLoadedMore: false,
        fresh: fresh,
        freshCursor: null,
      );

      expect(merged.vods.single.duration, '2h4m0s');
      expect(merged.vods.single.title, 'Ranked grind');
      expect(merged.added, isEmpty);
      expect(merged.changed, isTrue);
    });

    test('pages loaded with Load more stay, and so does their cursor', () {
      // Page one is 2 long here; the user has loaded page two as well.
      final current = [
        vod('d', hoursAgo: 2),
        vod('c', hoursAgo: 4),
        vod('b', hoursAgo: 6),
        vod('a', hoursAgo: 8),
      ];
      final fresh = [vod('e', hoursAgo: 0), vod('d', hoursAgo: 2)];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: 'after-a',
        hasLoadedMore: true,
        fresh: fresh,
        freshCursor: 'after-d',
      );

      // c was pushed off page one by e; it still exists and stays.
      expect(ids(merged.vods), ['e', 'd', 'c', 'b', 'a']);
      expect(merged.cursor, 'after-a',
          reason: 'the cursor continues after the last loaded page');
    });

    test('with only the first page on screen, the fresh cursor takes over', () {
      final current = [vod('b', hoursAgo: 2), vod('a', hoursAgo: 4)];
      final fresh = [vod('c', hoursAgo: 0), vod('b', hoursAgo: 2)];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: 'after-a',
        hasLoadedMore: false,
        fresh: fresh,
        freshCursor: 'after-b',
      );

      // a moved to page two, which Load more now fetches from after-b.
      expect(ids(merged.vods), ['c', 'b']);
      expect(merged.cursor, 'after-b');
    });

    test('a VOD deleted on Twitch goes, one merely pushed down stays', () {
      final current = [
        vod('c', hoursAgo: 2),
        vod('b', hoursAgo: 4),
        vod('a', hoursAgo: 6),
        vod('z', hoursAgo: 30),
      ];
      // b was deleted: it is newer than the oldest fresh entry, so the fresh
      // page would have held it.
      final fresh = [vod('c', hoursAgo: 2), vod('a', hoursAgo: 6)];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: 'after-z',
        hasLoadedMore: true,
        fresh: fresh,
        freshCursor: 'after-a',
      );

      expect(ids(merged.vods), ['c', 'a', 'z']);
    });

    test('a first page with no cursor is the whole archive', () {
      final current = [vod('b', hoursAgo: 2), vod('a', hoursAgo: 4)];
      final fresh = [vod('b', hoursAgo: 2)];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: 'after-a',
        hasLoadedMore: true,
        fresh: fresh,
        freshCursor: null,
      );

      expect(ids(merged.vods), ['b']);
      expect(merged.cursor, isNull);
    });

    test('what the fresh entry lacks is carried over', () {
      // The auto-download pass fetches without the per-VOD game lookup, and
      // its list must not strip the games off cards that had them.
      final current = [vod('a', hoursAgo: 1, games: ['Chess'], position: 600)];
      final fresh = [vod('a', hoursAgo: 1)];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: null,
        hasLoadedMore: false,
        fresh: fresh,
        freshCursor: null,
      );

      expect(merged.vods.single.games, ['Chess']);
      expect(merged.vods.single.watchPosition, 600);
      expect(merged.changed, isFalse);
    });

    test('an identical page changes nothing', () {
      final current = [vod('b', hoursAgo: 2), vod('a', hoursAgo: 4)];
      final fresh = [vod('b', hoursAgo: 2), vod('a', hoursAgo: 4)];

      final merged = mergeFirstPage(
        current: current,
        currentCursor: 'x',
        hasLoadedMore: false,
        fresh: fresh,
        freshCursor: 'x',
      );

      expect(merged.changed, isFalse);
      expect(merged.added, isEmpty);
    });

    test('a duplicated id in the fresh page is shown once', () {
      final merged = mergeFirstPage(
        current: const [],
        currentCursor: null,
        hasLoadedMore: false,
        fresh: [vod('a', hoursAgo: 1), vod('a', hoursAgo: 1)],
        freshCursor: null,
      );
      expect(ids(merged.vods), ['a']);
    });
  });

  group('appendVodPage', () {
    test('an entry repeated across a page boundary is not shown twice', () {
      // A VOD published between two Load-more requests shifts every later
      // page by one.
      final current = [vod('c', hoursAgo: 1), vod('b', hoursAgo: 2)];
      final page = [vod('b', hoursAgo: 2), vod('a', hoursAgo: 3)];
      expect(ids(appendVodPage(current, page)), ['c', 'b', 'a']);
    });
  });

  group('NewVodDetector', () {
    test('the first page seen for a channel is a baseline', () {
      final detector = NewVodDetector();
      final fresh = detector.observe(
        'shroud',
        [vod('b', hoursAgo: 2), vod('a', hoursAgo: 9)],
        isLive: false,
      );
      expect(fresh, isEmpty, reason: 'opening the app is not news');
      expect(detector.knows('Shroud'), isTrue);
    });

    test('a VOD published after the baseline is new, once', () {
      final detector = NewVodDetector()
        ..observe('shroud', [vod('a', hoursAgo: 9)], isLive: false);

      final first = detector.observe(
          'shroud', [vod('b', hoursAgo: 1), vod('a', hoursAgo: 9)],
          isLive: false);
      final again = detector.observe(
          'shroud', [vod('b', hoursAgo: 1), vod('a', hoursAgo: 9)],
          isLive: false);

      expect(ids(first), ['b']);
      expect(again, isEmpty);
    });

    test('the broadcast in progress counts once it has ended', () {
      // Twitch creates the archive when the stream starts. While it runs it
      // is the went-live toast's business; once the stream ends it is a VOD.
      final start = t0.subtract(const Duration(hours: 2));
      final detector = NewVodDetector()
        ..observe('shroud', [vod('a', hoursAgo: 30)], isLive: false);

      final whileLive = detector.observe(
        'shroud',
        [vod('live', hoursAgo: 2), vod('a', hoursAgo: 30)],
        isLive: true,
        liveSince: start,
      );
      final afterEnd = detector.observe(
        'shroud',
        [vod('live', hoursAgo: 2), vod('a', hoursAgo: 30)],
        isLive: false,
      );

      expect(whileLive, isEmpty);
      expect(ids(afterEnd), ['live']);
    });

    test('a baseline taken mid-broadcast leaves the live archive out of it', () {
      final start = t0.subtract(const Duration(hours: 1));
      final detector = NewVodDetector()
        ..observe('shroud', [vod('live', hoursAgo: 1), vod('a', hoursAgo: 30)],
            isLive: true, liveSince: start);

      final afterEnd = detector.observe(
          'shroud', [vod('live', hoursAgo: 1), vod('a', hoursAgo: 30)],
          isLive: false);

      expect(ids(afterEnd), ['live']);
    });

    test('a broadcast that ended is found even with no baseline', () {
      // A favourite whose list was never fetched this session (only the
      // first ten are prefetched) is first looked at when its stream ends.
      final start = t0.subtract(const Duration(hours: 3));
      final detector = NewVodDetector();

      final fresh = detector.observe(
        'shroud',
        [vod('ended', hoursAgo: 3), vod('older', hoursAgo: 30)],
        isLive: false,
        endedBroadcastStart: start,
      );

      expect(ids(fresh), ['ended']);
    });

    test('an old VOD pulled into the first page by a deletion is not new', () {
      final detector = NewVodDetector()
        ..observe('shroud', [vod('c', hoursAgo: 1), vod('b', hoursAgo: 5)],
            isLive: false);

      // c deleted; a, from page two, slides up into page one.
      final fresh = detector.observe(
          'shroud', [vod('b', hoursAgo: 5), vod('a', hoursAgo: 9)],
          isLive: false);

      expect(fresh, isEmpty);
    });

    test('channels are tracked separately and by login, whatever the case', () {
      final detector = NewVodDetector()
        ..observe('Shroud', [vod('a', hoursAgo: 9)], isLive: false);
      expect(detector.knows('shroud'), isTrue);
      expect(detector.knows('summit1g'), isFalse);

      detector.forget('SHROUD');
      expect(detector.knows('shroud'), isFalse);
    });
  });
}
