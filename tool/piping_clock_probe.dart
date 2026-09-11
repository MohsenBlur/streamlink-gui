// Does piping mode report an ABSOLUTE clock or a RELATIVE one?
//
// This exists because the repo answered that question wrongly for three weeks.
//
// docs/vod-seeking.md concluded in 2026-08 that piping does not corrupt watch
// progress, from piping a VOD into ffprobe and reading `start_time=668.149` for
// a 600s offset — streamlink preserves source timestamps, therefore the player
// sees an absolute clock. The measurement was real. The conclusion was false,
// and the note itself said why in its last line: it reads the *container's*
// timestamp base, not what the player surfaces.
//
// Re-measured here against the thing that actually matters — MPC-HC's own
// reported position, which is the number the progress tracker consumes:
//
//   60s offset -> player reports 1s, 2s, 3s, 4s
//
// The player rebases to zero. So every resumed piping session wrote a handful
// of seconds over the stored position, locally and to Twitch, within about four
// seconds. `positionOffset` in `_startVODProgressTracker` puts the skip back.
//
// Run:
//   dart run tool/piping_clock_probe.dart <streamlink exe> <mpc-hc exe> <hls dir>
//
// Expected on a healthy build: ABSOLUTE — the tracker's own offset makes the
// reported position match the real one. Run it with the offset removed to see
// the original defect reappear.
import 'dart:io';

import 'package:streamlink_gui/utils/player_progress.dart';

const httpPort = 14011;
const webPort = 14001;
const offset = 60;

final client = HttpClient();

Future<PlayerStatus?> poll() async {
  try {
    final r = await (await client
            .getUrl(Uri.parse('http://127.0.0.1:$webPort/variables.html'))
            .timeout(const Duration(seconds: 2)))
        .close()
        .timeout(const Duration(seconds: 2));
    return parseMpcHcStatus(
        await r.transform(const SystemEncoding().decoder).join());
  } catch (_) {
    return null;
  }
}

Future<void> main(List<String> a) async {
  if (a.length < 3) {
    print('usage: dart run tool/piping_clock_probe.dart '
        '<streamlink exe> <mpc-hc exe> <dir with stream.m3u8>');
    exit(2);
  }
  final streamlink = a[0];
  final mpc = a[1];
  final dir = a[2];

  final server = await HttpServer.bind('127.0.0.1', httpPort);
  server.listen((req) async {
    final f =
        File('$dir${Platform.pathSeparator}${req.uri.path.replaceAll('/', '')}');
    if (!f.existsSync()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    req.response.add(await f.readAsBytes());
    await req.response.close();
  }, onError: (_) {});

  // Exactly what buildVodStreamlinkArgs emits for piping: no start flag on the
  // player, the skip performed by streamlink.
  final args = [
    '--player', mpc,
    '--player-args', '/webport $webPort /viewpreset 2',
    '--hls-start-offset', '${offset}s',
    'hls://http://127.0.0.1:$httpPort/stream.m3u8',
    'best',
  ];
  print('streamlink ${args.join(' ')}\n');
  final proc = await Process.start(streamlink, args);

  int? seen;
  for (var t = 0; t < 45; t++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final s = await poll();
    if (s?.positionSeconds != null && s!.activity == PlayerActivity.playing) {
      seen = s.positionSeconds;
      print('  t=${t}s  player reports ${seen}s');
      if (t > 3) break;
    }
  }

  proc.kill();
  try {
    Process.runSync('taskkill', ['/F', '/IM', 'mpc-hc64.exe']);
  } catch (_) {}
  await server.close(force: true);
  client.close(force: true);

  print('\n--- verdict ---');
  if (seen == null) {
    print('INCONCLUSIVE - the player never reported a playing position.');
  } else if (seen >= offset - 10) {
    print('ABSOLUTE clock: ${seen}s reported for a ${offset}s offset.');
  } else {
    print('RELATIVE clock: ${seen}s reported for a ${offset}s offset - the '
        'tracker must add the skip back, or every resumed piping session '
        'overwrites the stored position within seconds.');
  }
  exit(0);
}
