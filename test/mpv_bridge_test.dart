import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/utils/player_args.dart';
import 'package:streamlink_gui/utils/player_progress.dart';
import 'package:streamlink_gui/utils/player_seek.dart';

/// The Windows mpv bridge: a PowerShell relay between a loopback TCP port and
/// mpv's named pipe.
///
/// Two defects lived here. The relay printed one line per exchange into a
/// stdout nobody read, so after about 340 polls it blocked and every progress
/// save, end-of-stream heal and seek after the eleventh minute silently did
/// nothing. And it copied raw bytes from any loopback client into a pipe that
/// accepts `run <program>`.
void main() {
  String withoutNewline(String line) => line.trimRight();

  group('bridge allowlist', () {
    test('admits every command the app itself sends', () {
      for (final command in mpvStatusCommands()) {
        expect(isMpvBridgeCommandAllowed(withoutNewline(command)), isTrue,
            reason: command);
      }
      for (final seconds in [0, 1, 3600, 86399]) {
        expect(
            isMpvBridgeCommandAllowed(withoutNewline(mpvSeekCommand(seconds))),
            isTrue);
      }
    });

    test('refuses anything that could run code or change mpv', () {
      const hostile = [
        '{"command":["run","cmd","/c","calc"]}',
        'run cmd /c calc', // input.conf syntax, which mpv's IPC also accepts
        '{"command":["subprocess",{"args":["calc"]}]}',
        '{"command":["loadfile","https://example.invalid/x.m3u8"]}',
        '{"command":["set_property","pause",true]}',
        '{"command":["quit"]}',
        '{"command":["load-script","C:/evil.lua"]}',
        // A permitted command with a hostile one glued on.
        '{"command":["get_property","pause"],"request_id":2}{"command":["run","calc"]}',
        // Reading a property the app never asks for.
        '{"command":["get_property","path"],"request_id":1}',
        // Non-ASCII digits, which .NET's \d would have admitted.
        '{"command":["seek",١٢٣,"absolute"]}',
        '',
      ];
      for (final line in hostile) {
        expect(isMpvBridgeCommandAllowed(line), isFalse, reason: line);
      }
    });
  });

  group('buildMpvBridgeScript', () {
    final script = buildMpvBridgeScript(port: 8091, pipeName: 'mpv-socket-123');

    test('fills every slot', () {
      expect(script, isNot(contains('@@')));
      expect(script, contains('Loopback, 8091)'));
      expect(script, contains("'mpv-socket-123'"));
      expect(script, contains(r'$env:' + mpvBridgeTokenVariable));
    });

    test('enforces exactly the Dart-side allowlist', () {
      for (final pattern in mpvBridgeAllowedCommandPatterns) {
        expect(script, contains("'$pattern'"));
      }
    });

    test('has no bare WaitAny left to print into stdout', () {
      // The wedge: PowerShell writes an uncaptured expression's value to
      // stdout. The relay no longer waits on tasks this way at all.
      expect(script, isNot(contains('WaitAny')));
    });
  });

  group('encodePowerShellCommand', () {
    test('is base64 of the UTF-16LE text', () {
      const text = "Write-Output 'héllo \"world\"' # ✓";
      final bytes = base64.decode(encodePowerShellCommand(text));
      final units = [
        for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
      ];
      expect(String.fromCharCodes(units), text);
    });
  });

  // The real relay, driven by the same client code the tracker and the seek
  // path use, against a fake mpv: one PowerShell process serving the named
  // pipe the way mpv does, and recording every line that reaches it.
  group('the running bridge', () {
    late Directory temp;
    late File mpvLog;
    late Process fakeMpv;
    late Process bridge;
    late int port;
    final bridgeOutput = <String>[];
    const token = '0123456789abcdef0123456789abcdef';

    Future<String> exchange(List<String> commands, {String? withToken}) {
      return PlayerService.exchangeWithMpv(
        () => Socket.connect('127.0.0.1', port,
            timeout: const Duration(seconds: 2)),
        commands: commands,
        bridgeToken: withToken ?? token,
        isComplete: mpvRepliesComplete,
        timeout: const Duration(seconds: 3),
      );
    }

    List<String> linesSeenByMpv() =>
        mpvLog.existsSync() ? mpvLog.readAsLinesSync() : const [];

    setUpAll(() async {
      temp = Directory.systemTemp.createTempSync('streamlink_gui_mpvbridge_');
      mpvLog = File('${temp.path}${Platform.pathSeparator}mpv.log');
      final pipeName = mpvPipeName('test-$pid');

      final fakeScript = File('${temp.path}${Platform.pathSeparator}fake_mpv.ps1')
        ..writeAsStringSync(_fakeMpvScript);
      fakeMpv = await Process.start('powershell', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', fakeScript.path, '-PipeName', pipeName, '-LogPath', mpvLog.path,
      ]);
      fakeMpv.stdout.drain<void>();
      fakeMpv.stderr.drain<void>();

      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();

      bridge = await PlayerService.startMpvPipeBridge(
        port: port,
        pipeName: pipeName,
        token: token,
        onOutput: bridgeOutput.add,
      );

      // PowerShell takes a moment to start listening.
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        try {
          (await Socket.connect('127.0.0.1', port)).destroy();
          break;
        } catch (_) {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    tearDownAll(() async {
      // These are the test's own children, ended by the pids it holds.
      await Process.run('taskkill',
          ['/F', '/T', '/PID', '${bridge.pid}', '/PID', '${fakeMpv.pid}']);
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('answers the tracker\'s status poll', () async {
      final status = parseMpvStatus(await exchange(mpvStatusCommands()));
      expect(status, isNotNull);
      expect(status!.positionSeconds, 43); // 42.5 from the fake, rounded
      expect(status.activity, PlayerActivity.playing);
      expect(status.eofReached, isFalse);
    });

    test('keeps serving well past the point its predecessor wedged', () async {
      // The old relay stopped at exchange ~340. Nothing in this one prints,
      // and whatever did would be drained into the log.
      for (var i = 0; i < 400; i++) {
        final replies = await exchange(mpvStatusCommands());
        expect(mpvRepliesComplete(replies), isTrue, reason: 'exchange $i');
      }
      expect(bridgeOutput, isEmpty);
    });

    test('relays a seek', () async {
      final replies = await exchange([mpvSeekCommand(120)]);
      expect(replies, contains('"error":"success"'));
      expect(linesSeenByMpv(), contains(withoutNewline(mpvSeekCommand(120))));
    });

    test('never lets an unlisted command reach mpv', () async {
      expect(await exchange(['{"command":["run","cmd","/c","calc"]}\n']),
          isEmpty);
      // Only the permitted half of a mixed request is passed on.
      final mixed = await exchange([
        '{"command":["run","calc"]}\n',
        mpvStatusCommands().first,
      ]);
      expect(mixed, contains('"request_id":1'));

      final seen = linesSeenByMpv();
      expect(seen.where((l) => l.contains('run')), isEmpty);
      expect(seen.every(isMpvBridgeCommandAllowed), isTrue);
    });

    test('drops a client that does not know the session token', () async {
      final before = linesSeenByMpv().length;

      expect(await exchange(mpvStatusCommands(), withToken: 'not-the-token'),
          isEmpty);

      // What a web page's no-cors POST to the port looks like on the wire.
      final browser = await Socket.connect('127.0.0.1', port);
      browser.write('POST / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'
          '{"command":["get_property","pause"],"request_id":2}\n');
      await browser.flush();
      await browser.drain<void>().timeout(const Duration(seconds: 3),
          onTimeout: () {});
      browser.destroy();

      // The relay is sequential: once a good exchange has been answered, any
      // line from the two above would already have been logged.
      expect(mpvRepliesComplete(await exchange(mpvStatusCommands())), isTrue);
      expect(linesSeenByMpv().length, before + mpvStatusCommands().length);
    });
  }, skip: Platform.isWindows ? false : 'the bridge exists only on Windows');
}

/// Stands in for mpv's JSON IPC server: one client at a time, one reply per
/// line - after an unsolicited event, as real mpv interleaves them - and every
/// received line appended to the log.
const String _fakeMpvScript = r'''
param([string]$PipeName, [string]$LogPath)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
while ($true) {
  $server = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1)
  try {
    $server.WaitForConnection()
    $reader = New-Object System.IO.StreamReader($server, $utf8)
    $writer = New-Object System.IO.StreamWriter($server, $utf8)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    while ($null -ne ($line = $reader.ReadLine())) {
      [System.IO.File]::AppendAllText($LogPath, $line + "`n")
      $id = 0
      if ($line -match '"request_id":([0-9]+)') { $id = [int]$Matches[1] }
      $data = 'null'
      if ($id -eq 1) { $data = '42.5' } elseif ($id -eq 2 -or $id -eq 3) { $data = 'false' }
      $writer.WriteLine('{"event":"playback-restart"}')
      $writer.WriteLine('{"data":' + $data + ',"request_id":' + $id + ',"error":"success"}')
    }
  } catch {
  } finally {
    $server.Dispose()
  }
}
''';
