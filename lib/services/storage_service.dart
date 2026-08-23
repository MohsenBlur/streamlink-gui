import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';

/// The most recent failed save, or null when the last save succeeded.
final ValueNotifier<StorageWriteFailure?> storageWriteFailure =
    ValueNotifier<StorageWriteFailure?>(null);

/// A save that did not reach disk.
class StorageWriteFailure {
  StorageWriteFailure(this.path, this.error, this.at);

  final String path;
  final Object error;
  final DateTime at;

  @override
  String toString() => '$path: $error';
}

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

  /// The most recent save failure, or null when the last save succeeded.
  ///
  /// Deliberately a notifier rather than a return value: `write()` has ~30
  /// fire-and-forget callers, so completing with an error would turn every one
  /// of them into an unhandled async error. Reporting through state instead
  /// means the UI can show a banner for as long as the condition lasts, and
  /// stop showing it the moment a save succeeds.
  static final ValueNotifier<StorageWriteFailure?> writeFailure =
      storageWriteFailure;

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
          writeFailure.value = null;
        } catch (e) {
          // Retry once. The common Windows cause is a transient lock from an
          // antivirus scanner, the search indexer or a sync client, which
          // clears in well under a second - and reporting those would make the
          // warning meaningless.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          try {
            await _writeAtomic(data);
            writeFailure.value = null;
          } catch (e2) {
            writeFailure.value =
                StorageWriteFailure(file.path, e2, DateTime.now());
          }
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

  /// Whether a config file is present, regardless of whether it can be parsed.
  ///
  /// `loadConfig` returns null both for "no config" and for "config was
  /// unreadable and has been quarantined", and treating the second as a first
  /// run showed the onboarding wizard to an existing user whose file had been
  /// corrupted.
  bool configExists() {
    try {
      return _getStorageFile().existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Moves an unreadable config aside so it is not silently overwritten by the
  /// next autosave, and can still be recovered by hand.
  void _quarantineCorruptFile(File file) {
    try {
      if (!file.existsSync()) return;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      file.renameSync('${file.path}.corrupt-$stamp');
    } catch (_) {}
    _pruneQuarantine(file);
  }

  /// Keeps only the newest few quarantined copies.
  ///
  /// Each one is a complete config including OAuth tokens, so they should not
  /// accumulate indefinitely on disk.
  static const int _maxQuarantineFiles = 3;

  void _pruneQuarantine(File file) {
    try {
      final name = p.basename(file.path);
      final dir = file.parent;
      if (!dir.existsSync()) return;
      final copies = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('$name.corrupt-'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path)); // timestamp-suffixed
      for (final stale in copies.skip(_maxQuarantineFiles)) {
        try {
          stale.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Removes temp files orphaned by a crash between write and rename.
  ///
  /// `_writeAtomic` deletes its own temp on a failed write, so anything left
  /// behind is from a process that died mid-save - which the self-updater makes
  /// a routine event. Only files matching the exact `<name>.<digits>.tmp` shape
  /// are considered, and only once they are old enough that no live writer
  /// could still own them.
  static const Duration _tempFileGrace = Duration(hours: 1);

  void sweepTempFiles(File file) {
    try {
      final name = p.basename(file.path);
      final dir = file.parent;
      if (!dir.existsSync()) return;
      final pattern = RegExp('^' + RegExp.escape(name) + r'\.\d+\.tmp$');
      final now = DateTime.now();
      for (final entry in dir.listSync().whereType<File>()) {
        if (!pattern.hasMatch(p.basename(entry.path))) continue;
        try {
          if (now.difference(entry.statSync().modified) < _tempFileGrace) {
            continue;
          }
          entry.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadConfig() async {
    final file = _getStorageFile();
    sweepTempFiles(file);
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
