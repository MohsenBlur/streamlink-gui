import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/player_args.dart';

const _defaultClientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';

VodStreamCommand build({
  bool seekable = true,
  int resume = 0,
  PlayerKind kind = PlayerKind.mpcHc,
  String? playerExe = r'C:\MPC-HC\mpc-hc64.exe',
  String customPlayerArgs = '',
  String oauthToken = '',
  String clientId = _defaultClientId,
}) {
  return buildVodStreamlinkArgs(
    vodId: '12345',
    titleString: 'chan - Some VOD',
    quality: 'best',
    oauthToken: oauthToken,
    clientId: clientId,
    kind: kind,
    playerExe: playerExe,
    customPlayerArgs: customPlayerArgs,
    port: 8089,
    seekableStreaming: seekable,
    resume: resume,
    isWindows: true,
  );
}

/// The value passed to `--player-args`, or null when the flag is absent.
String? playerArgsOf(List<String> args) {
  final i = args.indexOf('--player-args');
  return i == -1 ? null : args[i + 1];
}

void main() {
  group('passthrough on', () {
    test('asks streamlink to hand the HLS URL to the player', () {
      final cmd = build();
      expect(cmd.args, containsAllInOrder(['--player-passthrough', 'hls']));
      expect(cmd.passthrough, isTrue);
    });

    test('resume becomes a player-side flag, never --hls-start-offset', () {
      // Under passthrough streamlink does no HLS processing, so
      // --hls-start-offset would be silently ignored.
      final cmd = build(resume: 600);
      expect(cmd.args, isNot(contains('--hls-start-offset')));
      expect(playerArgsOf(cmd.args), contains('/start 600000'));
      expect(cmd.appliedStart, 600);
    });

    test('a player with no start flag still gets a seek bar, and says so', () {
      final cmd = build(
          kind: PlayerKind.other, playerExe: r'C:\Other\p.exe', resume: 600);
      expect(cmd.passthrough, isTrue);
      expect(cmd.resumeUnsupported, isTrue);
      expect(cmd.appliedStart, 0);
      expect(cmd.args, isNot(contains('--hls-start-offset')));
    });
  });

  group('passthrough off', () {
    test('falls back to streamlink skipping ahead', () {
      final cmd = build(seekable: false, resume: 600);
      expect(cmd.args, containsAllInOrder(['--hls-start-offset', '600s']));
      expect(cmd.args, isNot(contains('--player-passthrough')));
      expect(cmd.passthrough, isFalse);
      // The player is fed a pipe, so a player-side seek would be meaningless.
      expect(playerArgsOf(cmd.args), isNot(contains('/start')));
    });

    test('no resume means no offset flag', () {
      final cmd = build(seekable: false);
      expect(cmd.args, isNot(contains('--hls-start-offset')));
    });
  });

  test('without a resolvable player, passthrough is not attempted', () {
    // Streamlink aborts with "The default player (VLC) does not seem to be
    // installed" if passthrough is requested with no --player.
    final cmd =
        build(playerExe: null, kind: PlayerKind.other, resume: 600);
    expect(cmd.args, isNot(contains('--player')));
    expect(cmd.args, isNot(contains('--player-passthrough')));
    expect(cmd.passthrough, isFalse);
    expect(cmd.args, containsAllInOrder(['--hls-start-offset', '600s']));
  });

  group('twitch auth header', () {
    test('sent only with a token on the default client id', () {
      expect(build(oauthToken: 'abc').args, contains('--twitch-api-header'));
      expect(build(oauthToken: '').args, isNot(contains('--twitch-api-header')));
      expect(build(oauthToken: 'abc', clientId: 'custom-id').args,
          isNot(contains('--twitch-api-header')));
    });
  });

  test('user player args are forwarded verbatim, ahead of generated ones', () {
    final cmd = build(customPlayerArgs: '  --fullscreen  ');
    final pa = playerArgsOf(cmd.args)!;
    expect(pa.startsWith('--fullscreen'), isTrue);
    expect(pa, contains('/webport 8089'));
  });

  test('MPV pipe path is quoted so streamlink\'s shlex cannot eat it', () {
    final cmd = build(kind: PlayerKind.mpv, playerExe: r'C:\mpv\mpv.exe');
    expect(playerArgsOf(cmd.args),
        contains(r"'--input-ipc-server=\\.\pipe\mpv-socket-12345'"));
  });

  test('the URL and quality stay last, in that order', () {
    // streamlink reads these positionally; a reorder would fail silently.
    final args = build(resume: 600).args;
    expect(args[args.length - 2], 'twitch.tv/videos/12345');
    expect(args.last, 'best');
  });
  group('buildLiveStreamlinkArgs', () {
    List<String> live({
      String? playerExe = r'C:\Program Files\VideoLAN\VLC\vlc.exe',
      String customPlayerArgs = '',
      bool lowLatency = false,
      String oauthToken = '',
      String clientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko',
    }) {
      return buildLiveStreamlinkArgs(
        channelName: 'shroud',
        titleString: 'shroud - Live',
        quality: 'best',
        oauthToken: oauthToken,
        clientId: clientId,
        playerExe: playerExe,
        customPlayerArgs: customPlayerArgs,
        lowLatency: lowLatency,
      );
    }

    test('the URL and quality stay last, in that order', () {
      final args = live();
      expect(args[args.length - 2], 'twitch.tv/shroud');
      expect(args.last, 'best');
    });

    test('low latency is opt-in and passed through when on', () {
      // The flag IS supported by the bundled streamlink 8.4.0 - the comment
      // that used to sit at this spot in the live path claimed otherwise, and
      // the setting was simply never read.
      expect(live(lowLatency: false), isNot(contains('--twitch-low-latency')));
      expect(live(lowLatency: true), contains('--twitch-low-latency'));
    });

    test('an unresolved player emits no --player at all', () {
      // Rather than a bare quoted string streamlink cannot run.
      expect(live(playerExe: null), isNot(contains('--player')));
    });

    test('the resolved executable is passed verbatim', () {
      // Quote stripping belongs to resolvePlayerExecutable, which the live
      // path now shares with the VOD path; by here the value is already clean.
      final args = live(playerExe: r'C:\Program Files\mpv\mpv.exe');
      expect(args[args.indexOf('--player') + 1],
          r'C:\Program Files\mpv\mpv.exe');
    });

    test('the api header rides only on the default client id', () {
      expect(live(oauthToken: 'abc'), contains('--twitch-api-header'));
      expect(live(oauthToken: 'abc', clientId: 'my-own-app'),
          isNot(contains('--twitch-api-header')));
      expect(live(), isNot(contains('--twitch-api-header')));
    });

    test('custom player args are omitted when blank', () {
      expect(live(customPlayerArgs: '   '), isNot(contains('--player-args')));
      final args = live(customPlayerArgs: '  --fullscreen  ');
      expect(args[args.indexOf('--player-args') + 1], '--fullscreen');
    });
  });
}
