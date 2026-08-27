import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/player_args.dart';

void main() {
  group('classifyPlayer', () {
    test('named players map directly', () {
      expect(classifyPlayer('vlc', ''), PlayerKind.vlc);
      expect(classifyPlayer('mpv', ''), PlayerKind.mpv);
      expect(classifyPlayer('mpc-hc', ''), PlayerKind.mpcHc);
    });

    test('custom paths are sniffed, case-insensitively', () {
      expect(classifyPlayer('custom', r'C:\Tools\MPC-HC64\mpc-hc64.exe'),
          PlayerKind.mpcHc);
      expect(classifyPlayer('custom', r'C:\Program Files\VideoLAN\VLC\vlc.exe'),
          PlayerKind.vlc);
      expect(classifyPlayer('custom', r'D:\mpv\mpv.exe'), PlayerKind.mpv);
    });

    test('unknown custom player and unresolved default are "other"', () {
      expect(classifyPlayer('custom', r'C:\PotPlayer\PotPlayerMini64.exe'),
          PlayerKind.other);
      expect(classifyPlayer('custom', ''), PlayerKind.other);
      expect(classifyPlayer('default', ''), PlayerKind.other);
    });
  });

  group('resumeSeconds', () {
    test('nothing watched yet', () {
      expect(
          resumeSeconds(
              watchPosition: null, watchProgress: null, watchedThreshold: 90),
          0);
    });

    test('positions of 10s or less are ignored', () {
      expect(
          resumeSeconds(
              watchPosition: 10, watchProgress: 0.01, watchedThreshold: 90),
          0);
      expect(
          resumeSeconds(
              watchPosition: 11, watchProgress: 0.01, watchedThreshold: 90),
          11);
    });

    test('an already-watched VOD restarts from the top', () {
      // At the threshold exactly: watched.
      expect(
          resumeSeconds(
              watchPosition: 3000, watchProgress: 0.90, watchedThreshold: 90),
          0);
      // Just under: resume.
      expect(
          resumeSeconds(
              watchPosition: 3000, watchProgress: 0.89, watchedThreshold: 90),
          3000);
    });
  });

  group('buildPlayerArgs', () {
    test('MPC-HC takes milliseconds and keeps the compact seek bar', () {
      final args = buildPlayerArgs(
          kind: PlayerKind.mpcHc,
          startSeconds: 600,
          port: 8089,
          ipcName: '123',
          isWindows: true);
      expect(args, containsAllInOrder(['/start', '600000']));
      expect(args, containsAllInOrder(['/webport', '8089']));
      expect(args, containsAllInOrder(['/viewpreset', '2']));
    });

    test('no start flag when starting from the beginning', () {
      for (final kind in [PlayerKind.vlc, PlayerKind.mpv, PlayerKind.mpcHc]) {
        final args = buildPlayerArgs(
            kind: kind,
            startSeconds: 0,
            port: 8089,
            ipcName: '1',
            isWindows: true);
        expect(args.join(' '), isNot(contains('start')), reason: '$kind');
      }
    });

    test('VLC always exposes its HTTP interface on the given port', () {
      final args = buildPlayerArgs(
          kind: PlayerKind.vlc,
          startSeconds: 30,
          port: 9001,
          ipcName: '1',
          isWindows: true);
      expect(args, contains('--start-time=30'));
      expect(args, contains('--http-port=9001'));
      expect(args, contains('--extraintf=http'));
    });

    test('MPV IPC path differs by platform', () {
      expect(
          buildPlayerArgs(
              kind: PlayerKind.mpv,
              startSeconds: 0,
              port: 1,
              ipcName: 'abc',
              isWindows: true),
          contains(r'--input-ipc-server=\\.\pipe\mpv-socket-abc'));
      expect(
          buildPlayerArgs(
              kind: PlayerKind.mpv,
              startSeconds: 0,
              port: 1,
              ipcName: 'abc',
              isWindows: false),
          contains('--input-ipc-server=/tmp/mpv-socket-abc'));
    });

    test('an unknown player gets no flags at all', () {
      expect(
          buildPlayerArgs(
              kind: PlayerKind.other,
              startSeconds: 600,
              port: 1,
              ipcName: '1',
              isWindows: true),
          isEmpty);
    });
  });

  group('buildPlayerArgs keepOpen', () {
    List<String> mpv({bool keepOpen = false}) => buildPlayerArgs(
        kind: PlayerKind.mpv,
        startSeconds: 0,
        port: 1234,
        ipcName: 'v1',
        isWindows: true,
        keepOpen: keepOpen);

    test('defaults off, so local playback keeps close-at-end', () {
      expect(mpv(), isNot(contains('--keep-open=yes')));
    });

    test('on for mpv when asked', () {
      expect(mpv(keepOpen: true), contains('--keep-open=yes'));
    });

    test('other kinds ignore it - the flag is mpv syntax', () {
      final vlc = buildPlayerArgs(
          kind: PlayerKind.vlc,
          startSeconds: 0,
          port: 1234,
          ipcName: 'v1',
          isWindows: true,
          keepOpen: true);
      expect(vlc.where((a) => a.contains('keep-open')), isEmpty);
    });
  });

  group('shlexQuote', () {
    test('preserves MPV\'s Windows pipe path through streamlink\'s shlex', () {
      // Regression: streamlink parses --player-args with POSIX shlex, where a
      // backslash escapes the next character, so the unquoted pipe path
      // arrived at MPV as `--input-ipc-server=.pipempv-socket-123` and MPV
      // never created the pipe the progress bridge connects to.
      const raw = r'--input-ipc-server=\\.\pipe\mpv-socket-123';
      expect(shlexQuote(raw), r"'--input-ipc-server=\\.\pipe\mpv-socket-123'");
    });

    test('leaves ordinary tokens untouched', () {
      expect(shlexQuote('--http-port=8089'), '--http-port=8089');
      expect(shlexQuote('/webport'), '/webport');
      expect(shlexQuote('2'), '2');
    });

    test('quotes tokens containing spaces', () {
      expect(shlexQuote('a b'), "'a b'");
    });

    test('escapes embedded single quotes', () {
      expect(shlexQuote("it's"), r"'it'\''s'");
    });

    test('joinPlayerArgs quotes only what needs it', () {
      final joined = joinPlayerArgs([
        r'--input-ipc-server=\\.\pipe\mpv-socket-1',
        '--http-port=8089',
      ]);
      expect(joined,
          r"'--input-ipc-server=\\.\pipe\mpv-socket-1' --http-port=8089");
    });
  });
}
