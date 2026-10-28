import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log_store.dart';

/// A small file of what went wrong, beside the config.
///
/// A release build has no console, so before this an uncaught error went
/// nowhere at all: the invisible-window bug and the exit crash left nothing on
/// disk to diagnose, and every report started from "it just does not show".
/// This records uncaught errors from all three places Flutter can surface
/// them (the framework, the platform dispatcher, the root zone) plus a
/// handful of startup milestones - config loaded, surface engine, window
/// placement, first frame, what the window looked like a moment later - so
/// the next startup failure leaves evidence of how far it got.
///
/// Small on purpose. Each launch writes about a dozen lines; the file rotates
/// at [maxBytes] to one previous copy, so it can never grow without bound.
/// Lines go through [redactCredentials], since an error message can quote a
/// request header.
class CrashLog {
  CrashLog(this.file, {this.maxBytes = 256 * 1024, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const String fileName = 'crash.log';

  /// The log for this process, once [install]ed.
  static CrashLog? current;

  final File file;

  /// Size at which the file is rotated to `crash.log.1`, replacing any older
  /// copy.
  final int maxBytes;

  final DateTime Function() _clock;

  /// Bytes in [file], known after the first write; avoids a stat per line.
  int? _size;

  /// The previous copy, kept through one rotation.
  File get previous => File('${file.path}.1');

  /// Records [message] as a milestone. Never throws: logging must not be
  /// the thing that stops the app.
  void milestone(String message) => _write('$message\n', flush: false);

  /// Records an uncaught error. Flushed to disk at once, since the process
  /// may be about to die.
  void error(String source, Object error, StackTrace? stack) {
    final trace = stack == null
        ? ''
        : '\n${stack.toString().trimRight().split('\n').take(40).map((l) => '    $l').join('\n')}';
    _write('ERROR [$source] $error$trace\n', flush: true);
  }

  void _write(String text, {required bool flush}) {
    try {
      final line = '${_clock().toIso8601String()} ${redactCredentials(text)}';
      _rotateIfFull(line.length);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(line, mode: FileMode.append, flush: flush);
      _size = (_size ?? 0) + line.length;
    } catch (_) {
      // A read-only or vanished folder: nothing useful to do about it here.
    }
    if (kDebugMode) debugPrint(text.trimRight());
  }

  void _rotateIfFull(int incoming) {
    _size ??= file.existsSync() ? file.lengthSync() : 0;
    if (_size! + incoming <= maxBytes || _size == 0) return;
    try {
      if (previous.existsSync()) previous.deleteSync();
      file.renameSync(previous.path);
    } catch (_) {
      // Locked by an editor: truncate instead, so it still cannot grow.
      try {
        file.writeAsStringSync('');
      } catch (_) {}
    }
    _size = 0;
  }

  /// Routes every uncaught error into [log] and makes it [current].
  ///
  /// The framework's own reporting still runs - in debug that is the red
  /// screen and the console dump this does not replace - and the platform
  /// dispatcher's errors are marked handled, so one bad callback is logged
  /// rather than taking the isolate down.
  static void install(CrashLog log) {
    current = log;
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      log.error(
          details.library ?? 'flutter', details.exception, details.stack);
      if (previousOnError != null) {
        previousOnError(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log.error('platform', error, stack);
      return true;
    };
  }
}

/// Milestones of one operation in several steps, each with the time since
/// it began: `[exit] saved (+412ms)`.
///
/// For the exit, which logged only its first and last line. One exit was
/// seen to take 6.9s where the rest took under one, and nothing in between
/// said which step - the players, the saves or the tray - held it up.
class TimedMilestones {
  TimedMilestones(this.tag, this.log, {Stopwatch? stopwatch})
      : _watch = (stopwatch ?? Stopwatch())..start();

  /// Goes in brackets at the start of every line, as `[tag]`.
  final String tag;

  /// Where the lines go; null writes nothing.
  final CrashLog? log;

  final Stopwatch _watch;

  /// Records [step], with the milliseconds since this was created.
  void mark(String step) =>
      log?.milestone('[$tag] $step (+${_watch.elapsedMilliseconds}ms)');
}
