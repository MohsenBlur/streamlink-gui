import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';

/// Serializes and coalesces writes to a single file.
///
/// Two problems this solves:
///  * Concurrent writers previously shared one `<file>.tmp` path, so one call
///    could rename the temp away while another was still writing it.
///  * Watch-progress ticks trigger a full config save roughly twice a second
///    per playing VOD, so bursts of redundant writes pile up.
///
/// Only the most recent content is ever written: if newer content arrives while
/// a write is in flight, the intermediate snapshot is dropped rather than
/// queued, since every write is a complete snapshot anyway.
class _SerialFileWriter {
  _SerialFileWriter(this.file);

  final File file;
  String? _pending;
  Future<void>? _running;
  Object? lastError;

  Future<void> write(String content) {
    _pending = content;
    _running ??= _drain();
    return _running!;
  }

  Future<void> _drain() async {
    try {
      // No await between the loop test and clearing `_running` below, so a
      // concurrent write() can never be lost between iterations.
      while (_pending != null) {
        final data = _pending!;
        _pending = null;
        try {
          await _writeAtomic(data);
          lastError = null;
        } catch (e) {
          lastError = e;
        }
      }
    } finally {
      _running = null;
    }
  }

  /// Writes via a uniquely-named temp file and a single atomic rename.
  ///
  /// The previous implementation wrote a temp file, then DELETED the real file,
  /// then renamed. A crash, power loss or process kill in that window - which
  /// every self-update triggers - left no config at all, losing every channel,
  /// all settings, the OAuth tokens and the watch history. `File.rename`
  /// replaces the destination atomically (MoveFileEx with
  /// MOVEFILE_REPLACE_EXISTING on Windows), so the delete was never needed.
  Future<void> _writeAtomic(String content) async {
    final dir = file.parent;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(file.path);
    } catch (_) {
      // Best-effort fallback: a direct write is not atomic, but losing the
      // update is worse than a narrow torn-write window.
      try {
        await file.writeAsString(content, flush: true);
      } finally {
        if (await temp.exists()) {
          try {
            await temp.delete();
          } catch (_) {}
        }
      }
      rethrow;
    }
  }
}

class StorageService {
  /// Keyed by absolute path and static, because several StorageService
  /// instances exist (main and the player service each construct their own)
  /// and they must not write the same file concurrently.
  static final Map<String, _SerialFileWriter> _writers = {};

  static _SerialFileWriter _writerFor(File file) {
    return _writers.putIfAbsent(file.path, () => _SerialFileWriter(file));
  }

  /// True when running under `flutter test` / `dart test`, where the resolved
  /// executable is the test runner rather than the app.
  ///
  /// Matched on the executable's file name: the previous check looked for the
  /// substring 'dart' anywhere in the full path, so any user whose profile
  /// path happened to contain it (for example `C:\Users\bernardart`) had their
  /// config silently written to the working directory instead.
  static bool get _isTestRunner {
    try {
      final exeName = p.basename(Platform.resolvedExecutable).toLowerCase();
      return exeName == 'dart.exe' ||
          exeName == 'dart' ||
          exeName.startsWith('flutter_tester') ||
          exeName.startsWith('flutter_tools');
    } catch (_) {
      return false;
    }
  }

  /// Forces all storage into a specific directory. Used by tests; leave null in
  /// the app so the normal AppData / portable resolution applies.
  static String? storageDirectoryOverride;

  File getStorageFile(String filename) {
    try {
      final override = storageDirectoryOverride;
      if (override != null) {
        return File(p.join(override, filename));
      }
      if (_isTestRunner) {
        return File(filename);
      }

      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final exeFile = File(p.join(exeDir, filename));

      // Explicit opt-in to portable mode: config lives beside the executable.
      final portableMarker = File(p.join(exeDir, 'portable.txt'));
      if (portableMarker.existsSync()) {
        return exeFile;
      }

      String? appDataDir;
      if (Platform.isWindows) {
        appDataDir = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'];
      } else if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          appDataDir = p.join(home, 'Library', 'Application Support');
        }
      } else if (Platform.isLinux) {
        appDataDir = Platform.environment['XDG_CONFIG_HOME'];
        if (appDataDir == null || appDataDir.isEmpty) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            appDataDir = p.join(home, '.config');
          }
        }
      }

      if (appDataDir != null && appDataDir.isNotEmpty) {
        final configDir = Directory(p.join(appDataDir, 'TwitchStreamlinkGUI'));
        final appDataFile = File(p.join(configDir.path, filename));

        if (!appDataFile.existsSync()) {
          try {
            if (!configDir.existsSync()) {
              configDir.createSync(recursive: true);
            }
            // One-time migration of a pre-AppData config living next to the exe.
            if (exeFile.existsSync()) {
              exeFile.copySync(appDataFile.path);
            }
          } catch (_) {}
        }
        return appDataFile;
      }

      return exeFile;
    } catch (_) {
      return File(filename);
    }
  }

  File _getStorageFile() {
    return getStorageFile('channels_config.json');
  }

  /// Moves an unreadable config aside so it is not silently overwritten by the
  /// next autosave, and can still be recovered by hand.
  void _quarantineCorruptFile(File file) {
    try {
      if (!file.existsSync()) return;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      file.renameSync('${file.path}.corrupt-$stamp');
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadConfig() async {
    final file = _getStorageFile();
    try {
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      final decoded = json.decode(content);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      _quarantineCorruptFile(file);
    } catch (_) {
      // Unreadable or invalid JSON: preserve it rather than letting the app
      // start from defaults and immediately autosave over the user's data.
      _quarantineCorruptFile(file);
    }
    return null;
  }

  Future<void> saveConfig(
    List<TwitchChannel> channels,
    AppSettings settings,
    Map<String, int> localProgress,
    Map<String, String> downloadedVods,
  ) async {
    final file = _getStorageFile();
    final config = {
      'channels': channels.map((c) => c.toJson()).toList(),
      'settings': settings.toJson(),
      'local_vods_progress': localProgress,
      'downloaded_vods': downloadedVods,
    };
    await _writerFor(file).write(json.encode(config));

    // NOTE: this used to also mirror the whole config next to the executable on
    // every save. That wrote the Twitch OAuth token and the browser auth token
    // into the install directory even for non-portable installs, from where the
    // updater's backup copied them into %TEMP% (and, during an elevated update,
    // into another user's profile). Portable installs are already served by the
    // portable.txt branch in getStorageFile.
  }

  Future<List<Map<String, dynamic>>> loadRecentWatchedVods() async {
    final file = getStorageFile('recent_watched_vods.json');
    try {
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      if (content.trim().isEmpty) return [];

      final decoded = json.decode(content);
      if (decoded is List) {
        return decoded.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
      }
      _quarantineCorruptFile(file);
    } catch (_) {
      _quarantineCorruptFile(file);
    }
    return [];
  }

  Future<void> saveRecentWatchedVods(List<Map<String, dynamic>> list) async {
    final file = getStorageFile('recent_watched_vods.json');
    await _writerFor(file).write(json.encode(list));
  }
}
