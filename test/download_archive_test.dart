import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/player_service.dart';

import 'support/fake_process.dart';

/// yt-dlp's download archive, as PlayerService takes VODs back out of it.
void main() {
  late Directory temp;
  late File archive;
  late FakeLauncher launcher;
  late PlayerService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('streamlink_gui_archive_');
    archive = File('${temp.path}${Platform.pathSeparator}yt_dlp_archive.txt');
    launcher = FakeLauncher();
    service = PlayerService(
        startProcess: launcher.start, runProcess: FakeTaskkill(launcher).run)
      ..downloadArchiveFilePath = archive.path;
  });

  tearDown(() async {
    await service.stopAll();
    for (final p in launcher.launched) {
      await p.exit(-1);
    }
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('removes the line yt-dlp wrote for a Twitch VOD, and only that one',
      () async {
    // Exactly as yt-dlp writes them: its Twitch ids carry a v.
    archive.writeAsStringSync('twitchvod v2821242888\n'
        'twitchvod v28212428880\n'
        'twitchvod v2825247440\n');

    await service.removeVodFromArchive('2821242888');

    expect(archive.readAsLinesSync(),
        ['twitchvod v28212428880', 'twitchvod v2825247440']);
  });

  test('matches whole ids only', () {
    for (final (line, matches) in [
      ('twitchvod v2821242888', true),
      ('twitchvod 2821242888', true),
      ('twitchvod v2821242888 ', true),
      ('twitchvod v28212428880', false),
      ('twitchvod v821242888', false),
      ('twitchvod vv2821242888', false),
      ('v2821242888', false),
      ('', false),
    ]) {
      expect(PlayerService.isArchiveLineFor(line, '2821242888'), matches,
          reason: '"$line"');
    }
  });

  test('does not hold up the caller while it rewrites the file', () async {
    // It ran synchronously on the UI isolate, once per VOD of a multi-delete.
    archive.writeAsStringSync('twitchvod v1\ntwitchvod v2\n');

    final pending = service.removeVodFromArchive('1');
    expect(archive.readAsLinesSync(), ['twitchvod v1', 'twitchvod v2']);

    await pending;
    expect(archive.readAsLinesSync(), ['twitchvod v2']);
  });

  test('removals started together all take effect', () async {
    // A multi-delete starts one per VOD without waiting. Rewrites running
    // side by side would each start from the same read, and the last one
    // would put back what the others took out.
    archive.writeAsStringSync(
        [for (var i = 1; i <= 6; i++) 'twitchvod v$i'].join('\n'));

    await Future.wait([
      for (final id in ['1', '3', '5', '6']) service.removeVodFromArchive(id),
    ]);

    expect(archive.readAsLinesSync(), ['twitchvod v2', 'twitchvod v4']);
  });

  test('with no archive there is nothing to do', () async {
    await service.removeVodFromArchive('1');
    expect(archive.existsSync(), isFalse,
        reason: 'opening it for the rewrite must not create it');
  });

  group('beside yt-dlp, which locks the whole file', () {
    // yt-dlp takes LockFileEx over the whole file to read it and to append a
    // line, and RandomAccessFile.lock takes that same range. Windows byte-
    // range locks also exclude a second handle in the same process, which
    // is what lets one test process stand in for yt-dlp; POSIX record locks
    // do not.
    final skip =
        Platform.isWindows ? false : 'a lock only excludes this process on Windows';

    Future<RandomAccessFile> lockLikeYtDlp() async {
      final held = await archive.open(mode: FileMode.append);
      await held.lock(FileLock.blockingExclusive);
      return held;
    }

    test('the rewrite waits for its lock and keeps the line it appended',
        () async {
      archive.writeAsStringSync('twitchvod v1\ntwitchvod v2\n');
      final ytDlp = await lockLikeYtDlp();

      final pending = service.removeVodFromArchive('1');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // A download completing while the rewrite waits.
      await ytDlp.writeString('twitchvod v3\n');
      await ytDlp.unlock();
      await ytDlp.close();
      await pending;

      expect(archive.readAsLinesSync(), ['twitchvod v2', 'twitchvod v3'],
          reason: 'it read the file before the append, or read nothing '
              'at all past the lock');
    }, skip: skip);

    test('a download does not start until a removal before it is done',
        () async {
      // Deleted, then downloaded again: yt-dlp reading the old archive would
      // skip it as already done and exit 0 with no file.
      archive.writeAsStringSync('twitchvod v1\n');
      final ytDlp = await lockLikeYtDlp();

      final pending = service.removeVodFromArchive('1');
      service.queueVodDownload(
        TwitchVideo(
          id: '1',
          title: 'Some VOD',
          duration: '1h0m0s',
          thumbnailUrl: '',
          viewCount: '0',
          publishedAt: DateTime(2026),
        ),
        'chan',
        AppSettings(vodDownloadFolder: temp.path),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(launcher.launched, isEmpty);

      await ytDlp.unlock();
      await ytDlp.close();
      await pending;
      await pumpEventQueue();

      expect(launcher.launched, hasLength(1));
      expect(archive.readAsStringSync(), isEmpty);
    }, skip: skip);
  });
}
