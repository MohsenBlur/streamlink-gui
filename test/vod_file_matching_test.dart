import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/player_service.dart';

/// Exercises the file matching that the delete/cancel/retention paths rely on.
///
/// These paths used to test `path.contains(' - $vodId')`, which is unanchored:
/// deleting id `12345` also matched `Title - 123456789.mp4`. Since these
/// operations delete multi-gigabyte files irreversibly, the matcher gets its
/// own tests.
void main() {
  late Directory tempDir;
  late Directory channelDir;
  late PlayerService player;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('streamlink_gui_vodfiles_');
    channelDir = Directory('${tempDir.path}${Platform.pathSeparator}somechannel')
      ..createSync(recursive: true);
    player = PlayerService();
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  File touch(String name, {String content = 'x'}) {
    final f = File('${channelDir.path}${Platform.pathSeparator}$name');
    f.writeAsStringSync(content);
    return f;
  }

  List<String> names(List<File> files) =>
      files.map((f) => f.uri.pathSegments.last).toList()..sort();

  group('findDownloadedVodFiles', () {
    test('matches only the exact id', () {
      touch('A Stream - 12345.mp4');
      touch('Another - 123456789.mp4');
      touch('Third - 912345.mkv');

      final found = player.findDownloadedVodFiles('12345', 'somechannel', tempDir.path);
      expect(names(found), ['A Stream - 12345.mp4']);
    });

    test('a longer id is not matched by a shorter one', () {
      touch('Long - 123456789.mp4');

      expect(
        player.findDownloadedVodFiles('12345', 'somechannel', tempDir.path),
        isEmpty,
        reason: 'a prefix of a longer id must never match',
      );
    });

    test('accepts the legacy v-prefixed form', () {
      touch('Old Style - v6789.mp4');
      final found = player.findDownloadedVodFiles('6789', 'somechannel', tempDir.path);
      expect(names(found), ['Old Style - v6789.mp4']);
    });

    test('ignores partial and temporary files', () {
      touch('A Stream - 12345.mp4.part');
      touch('A Stream - 12345.f301.mp4.part');
      touch('A Stream - 12345.ytdl');

      expect(player.findDownloadedVodFiles('12345', 'somechannel', tempDir.path), isEmpty);
    });

    test('returns nothing for a missing folder or empty root', () {
      expect(player.findDownloadedVodFiles('1', 'nope', tempDir.path), isEmpty);
      expect(player.findDownloadedVodFiles('1', 'somechannel', '   '), isEmpty);
    });
  });

  group('findTemporaryVodFiles', () {
    test('matches partials for the exact id only', () {
      touch('A Stream - 12345.mp4.part');
      touch('A Stream - 12345.f301.mp4.part');
      touch('A Stream - 12345.ytdl');
      touch('Other - 999.mp4.part');
      touch('A Stream - 12345.mp4'); // completed, not temporary

      final found = player.findTemporaryVodFiles('12345', 'somechannel', tempDir.path);
      expect(names(found), [
        'A Stream - 12345.f301.mp4.part',
        'A Stream - 12345.mp4.part',
        'A Stream - 12345.ytdl',
      ]);
    });

    test('does not match a different in-flight download', () {
      touch('Other - 123456789.mp4.part');
      expect(player.findTemporaryVodFiles('12345', 'somechannel', tempDir.path), isEmpty);
    });
  });

  group('deleteVodFiles', () {
    test('removes the VOD files and reports an accurate count', () {
      touch('A Stream - 12345.mp4');
      touch('A Stream - 12345.mp4.part');
      final survivor = touch('Another - 123456789.mp4');

      final deleted = player.deleteVodFiles('12345', 'somechannel', tempDir.path);

      expect(deleted, 2);
      expect(survivor.existsSync(), isTrue, reason: 'unrelated VOD must survive');
      expect(channelDir.listSync().whereType<File>(), hasLength(1));
    });

    test('returns zero when nothing matches', () {
      touch('Another - 999.mp4');
      expect(player.deleteVodFiles('12345', 'somechannel', tempDir.path), 0);
    });

    test('can leave temporary files alone', () {
      touch('A Stream - 12345.mp4');
      final partial = touch('A Stream - 12345.mp4.part');

      final deleted = player.deleteVodFiles(
        '12345',
        'somechannel',
        tempDir.path,
        includeTemporary: false,
      );

      expect(deleted, 1);
      expect(partial.existsSync(), isTrue);
    });
  });

  group('getDownloadedVodFile', () {
    test('returns the completed file when present', () {
      touch('A Stream - 12345.mp4');
      final file = player.getDownloadedVodFile('12345', 'somechannel', tempDir.path);
      expect(file, isNotNull);
      expect(file!.path, endsWith('A Stream - 12345.mp4'));
    });

    test('returns null when only a partial exists', () {
      touch('A Stream - 12345.mp4.part');
      expect(player.getDownloadedVodFile('12345', 'somechannel', tempDir.path), isNull);
    });
  });
}
