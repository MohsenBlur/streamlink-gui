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
          isWindows: true,
          httpPassword: 'pw',
          mpcSlaveWindow: '197380');
      expect(args, containsAllInOrder(['/start', '600000']));
      expect(args, containsAllInOrder(['/slave', '197380']));
      expect(args, containsAllInOrder(['/viewpreset', '2']));
    });

    test("MPC-HC's web interface is never turned on", () {
      // It has no authentication: while a VOD played, any web page could
      // drive the player with a plain GET (a UNC path leaks the NTLM hash).
      for (final window in ['197380', null]) {
        final args = buildPlayerArgs(
            kind: PlayerKind.mpcHc,
            startSeconds: 60,
            port: 8089,
            ipcName: '1',
            isWindows: true,
            httpPassword: 'pw',
            mpcSlaveWindow: window);
        expect(args, isNot(contains('/webport')));
        expect(args, isNot(contains('8089')));
      }
    });

    test('MPC-HC gets a player of its own, with or without a control window',
        () {
      // With "use the same player for each media file" (MPC-HC's default) a
      // launch while another MPC-HC is open hands the file, /slave and all,
      // to that one and exits.
      for (final window in ['197380', null]) {
        final args = buildPlayerArgs(
            kind: PlayerKind.mpcHc,
            startSeconds: 0,
            port: 8089,
            ipcName: '1',
            isWindows: true,
            httpPassword: 'pw',
            mpcSlaveWindow: window);
        expect(args, contains('/new'));
        expect(args.contains('/slave'), window != null);
      }
    });

    test('no start flag when starting from the beginning', () {
      for (final kind in [PlayerKind.vlc, PlayerKind.mpv, PlayerKind.mpcHc]) {
        final args = buildPlayerArgs(
            kind: kind,
            startSeconds: 0,
            port: 8089,
            ipcName: '1',
            isWindows: true,
            httpPassword: 'pw');
        expect(args.join(' '), isNot(contains('start')), reason: '$kind');
      }
    });

    test('VLC always exposes its HTTP interface on the given port', () {
      final args = buildPlayerArgs(
          kind: PlayerKind.vlc,
          startSeconds: 30,
          port: 9001,
          ipcName: '1',
          isWindows: true,
          httpPassword: 'pw');
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
              isWindows: true,
              httpPassword: 'pw'),
          contains(r'--input-ipc-server=\\.\pipe\mpv-socket-abc'));
      expect(
          buildPlayerArgs(
              kind: PlayerKind.mpv,
              startSeconds: 0,
              port: 1,
              ipcName: 'abc',
              isWindows: false,
              httpPassword: 'pw'),
          contains('--input-ipc-server=/tmp/mpv-socket-abc'));
    });

    test('an unknown player gets no flags at all', () {
      expect(
          buildPlayerArgs(
              kind: PlayerKind.other,
              startSeconds: 600,
              port: 1,
              ipcName: '1',
              isWindows: true,
              httpPassword: 'pw'),
          isEmpty);
    });
  });

  group("the players' control interfaces", () {
    test("VLC's HTTP password is the session's own, not a public constant",
        () {
      // "streamlink" was in the public source: any program on the machine
      // could log in and have VLC list folders or open any file.
      final args = buildPlayerArgs(
          kind: PlayerKind.vlc,
          startSeconds: 0,
          port: 9001,
          ipcName: '1',
          isWindows: true,
          httpPassword: 's3cret');
      expect(args, contains('--http-password=s3cret'));
      expect(args.join(' '), isNot(contains('=streamlink')));
      expect(args, contains('--http-host=127.0.0.1'));
    });
  });

  group('buildPlayerArgs keepOpen', () {
    List<String> mpv({bool keepOpen = false}) => buildPlayerArgs(
        kind: PlayerKind.mpv,
        startSeconds: 0,
        port: 1234,
        ipcName: 'v1',
        isWindows: true,
        httpPassword: 'pw',
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
          httpPassword: 'pw',
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
      expect(shlexQuote('/slave'), '/slave');
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
