import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';

void main() {
  group('TwitchChannel.tryFromJson', () {
    test('parses a full entry', () {
      final channel = TwitchChannel.tryFromJson({
        'username': 'SomeStreamer',
        'id': '12345',
        'avatarUrl': 'https://example.invalid/a.png',
        'autoPlayLive': true,
        'autoPlayPriority': 3,
        'autoDownloadVods': true,
        'maxVodKeepCount': 4,
        'stopAtLastWatchedVod': false,
        'autoDownloadFastDownload': true,
      });

      expect(channel, isNotNull);
      expect(channel!.username, 'somestreamer', reason: 'usernames are normalised');
      expect(channel.id, '12345');
      expect(channel.avatarUrl, 'https://example.invalid/a.png');
      expect(channel.autoPlayLive, isTrue);
      expect(channel.autoPlayPriority, 3);
      expect(channel.maxVodKeepCount, 4);
      expect(channel.stopAtLastWatchedVod, isFalse);
      expect(channel.autoDownloadFastDownload, isTrue);
    });

    test('persists id and avatar so they are not re-resolved every launch', () {
      final channel = TwitchChannel(username: 'x', id: '99', avatarUrl: 'u');
      final restored = TwitchChannel.tryFromJson(channel.toJson());

      expect(restored!.id, '99');
      expect(restored.avatarUrl, 'u');
    });

    test('a stored id that is not a number is dropped so it is re-resolved', () {
      // Older builds saved DecAPI's 200-status error text as the id, and the
      // Helix path then sent it on every poll and got a 400 forever.
      final channel = TwitchChannel.tryFromJson({
        'username': 'streamer',
        'id': 'Error: User not found',
        'avatarUrl': 'https://example.invalid/a.png',
      });
      expect(channel, isNotNull, reason: 'the channel itself is kept');
      expect(channel!.id, isNull);
      expect(channel.avatarUrl, 'https://example.invalid/a.png');
    });

    test('a numeric id stored as a number is kept, not fatal', () {
      final channel =
          TwitchChannel.tryFromJson({'username': 'streamer', 'id': 12345});
      expect(channel, isNotNull);
      expect(channel!.id, '12345');
    });
  });

  group('Twitch identifiers', () {
    test('logins are letters, digits and underscores, up to 25', () {
      for (final ok in ['a', 'some_user', 'User123', 'x' * 25]) {
        expect(isValidTwitchLogin(ok), isTrue, reason: ok);
      }
      for (final bad in [
        '',
        'foo bar',
        'foo&login=bar',
        'a/b',
        'x' * 26,
        'émile',
        'twitch.tv/foo',
      ]) {
        expect(isValidTwitchLogin(bad), isFalse, reason: bad);
      }
    });

    test('user ids are decimal strings', () {
      expect(isValidTwitchUserId('123456789'), isTrue);
      for (final bad in [null, '', '12a', ' 12', 'Error: rate limited', '-5']) {
        expect(isValidTwitchUserId(bad), isFalse, reason: '$bad');
      }
    });

    test('returns null for unusable entries instead of throwing', () {
      // One malformed entry used to abort the entire config load, leaving the
      // channel list empty - which the next autosave then persisted.
      expect(TwitchChannel.tryFromJson(null), isNull);
      expect(TwitchChannel.tryFromJson({}), isNull);
      expect(TwitchChannel.tryFromJson({'username': null}), isNull);
      expect(TwitchChannel.tryFromJson({'username': 42}), isNull);
      expect(TwitchChannel.tryFromJson({'username': '   '}), isNull);
      expect(TwitchChannel.tryFromJson(7), isNull);
    });

    test('accepts the legacy bare-string form', () {
      final channel = TwitchChannel.tryFromJson('LegacyName');
      expect(channel, isNotNull);
      expect(channel!.username, 'legacyname');
    });

    test('survives wrongly-typed optional fields', () {
      // Hand-edited configs can hold the wrong type; the entry should be
      // dropped rather than taking the whole load down.
      expect(
        () => TwitchChannel.tryFromJson({'username': 'ok', 'autoPlayPriority': 'high'}),
        returnsNormally,
      );
    });

    test('a good entry still parses when a neighbouring one is broken', () {
      final raw = [
        {'username': 'good1'},
        {'nousername': true},
        'good2',
        null,
      ];
      final parsed = raw.map(TwitchChannel.tryFromJson).whereType<TwitchChannel>().toList();

      expect(parsed.map((c) => c.username), ['good1', 'good2']);
    });
  });

  group('TwitchVideo.tryFromJson', () {
    Map<String, dynamic> validVod() => {
          'id': '555',
          'title': 'A stream',
          'duration': '1h2m3s',
          'thumbnail_url': 'https://example.invalid/t.png',
          'view_count': 10,
          'published_at': '2026-01-02T03:04:05Z',
        };

    test('parses a valid entry', () {
      final vod = TwitchVideo.tryFromJson(validVod());
      expect(vod, isNotNull);
      expect(vod!.id, '555');
      expect(vod.title, 'A stream');
      expect(vod.publishedAt.year, 2026);
    });

    test('returns null when the id is missing or unusable', () {
      expect(TwitchVideo.tryFromJson(null), isNull);
      expect(TwitchVideo.tryFromJson({}), isNull);
      expect(TwitchVideo.tryFromJson({'id': ''}), isNull);
      expect(TwitchVideo.tryFromJson({'id': 123}), isNull);
    });

    test('falls back to the epoch for a malformed timestamp', () {
      final vod = TwitchVideo.tryFromJson(validVod()..['published_at'] = 'not-a-date');
      expect(vod, isNotNull);
      expect(vod!.publishedAt.millisecondsSinceEpoch, 0);
    });

    test('round-trips through toJson', () {
      final original = TwitchVideo.tryFromJson(validVod())!;
      final restored = TwitchVideo.tryFromJson(original.toJson())!;

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.duration, original.duration);
      expect(restored.publishedAt, original.publishedAt);
    });
  });
}
