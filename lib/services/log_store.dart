import 'package:flutter/foundation.dart';

/// One process's log session — a download, a stream, or a player.
class LogSession {
  LogSession({
    required this.key,
    required this.label,
    required this.startedAt,
    this.exitCode,
  });

  /// `dl-<vodId>` | `<vodId>` | `stream_<channel>`
  final String key;

  /// Human label, e.g. "Download: Some VOD" or "shroud (Live)".
  final String label;

  final DateTime startedAt;

  /// Null while the process is still running.
  int? exitCode;

  bool get isRunning => exitCode == null;
  bool get failed => exitCode != null && exitCode != 0;
}

/// Buffered process output plus the session metadata describing it.
///
/// This used to be the console drawer's private state, where the only way a
/// session was ever forgotten was the user closing its tab by hand. With the
/// drawer gone, the store prunes itself: buffers are capped per session and
/// the session count is capped overall.
class LogNotifier extends ChangeNotifier {
  LogNotifier({this.maxLines = 1000, this.maxSessions = 20});

  /// Lines retained per session.
  final int maxLines;

  /// Sessions retained. Finished ones are evicted oldest-first; a running
  /// session is never evicted, however old it is.
  final int maxSessions;

  final Map<String, List<String>> _logs = {};
  final Map<String, LogSession> _sessions = {};

  List<String> getLogs(String key) => _logs[key] ?? const [];

  /// Newest first.
  List<LogSession> get sessions {
    final list = _sessions.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list;
  }

  LogSession? session(String key) => _sessions[key];

  bool get isEmpty => _sessions.isEmpty && _logs.isEmpty;

  void appendLog(String key, String line) {
    final list = _logs.putIfAbsent(key, () => []);
    list.add(line);
    if (list.length > maxLines) {
      list.removeRange(0, list.length - maxLines);
    }
    notifyListeners();
  }

  /// Registers a session and reclaims space from old finished ones.
  void beginSession(String key, String label) {
    _sessions[key] = LogSession(
      key: key,
      label: label,
      startedAt: DateTime.now(),
    );
    // A restarted key begins a fresh session, so drop the previous output
    // rather than appending to it.
    _logs.remove(key);
    _evict();
    notifyListeners();
  }

  void endSession(String key, int exitCode) {
    final session = _sessions[key];
    if (session == null || !session.isRunning) return;
    session.exitCode = exitCode;
    // Eviction skips running sessions, so a session only becomes reclaimable
    // once it ends - which is why this runs here rather than only at begin.
    _evict();
    notifyListeners();
  }

  /// Ends every session still marked running.
  ///
  /// For the paths that kill all child processes at once without the app
  /// exiting - a failed update, most notably.
  void endAllRunning(int exitCode) {
    var changed = false;
    for (final session in _sessions.values) {
      if (!session.isRunning) continue;
      session.exitCode = exitCode;
      changed = true;
    }
    if (!changed) return;
    _evict();
    notifyListeners();
  }

  void clear(String key) {
    _logs[key]?.clear();
    notifyListeners();
  }

  void removeKey(String key) {
    _logs.remove(key);
    _sessions.remove(key);
    notifyListeners();
  }

  void clearAll() {
    _logs.clear();
    _sessions.clear();
    notifyListeners();
  }

  void _evict() {
    if (_sessions.length <= maxSessions) return;
    final finished = _sessions.values.where((s) => !s.isRunning).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    var over = _sessions.length - maxSessions;
    for (final s in finished) {
      if (over <= 0) break;
      _sessions.remove(s.key);
      _logs.remove(s.key);
      over--;
    }
  }
}
