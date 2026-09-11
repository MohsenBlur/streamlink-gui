// Forensic instrument for the SELF-HEAL, not part of the app.
//
// `mpc_probe.dart` proved the DETECTION half (a dying stream produces a
// premature-EOF verdict). It never touched the half that actually failed in
// the field: the relaunch. It launches MPC-HC with `/play` and no `/start`,
// and stops at the verdict printing "the heal WOULD trigger" - so the bounce
// itself shipped verified against no player at all.
//
// This answers the questions that separate the candidate causes, and then
// exercises the fix itself (Q5) through the shipped decision logic:
//
//   Q1  Does MPC-HC honour `/start <ms>` on an HLS URL at all?
//   Q2  After the source dies, what does an IDLING MPC-HC keep reporting? If
//       it repeats a low position, two readings corroborate each other and the
//       confirmation gate commits it - the gate's founding premise ("a dying
//       player's bad reading is a lone reading") is then false.
//   Q4  Does the web-interface seek work as a correction, and in what units?
//       (`command.html?wm_command=-1&percent=` is what MPC-HC's own UI sends;
//       `-1` is CMD_SETPOS, both extracted from the shipped binary.)
//   Q5  Does LandingCheck + seekRequestPath actually rescue a discarded
//       `/start`? Measured: landed 0s asked 60s, corrected to 64s in one seek.
//
// Measured answers on MPC-HC 2.7.4: Q1 FAIL (/start discarded on a network
// stream, honoured on a local file), Q2 the gate HELD (it committed nothing
// low - the idling-corroboration theory did not fire), Q3 FAIL, Q4 PASS,
// Q5 PASS.
//
// Run:  dart run tool/mpc_heal_probe.dart <mpc-hc exe> <dir with stream.m3u8>
import 'dart:io';

import 'package:streamlink_gui/utils/player_progress.dart';
import 'package:streamlink_gui/utils/player_seek.dart';
import 'package:streamlink_gui/utils/vod_playback_monitor.dart';

const httpPort = 13697;
const webPortA = 13687;
const webPortB = 13688; // deliberately DIFFERENT, to isolate Q3 from port reuse
const durationSeconds = 120;
const resumeAt = 60; // where the "heal" claims the user was

HttpServer? _server;
HttpServer get server => _server!;
set server(HttpServer v) => _server = v;
bool serverDead = true;

Future<void> startServer(String hlsDir) async {
  // Release any listener still bound from the previous phase first: binding
  // twice on one address is an error, not a wait.
  if (_server != null && !serverDead) {
    try {
      await _server!.close(force: true);
    } catch (_) {}
    serverDead = true;
  }
  // Then bind with a retry, because a just-closed listener can hold the port
  // for a moment and a probe that dies on that is not a reusable instrument.
  for (var attempt = 0; ; attempt++) {
    try {
      server = await HttpServer.bind('127.0.0.1', httpPort);
      break;
    } on SocketException {
      if (attempt >= 10) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
  serverDead = false;
  server.listen((req) async {
    final f = File(
        '$hlsDir${Platform.pathSeparator}${req.uri.path.replaceAll('/', '')}');
    if (!f.existsSync()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final bytes = await f.readAsBytes();
    if (req.uri.path.endsWith('.ts')) {
      // Throttled so the player holds a realistic buffer rather than
      // swallowing the whole VOD before we can kill anything.
      for (var i = 0; i < bytes.length; i += 65536) {
        req.response.add(
            bytes.sublist(i, i + 65536 > bytes.length ? bytes.length : i + 65536));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } else {
      req.response.add(bytes);
    }
    await req.response.close();
  }, onError: (_) {});
}

final client = HttpClient();

Future<String?> raw(int webPort, String path) async {
  try {
    final req = await client
        .getUrl(Uri.parse('http://127.0.0.1:$webPort/$path'))
        .timeout(const Duration(seconds: 2));
    final res = await req.close().timeout(const Duration(seconds: 2));
    return await res.transform(const SystemEncoding().decoder).join();
  } catch (_) {
    return null;
  }
}

Future<PlayerStatus?> poll(int webPort) async {
  final body = await raw(webPort, 'variables.html');
  return body == null ? null : parseMpcHcStatus(body);
}

Future<Process> launch(String exe, int webPort, {int? startMs}) {
  return Process.start(exe, [
    if (startMs != null) ...['/start', '$startMs'],
    '/webport', '$webPort',
    '/viewpreset', '2',
    'http://127.0.0.1:$httpPort/stream.m3u8',
  ]);
}

Future<void> main(List<String> args) async {
  final exe = args[0];
  final hlsDir = args[1];
  final findings = <String, String>{};

  // ---------------------------------------------------------------- Q1 ----
  print('\n=== Q1: does /start <ms> work on an HLS URL? ===');
  await startServer(hlsDir);
  var proc = await launch(exe, webPortA, startMs: resumeAt * 1000);

  int? firstSeen;
  for (var t = 0; t < 30; t += 1) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final s = await poll(webPortA);
    if (s?.positionSeconds != null && s!.activity == PlayerActivity.playing) {
      firstSeen = s.positionSeconds;
      print('  t=${t}s  first playing position = ${firstSeen}s '
          '(asked for ${resumeAt}s)');
      break;
    }
    if (t % 5 == 0) print('  t=${t}s  ${s?.activity.name ?? 'no contact'}');
  }
  if (firstSeen == null) {
    findings['Q1'] = 'INCONCLUSIVE - never reported a playing position';
  } else if ((firstSeen - resumeAt).abs() <= 5) {
    findings['Q1'] = 'PASS - /start honoured (landed ${firstSeen}s)';
  } else {
    findings['Q1'] = 'FAIL - /start IGNORED (landed ${firstSeen}s, '
        'asked ${resumeAt}s)  <-- this alone explains the bug';
  }
  print('  ${findings['Q1']}');

  // ---------------------------------------------------------------- Q4 ----
  print('\n=== Q4: does the web-interface seek work? ===');
  final target = 90;
  final pct = (target / durationSeconds) * 100;
  final seekRes =
      await raw(webPortA, 'command.html?wm_command=-1&percent=$pct');
  await Future<void>.delayed(const Duration(seconds: 3));
  final afterSeek = await poll(webPortA);
  print('  seek request ${seekRes == null ? 'FAILED' : 'accepted'}; '
      'position now ${afterSeek?.positionSeconds}s (asked ${target}s)');
  if (afterSeek?.positionSeconds != null &&
      (afterSeek!.positionSeconds! - target).abs() <= 6) {
    findings['Q4'] = 'PASS - percent seek works, usable as a correction';
  } else {
    findings['Q4'] = 'FAIL - percent seek did not land '
        '(got ${afterSeek?.positionSeconds}s)';
  }
  print('  ${findings['Q4']}');

  // ---------------------------------------------------------------- Q2 ----
  print('\n=== Q2: what does an IDLING MPC-HC report after the source dies? ===');
  await server.close(force: true);
  serverDead = true;
  print('  *** SERVER KILLED ***');

  final monitor = VodPlaybackMonitor(durationSeconds: durationSeconds);
  final reported = <String>[];
  final commits = <int>[];
  for (var t = 0; t < 40; t += 2) {
    final s = await poll(webPortA);
    final r = monitor.onSample(
        status: s, nowMs: DateTime.now().millisecondsSinceEpoch);
    reported.add('${s?.positionSeconds}/${s?.activity.name}');
    if (r.commitPositionSeconds != null) commits.add(r.commitPositionSeconds!);
    for (final e in r.events) {
      print('  t=${t}s  EVENT ${e.name}  confirmed=${monitor.lastConfirmedPosition}s '
          'reported=${s?.positionSeconds}s ${s?.activity.name}');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  print('  reported sequence: ${reported.join('  ')}');
  print('  gate commits: $commits');
  final confirmed = monitor.lastConfirmedPosition;
  findings['Q2'] = 'confirmed=${confirmed}s after death; commits=$commits';
  final low = commits.where((c) => c < 30).toList();
  findings['Q2_verdict'] = low.isEmpty
      ? 'gate held - no low value committed'
      : 'GATE COMMITTED LOW VALUES $low  <-- R2 confirmed, '
          'an idling player corroborates its own bad reading';
  print('  ${findings['Q2_verdict']}');

  // ---------------------------------------------------------------- Q5 ----
  // The fix itself, driven through the SHIPPED decision logic rather than a
  // hand-rolled imitation of it: LandingCheck decides, seekRequestPath builds
  // the request. If this lands, the app lands.
  print('\n=== Q5: does the landing check + seek correct a discarded /start? ===');
  proc.kill();
  await Future<void>.delayed(const Duration(seconds: 2));
  await startServer(hlsDir);
  proc = await launch(exe, webPortB, startMs: resumeAt * 1000);

  final check = LandingCheck(intendedSeconds: resumeAt);
  int? corrected;
  for (var t = 0; t < 40; t++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final st = await poll(webPortB);
    if (st?.positionSeconds == null || st!.activity != PlayerActivity.playing) {
      continue;
    }
    if (check.isSettled) {
      corrected = st.positionSeconds;
      break;
    }
    final target = check.evaluate(st.positionSeconds!);
    if (target != null) {
      final path = seekRequestPath(SeekChannel.mpcHcWeb,
          targetSeconds: target, durationSeconds: durationSeconds);
      print('  landed ${st.positionSeconds}s, asked ${resumeAt}s -> correcting');
      await raw(webPortB, path!);
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  findings['Q5'] = corrected == null
      ? 'INCONCLUSIVE - never settled'
      : (((corrected - resumeAt).abs() <= kSeekToleranceSeconds)
          ? 'PASS - corrected to ${corrected}s (asked ${resumeAt}s) after '
              '${check.corrections} seek(s)'
          : 'FAIL - settled at ${corrected}s, asked ${resumeAt}s');
  print('  ${findings['Q5']}');

  proc.kill();
  if (!serverDead) await server.close(force: true);
  client.close(force: true);

  print('\n================ SUMMARY ================');
  for (final e in findings.entries) {
    print('${e.key.padRight(11)} ${e.value}');
  }
  exit(0);
}
