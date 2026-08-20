import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/state/library_entries.dart';

TwitchVideo vid(String id, String title, {double? progress, DateTime? published}) {
  return TwitchVideo(
    id: id,
    title: title,
    duration: '1h2m3s',
    thumbnailUrl: '',
    viewCount: '10',
    publishedAt: published ?? DateTime(2026, 1, 1),
    watchProgress: progress,
  );
}

void main() {
  group('parseDownloadedVodFilename', () {
    test('parses title and id, with and without the v prefix', () {
      expect(parseDownloadedVodFilename('My Cool VOD - 12345.mp4'),
          (title: 'My Cool VOD', vodId: '12345'));
      expect(parseDownloadedVodFilename('My Cool VOD - v12345.mkv'),
          (title: 'My Cool VOD', vodId: '12345'));
    });

    test('title containing the separator keeps everything before the LAST id', () {
      expect(parseDownloadedVodFilename('A - B - 999.mp4'),
          (title: 'A - B', vodId: '999'));
    });

    test('rejects names without the convention', () {
      expect(parseDownloadedVodFilename('random-video.mp4'), isNull);
      expect(parseDownloadedVodFilename(' - 123.mp4'), isNull);
    });
  });

  group('channelFromDownloadPath', () {
    test('first segment under the download root', () {
      expect(
        channelFromDownloadPath(
            r'D:\vods\somechannel\Title - 1.mp4', r'D:\vods'),
        'somechannel',
      );
    });

    test('root match is case-insensitive and separator-agnostic', () {
      expect(
        channelFromDownloadPath('d:/VODS/Chan/file.mp4', r'D:\vods'),
        'Chan',
      );
    });

    test('file outside the root falls back to parent directory', () {
      expect(
        channelFromDownloadPath(r'E:\other\chan\file.mp4', r'D:\vods'),
        'chan',
      );
    });

    test('file directly in the root has no channel', () {
      expect(channelFromDownloadPath(r'D:\vods\file.mp4', r'D:\vods'), isNull);
    });
  });

  group('formatBytes', () {
    test('unit boundaries', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1048576), '1.0 MB');
      expect(formatBytes(3221225472), '3.0 GB');
    });

    test('three-digit values drop the decimal', () {
      expect(formatBytes(150 * 1024), '150 KB');
    });
  });

  group('buildLibraryEntries', () {
    final stats = <String, LibraryFileStat>{
      r'D:\vods\chan\Title A - 1.mp4': (
        size: 1000,
        modified: DateTime(2026, 3, 1)
      ),
      r'D:\vods\chan\Title B - 2.mp4': (
        size: 5000,
        modified: DateTime(2026, 2, 1)
      ),
    };
    LibraryFileStat? stat(String p) => stats[p];

    test('registry entries get file metadata, parsed title and channel', () {
      final entries = buildLibraryEntries(
        registry: {'1': r'D:\vods\chan\Title A - 1.mp4'},
        recents: [],
        localProgress: {},
        channelNames: {},
        downloadRoot: r'D:\vods',
        statFile: stat,
      );
      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.title, 'Title A');
      expect(e.channel, 'chan');
      expect(e.sizeBytes, 1000);
      expect(e.isDownloaded, isTrue);
    });

    test('missing files are dropped, like _checkDownloadedVods', () {
      final entries = buildLibraryEntries(
        registry: {'9': r'D:\vods\chan\Gone - 9.mp4'},
        recents: [],
        localProgress: {},
        channelNames: {},
        downloadRoot: r'D:\vods',
        statFile: stat,
      );
      expect(entries, isEmpty);
    });

    test('recents merge onto downloads; streamed-only rows appear separately', () {
      final entries = buildLibraryEntries(
        registry: {'1': r'D:\vods\chan\Title A - 1.mp4'},
        recents: [
          vid('1', 'Rich Title A', progress: 0.5),
          vid('7', 'Streamed Only', progress: 0.2),
        ],
        localProgress: {},
        channelNames: {'7': 'someone'},
        downloadRoot: r'D:\vods',
        statFile: stat,
      );
      expect(entries, hasLength(2));
      final downloaded = entries.singleWhere((e) => e.vodId == '1');
      expect(downloaded.title, 'Rich Title A'); // metadata wins over filename
      expect(downloaded.watchProgress, 0.5);
      expect(downloaded.video, isNotNull);
      final streamed = entries.singleWhere((e) => e.vodId == '7');
      expect(streamed.isDownloaded, isFalse);
      expect(streamed.channel, 'someone');
    });

    test('sorted newest-first by file mtime / publish date', () {
      final entries = buildLibraryEntries(
        registry: {
          '1': r'D:\vods\chan\Title A - 1.mp4', // mtime Mar 1
          '2': r'D:\vods\chan\Title B - 2.mp4', // mtime Feb 1
        },
        recents: [vid('7', 'Streamed', published: DateTime(2026, 2, 15))],
        localProgress: {},
        channelNames: {},
        downloadRoot: r'D:\vods',
        statFile: stat,
      );
      expect(entries.map((e) => e.vodId).toList(), ['1', '7', '2']);
    });
  });

  group('filterLibraryEntries', () {
    final entries = buildLibraryEntries(
      registry: {'1': r'D:\vods\chan\Title A - 1.mp4'},
      recents: [vid('7', 'Streamed Only')],
      localProgress: {},
      channelNames: {'7': 'someone'},
      downloadRoot: r'D:\vods',
      statFile: (p) => p.contains('Title A')
          ? (size: 1, modified: DateTime(2026, 1, 1))
          : null,
    );

    test('matches title, channel and id, case-insensitively', () {
      expect(filterLibraryEntries(entries, 'title a'), hasLength(1));
      expect(filterLibraryEntries(entries, 'SOMEONE'), hasLength(1));
      expect(filterLibraryEntries(entries, '7'), hasLength(1));
      expect(filterLibraryEntries(entries, 'zzz'), isEmpty);
    });

    test('blank query returns everything', () {
      expect(filterLibraryEntries(entries, '  '), hasLength(2));
    });
  });
}
