import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/player_service.dart';

/// yt-dlp's download archive, as PlayerService takes VODs back out of it.
void main() {
  late Directory temp;
  late File archive;
  late PlayerService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('streamlink_gui_archive_');
    archive = File('${temp.path}${Platform.pathSeparator}yt_dlp_archive.txt');
    service = PlayerService()..downloadArchiveFilePath = archive.path;
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('removes the line yt-dlp wrote for a Twitch VOD, and only that one', () {
    // Exactly as yt-dlp writes them: its Twitch ids carry a v.
    archive.writeAsStringSync('twitchvod v2821242888\n'
        'twitchvod v28212428880\n'
        'twitchvod v2825247440\n');

    service.removeVodFromArchive('2821242888');

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
}
