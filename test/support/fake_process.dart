import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A child process the test controls: what it prints, when, and how it ends.
///
/// Handed to `PlayerService(startProcess: ...)`, it lets the service's real
/// launch, output-parsing and exit handling run without starting streamlink,
/// yt-dlp or a player.
class FakeProcess implements Process {
  FakeProcess(this.executable, this.arguments, {required this.pid});

  final String executable;
  final List<String> arguments;

  @override
  final int pid;

  final StreamController<List<int>> _stdout = StreamController();
  final StreamController<List<int>> _stderr = StreamController();
  final Completer<int> _exit = Completer();

  /// How many times the service called [kill].
  int killCount = 0;

  bool get hasExited => _exit.isCompleted;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Future<int> get exitCode => _exit.future;

  /// One pipe read's worth of output, exactly as given - no line framing.
  void printOut(String chunk) => _stdout.add(utf8.encode(chunk));
  void printErr(String chunk) => _stderr.add(utf8.encode(chunk));

  /// Ends the process. Output already printed is delivered first, as the
  /// service's listeners would see it from a real child.
  Future<void> exit(int code) async {
    if (_exit.isCompleted) return;
    _stdout.close();
    _stderr.close();
    await Future<void>.delayed(Duration.zero);
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCount++;
    exit(-1);
    return true;
  }
}

/// Stands in for taskkill: records each call and ends the [FakeProcess]es it
/// names, the way the real one would.
class FakeTaskkill {
  FakeTaskkill(this.launcher);

  final FakeLauncher launcher;
  final List<List<String>> calls = [];

  /// Whether a graceful (no `/F`) call ends its targets. Players with a window
  /// close on the WM_CLOSE it posts; console programs ignore it.
  bool gracefulEndsTargets = false;

  /// What taskkill exits with.
  int exitCode = 0;
  String stderr = '';

  /// How long each call takes before it ends anything. The real one starts a
  /// process and walks the process table, routinely a few hundred ms.
  Duration delay = Duration.zero;

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add(arguments);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (arguments.contains('/F') || gracefulEndsTargets) {
      for (var i = 0; i < arguments.length - 1; i++) {
        if (arguments[i] != '/PID') continue;
        final pid = int.parse(arguments[i + 1]);
        for (final p in launcher.launched.where((p) => p.pid == pid)) {
          await p.exit(1); // taskkill'd processes exit non-zero
        }
      }
    }
    return ProcessResult(0, exitCode, '', stderr);
  }
}

/// Records every launch and hands back a [FakeProcess] for each.
class FakeLauncher {
  final List<FakeProcess> launched = [];

  // Odd on purpose: Windows pids are multiples of four, so a fake one can
  // never name a real process, even if some path reached a real taskkill.
  var _nextPid = 900001;

  /// How long each start takes before the process exists. A real start is a
  /// CreateProcess plus whatever the child does before Dart hears back.
  Duration startDelay = Duration.zero;

  /// When set, each start waits for it before the process exists, and
  /// [starting] counts the starts held there.
  Completer<void>? startGate;
  int starting = 0;

  Future<Process> start(String executable, List<String> arguments,
      {Map<String, String>? environment}) async {
    if (startDelay > Duration.zero) await Future<void>.delayed(startDelay);
    final gate = startGate;
    if (gate != null) {
      starting++;
      try {
        await gate.future;
      } finally {
        starting--;
      }
    }
    final p = FakeProcess(executable, arguments, pid: _nextPid);
    _nextPid += 2;
    launched.add(p);
    return p;
  }
}
