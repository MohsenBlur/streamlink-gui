import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/mpc_slave_protocol.dart';

/// What no behavioural test can see: that nothing in the app turns on
/// MPC-HC's web interface or writes MPC-HC's settings, and that the runner's
/// /slave receiver (windows/runner/mpc_slave.cpp) keeps its guards. The
/// runner's C++ has no tests of its own here, so its source is read, as the
/// other runner checks do.
void main() {
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  Iterable<File> sources(String dir, List<String> extensions) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => extensions.any(f.path.endsWith));

  final appSources = [
    ...sources('lib', ['.dart']),
    ...sources('windows/runner', ['.cpp', '.h']),
  ];

  /// [source] without its comments, so a comment explaining why something is
  /// gone does not count as it being there.
  String code(String source) => source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .split('\n')
      .map((line) {
        final comment = line.indexOf('//');
        return comment < 0 ? line : line.substring(0, comment);
      })
      .join('\n');

  test("nothing turns on MPC-HC's web interface", () {
    // It has no authentication: while a VOD played, any web page could
    // drive the player with a plain GET - /browser.html?path=\\host\share
    // hands the account's NTLM hash to whoever serves the share.
    for (final file in appSources) {
      final text = code(read(file.path)).toLowerCase();
      for (final banned in ['webport', 'variables.html', 'command.html']) {
        expect(text, isNot(contains(banned)),
            reason: '${file.path} mentions $banned outside a comment');
      }
    }
  });

  test("nothing writes MPC-HC's settings", () {
    // The app used to set WebServerLocalhostOnly=1 in the user's MPC-HC
    // settings (the registry, or the .ini beside its exe) before every
    // launch, and never put it back.
    for (final file in appSources) {
      final text = code(read(file.path));
      expect(text.toLowerCase(), isNot(contains('webserverlocalhostonly')),
          reason: file.path);
      expect(text, isNot(contains(r'Software\MPC-HC')), reason: file.path);
      expect(text, isNot(contains(r'Software\\MPC-HC')), reason: file.path);
      expect(text, isNot(contains('mpc-hc64.ini')), reason: file.path);
    }
    // The startup Run key is the app's only registry write, and not here.
    for (final path in [
      'lib/services/player_service.dart',
      'lib/services/mpc_slave.dart',
      'lib/utils/player_args.dart',
      'lib/utils/mpc_slave_protocol.dart',
    ]) {
      expect(code(read(path)), isNot(contains("'reg'")), reason: path);
      expect(code(read(path)), isNot(contains('.ini')), reason: path);
    }
    final receiver = code(read('windows/runner/mpc_slave.cpp'));
    for (final api in ['RegSetValue', 'RegCreateKey', 'WritePrivateProfile']) {
      expect(receiver, isNot(contains(api)));
    }
  });

  group('the runner receiver', () {
    final header = read('windows/runner/mpc_slave.h');
    final source = code(read('windows/runner/mpc_slave.cpp'));

    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNonNegative, reason: signature);
      return source.substring(start, source.indexOf('\n}\n', start));
    }

    test("speaks the same command ids as Dart's MpcCommand", () {
      int id(String name) {
        final match = RegExp('constexpr ULONG_PTR $name = (0x[0-9A-Fa-f]+);')
            .firstMatch(header);
        expect(match, isNotNull, reason: name);
        return int.parse(match!.group(1)!.substring(2), radix: 16);
      }

      expect(id('kConnect'), MpcCommand.connect);
      expect(id('kState'), MpcCommand.state);
      expect(id('kPlayMode'), MpcCommand.playMode);
      expect(id('kNowPlaying'), MpcCommand.nowPlaying);
      expect(id('kCurrentPosition'), MpcCommand.currentPosition);
      expect(id('kNotifySeek'), MpcCommand.notifySeek);
      expect(id('kNotifyEndOfStream'), MpcCommand.notifyEndOfStream);
      expect(id('kVersion'), MpcCommand.version);
      expect(id('kDisconnect'), MpcCommand.disconnect);
      expect(id('kSetPosition'), MpcCommand.setPosition);
      expect(id('kGetNowPlaying'), MpcCommand.getNowPlaying);
      expect(id('kGetCurrentPosition'), MpcCommand.getCurrentPosition);
      expect(id('kCloseApp'), MpcCommand.closeApp);
    });

    test('listens on message-only windows, open to no lower integrity', () {
      expect(body('HWND CreateMessageWindow('), contains('HWND_MESSAGE'));
      // UIPI keeps a lower-integrity process - a sandboxed browser among
      // them - from sending WM_COPYDATA here. Nothing may undo that.
      expect(source, isNot(contains('ChangeWindowMessageFilter')));
    });

    test('judges every message by the window that sent it', () {
      final onCopyData = body('bool Sessions::OnCopyData(');
      expect(onCopyData, contains('WindowProcess(sender)'));
      expect(onCopyData, contains('IsPlayerNotification(command)'));
      expect(onCopyData, contains('ReadPayload(data)'));
      expect(onCopyData, contains('session.root == nullptr'),
          reason: 'held until the launch is bound, not accepted');
      expect(body('DWORD WindowProcess('), contains('GetWindowThreadProcessId'));
    });

    test('takes a connect only from a process this session launched', () {
      final accept = body('bool Sessions::Accept(');
      expect(accept, contains('command == kConnect'));
      expect(accept, contains('DescendsFrom(sender_pid, session.root)'));
      expect(accept, contains('*player_window != sender_window'));
      // ...and everything after it only from that window of that process.
      expect(accept, contains('sender_pid != session.player_pid'));
      expect(accept, contains('sender_window != session.player_window'));
    });

    test('a reused process id cannot pass for a parent', () {
      final descends = body('bool DescendsFrom(');
      expect(descends, contains('CompareFileTime(&parent_created, &current_created) > 0'));
      expect(body('bool Sessions::Bind('), contains('SYNCHRONIZE'),
          reason: 'the launched process is held open, so its id stays its own');
    });

    test('sends only what the app asks, off the UI thread', () {
      final hostCommands = body('bool IsHostCommand(');
      for (final allowed in [
        'kSetPosition',
        'kGetNowPlaying',
        'kGetCurrentPosition',
        'kCloseApp',
      ]) {
        expect(hostCommands, contains('case $allowed:'));
      }
      expect(RegExp('case ').allMatches(hostCommands), hasLength(4),
          reason: 'never CMD_OPENFILE or CMD_ADDTOPLAYLIST');
      final send = body('void Sessions::Send(');
      expect(send, contains('IsHostCommand(command)'));
      expect(send, contains('std::thread('));
      expect(send, contains('SendMessageTimeoutW('));
      expect(send, contains('SMTO_ABORTIFHUNG'));
    });

    test('is torn down with the engine, before its controller', () {
      final window = read('windows/runner/flutter_window.cpp');
      final onDestroy = window.substring(
          window.indexOf('void FlutterWindow::OnDestroy()'));
      expect(onDestroy.indexOf('mpc_slave_channel_ = nullptr;'),
          lessThan(onDestroy.indexOf('controller.reset();')));
      expect(read('windows/runner/mpc_slave_channel.cpp'),
          contains('"streamlink_gui/mpc_slave"'));
      expect(read('lib/services/mpc_slave.dart'),
          contains("MethodChannel('streamlink_gui/mpc_slave')"));
      expect(read('windows/runner/CMakeLists.txt'),
          allOf(contains('"mpc_slave.cpp"'), contains('"mpc_slave_channel.cpp"')));
    });
  });
}
