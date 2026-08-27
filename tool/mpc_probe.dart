// A forensic instrument, not part of the app: drives the SHIPPED detection
// chain - parseMpcHcStatus feeding VodPlaybackMonitor - against a real
// MPC-HC playing a local HLS stream that this script kills mid-play.
//
// This is how "paused at the duration is MPC-HC's end-of-file signal" was
// measured (v2.7.4), and how to re-verify it against a future MPC-HC. Run:
//
//   dart run tool/mpc_probe.dart <mpc-hc exe> <dir with stream.m3u8>
//
// Expected verdict on a healthy fix: stall events while the buffer drains,
// then eofObserved -> prematureEof with the confirmed position at the stall
// point - never at the bogus jumped-to-duration value.
import 'dart:io';

import 'package:streamlink_gui/utils/player_progress.dart';
import 'package:streamlink_gui/utils/vod_playback_monitor.dart';

Future<void> main(List<String> args) async {
  final exe = args[0];
  final hlsDir = args[1];
  const httpPort = 13594;
  const webPort = 13584;

  // A throttled HLS server: ~4s segments served over ~3s, so the player
  // holds a realistic buffer instead of swallowing the whole VOD instantly.
  final server = await HttpServer.bind('127.0.0.1', httpPort);
  var serverDead = false;
  server.listen((req) async {
    final f = File('$hlsDir${Platform.pathSeparator}'
        '${req.uri.path.replaceAll('/', '')}');
    if (!f.existsSync()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final bytes = await f.readAsBytes();
    if (req.uri.path.endsWith('.ts')) {
      for (var i = 0; i < bytes.length; i += 65536) {
        req.response.add(bytes.sublist(
            i, i + 65536 > bytes.length ? bytes.length : i + 65536));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    } else {
      req.response.add(bytes);
    }
    await req.response.close();
  }, onError: (_) {});

  final proc = await Process.start(exe, [
    '/webport', '$webPort', '/viewpreset', '2',
    '/play', 'http://127.0.0.1:$httpPort/stream.m3u8',
  ]);

  final monitor = VodPlaybackMonitor(durationSeconds: 60);
  final client = HttpClient();

  Future<PlayerStatus?> poll() async {
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$webPort/variables.html'))
          .timeout(const Duration(seconds: 2));
      final res = await req.close().timeout(const Duration(seconds: 2));
      final body = await res.transform(const SystemEncoding().decoder).join();
      return parseMpcHcStatus(body);
    } catch (_) {
      return null;
    }
  }

  var prematureSeen = false;
  for (var t = 0; t < 60; t += 2) {
    if (t >= 12 && !serverDead) {
      serverDead = true;
      await server.close(force: true);
      print('t=${t}s  *** SERVER KILLED ***');
    }
    final status = await poll();
    final result = monitor.onSample(
        status: status, nowMs: DateTime.now().millisecondsSinceEpoch);
    for (final e in result.events) {
      print('t=${t}s  EVENT ${e.name}  '
          'confirmed=${monitor.lastConfirmedPosition}s  '
          'reported=${status?.positionSeconds}s ${status?.activity.name}');
      if (e == MonitorEvent.prematureEof) prematureSeen = true;
    }
    if (prematureSeen) break;
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  proc.kill();
  client.close(force: true);
  print(prematureSeen
      ? 'VERDICT: prematureEof fired - the heal would trigger for MPC-HC'
      : 'VERDICT: NO premature verdict - the chain does not work');
  exit(prematureSeen ? 0 : 1);
}
