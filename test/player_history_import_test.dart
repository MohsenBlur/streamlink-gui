import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/player_history_import.dart';

/// Matching a player's own history back onto VODs.
///
/// Every URL here is a real one lifted from MPC-HC's MediaHistory on a machine
/// that hit the bug. Synthetic URLs would only prove the pattern matches the
/// examples the pattern was written from.
void main() {
  group('reading identity out of a CDN url', () {
    test('a real limmy VOD url yields channel and broadcast time', () {
      final id = identifyCdnUrl(
          'https://dgeft87wbj63p.cloudfront.net/f589ea12f111f2824e39_limmy_316000806994_1789028629/1080p60/index-dvr.m3u8');
      expect(id, isNotNull);
      expect(id!.channel, 'limmy');
      // 1789028629 -> 2026-09-10, which matched the age the app showed.
      expect(id.startedAt.toUtc().year, 2026);
      expect(id.startedAt.toUtc().month, 9);
      expect(id.startedAt.toUtc().day, 10);
    });

    test('a channel containing digits and underscores survives', () {
      final id = identifyCdnUrl(
          'https://d2nvs31859zcd8.cloudfront.net/181885a3daeab98a1d85_mega64podcast_319007897815_1787871055/chunked/index-dvr.m3u8');
      expect(id!.channel, 'mega64podcast');
    });

    test('a muted-variant url still parses', () {
      final id = identifyCdnUrl(
          'https://dgeft87wbj63p.cloudfront.net/9004f5264750a8364b29_limmy_315997641042_1788942604/1080p60/index-muted-SMH4VDDJ30.m3u8');
      expect(id!.channel, 'limmy');
    });

    test('local files and unrelated media are ignored, not guessed at', () {
      for (final url in const [
        r'B:\TwitchVODs\limmy\Saturday craziness and fun - v2853608131.mp4',
        r'S:\s\something\else.mkv',
        'https://example.com/video.m3u8',
        '',
      ]) {
        expect(identifyCdnUrl(url), isNull, reason: url);
      }
    });
  });

  group('matching history to known VODs', () {
    final vods = [
      VodIdentity(
        id: '2870237439',
        channel: 'limmy',
        publishedAt: DateTime.utc(2026, 9, 10, 8, 23, 49),
        durationSeconds: 18876,
      ),
      VodIdentity(
        id: '2869387736',
        channel: 'limmy',
        publishedAt: DateTime.utc(2026, 9, 9, 8, 30, 4),
        durationSeconds: 18865,
      ),
    ];

    PlayerHistoryEntry entry(String url, int seconds) =>
        PlayerHistoryEntry(url: url, positionSeconds: seconds);

    test('a real entry lands on the right VOD', () {
      final got = matchHistoryToVods([
        entry(
            'https://dgeft87wbj63p.cloudfront.net/f589ea12f111f2824e39_limmy_316000806994_1789028629/1080p60/index-dvr.m3u8',
            9448),
      ], vods);
      expect(got, hasLength(1));
      expect(got.first.vodId, '2870237439');
      expect(got.first.seconds, 9448);
    });

    test('two broadcasts a day apart are not confused', () {
      final got = matchHistoryToVods([
        entry(
            'https://dgeft87wbj63p.cloudfront.net/9004f5264750a8364b29_limmy_315997641042_1788942604/1080p60/index-muted-SMH4VDDJ30.m3u8',
            10469),
      ], vods);
      expect(got.single.vodId, '2869387736');
    });

    test('an unknown channel is dropped rather than guessed', () {
      final got = matchHistoryToVods([
        entry(
            'https://d2nvs31859zcd8.cloudfront.net/181885a3daeab98a1d85_mega64podcast_319007897815_1787871055/chunked/index-dvr.m3u8',
            7256),
      ], vods);
      expect(got, isEmpty,
          reason: 'restoring onto the wrong VOD is worse than the loss');
    });

    test('a position past the VOD duration is refused', () {
      final got = matchHistoryToVods([
        entry(
            'https://dgeft87wbj63p.cloudfront.net/f589ea12f111f2824e39_limmy_316000806994_1789028629/1080p60/index-dvr.m3u8',
            99999),
      ], vods);
      expect(got, isEmpty);
    });

    test('a zero position carries no information and is skipped', () {
      final got = matchHistoryToVods([
        entry(
            'https://dgeft87wbj63p.cloudfront.net/f589ea12f111f2824e39_limmy_316000806994_1789028629/1080p60/index-dvr.m3u8',
            0),
      ], vods);
      expect(got, isEmpty);
    });

    test('an ambiguous match is dropped', () {
      // Two VODs from the same channel inside the match window should never
      // both be claimed by one history entry.
      final ambiguous = [
        vods.first,
        VodIdentity(
          id: 'duplicate',
          channel: 'limmy',
          publishedAt: DateTime.utc(2026, 9, 10, 8, 25, 0),
          durationSeconds: 18876,
        ),
      ];
      final got = matchHistoryToVods([
        entry(
            'https://dgeft87wbj63p.cloudfront.net/f589ea12f111f2824e39_limmy_316000806994_1789028629/1080p60/index-dvr.m3u8',
            9448),
      ], ambiguous);
      expect(got, isEmpty);
    });

    test('a mixed history keeps only what it can prove', () {
      final got = matchHistoryToVods([
        entry(r'B:\TwitchVODs\limmy\local file.mp4', 16800),
        entry(
            'https://dgeft87wbj63p.cloudfront.net/f589ea12f111f2824e39_limmy_316000806994_1789028629/1080p60/index-dvr.m3u8',
            9448),
        entry('https://example.com/whatever.m3u8', 500),
      ], vods);
      expect(got, hasLength(1));
      expect(got.single.vodId, '2870237439');
    });
  });
}
