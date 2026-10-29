import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import 'config_secrets.dart';

/// The most recent failed save, or null when the last save succeeded.
final ValueNotifier<StorageWriteFailure?> storageWriteFailure =
    ValueNotifier<StorageWriteFailure?>(null);

/// The first of the app's files found present but unreadable this session,
/// or null when every one read.
final ValueNotifier<StorageReadFailure?> storageReadFailure =
    ValueNotifier<StorageReadFailure?>(null);

/// A file that is there but could not be read: held open by another program
/// that shares no reading (a backup or sync client), on a share that is out
/// of reach for a moment, or damaged and impossible to move aside.
///
/// Not "nothing to lose". Reading it as damage, or as no file, started the
/// app from defaults, and the next save replaced the user's channels,
/// settings, tokens, registry and history - or every furthest point and
/// undo trail - with nothing left to recover. What it holds was never
/// loaded, so nothing may be written over it this session.
class StorageReadFailure implements Exception {
  StorageReadFailure(this.path, this.error);

  final String path;
  final Object error;

  @override
  String toString() => '$path: $error';
}

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
  ///
  /// The real file is only ever replaced by that rename, never written in
  /// place. A failure here used to fall back to writing it directly, which
  /// opens it with truncation first: on a full disk the temp write failed,
  /// the fallback emptied the config and then failed too, `loadConfig` read
  /// the empty file as "no config", and the next autosave made the loss
  /// permanent. The rename failure the fallback was aimed at (a destination
  /// held open by a scanner or a sync client) refuses a direct write on the
  /// same lock anyway. A failed write now leaves the last good file exactly
  /// as it was; `_drain` retries it once and reports it if it persists.
  Future<void> _writeAtomic(String content) async {
    final dir = file.parent;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final override = StorageService.tempPathOverride;
    final temp = File(override != null
        ? override(file.path)
        : '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(file.path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
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

  /// Chooses the temp file a save writes before its rename, given the real
  /// file's path. Used by tests to make that write fail the way a full disk
  /// does; leave null in the app.
  static String Function(String targetPath)? tempPathOverride;

  /// Seals the account tokens at rest; see [ConfigSecrets].
  ///
  /// Static for the same reason as [_writers]: main and the player service
  /// each construct their own instance, and both save the config.
  static ConfigSecrets _secrets = ConfigSecrets(platformCipher(
    isWindows: Platform.isWindows,
    isTestRunner: _isTestRunner,
  ));

  /// DPAPI on Windows. Plaintext elsewhere, and under the test runner, so no
  /// test depends on the account running it; tests that exercise sealing
  /// supply their own cipher through [secretCipher].
  @visibleForTesting
  static SecretCipher? platformCipher({
    required bool isWindows,
    required bool isTestRunner,
  }) =>
      isWindows && !isTestRunner ? const DpapiSecretCipher() : null;

  /// The cipher sealing tokens at rest. Setting it (tests do) starts over,
  /// with nothing remembered from earlier loads.
  static SecretCipher? get secretCipher => _secrets.cipher;
  static set secretCipher(SecretCipher? cipher) =>
      _secrets = ConfigSecrets(cipher);

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

      final appDataPath = _appDataConfigDirectory();
      if (appDataPath != null) {
        final configDir = Directory(appDataPath);
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

  /// The app's folder in the per-user config location (AppData on Windows),
  /// or null where the environment names none. Resolving it creates nothing.
  static String? _appDataConfigDirectory() {
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
    if (appDataDir == null || appDataDir.isEmpty) return null;
    return p.join(appDataDir, 'TwitchStreamlinkGUI');
  }

  static const String _configFileName = 'channels_config.json';

  File _getStorageFile() {
    return getStorageFile(_configFileName);
  }

  /// The folder [scrubStaleConfigMirror] looks in for the mirror. Used by
  /// tests, which run from the test runner's own folder; leave null in the
  /// app, where it is the executable's.
  @visibleForTesting
  static String? exeDirectoryOverride;

  /// Whether this copy keeps its config in AppData, and has one there.
  ///
  /// What makes a `channels_config.json` beside the executable a stale
  /// mirror rather than the config: in a portable copy (portable.txt) that
  /// file IS the config, and with no config in AppData yet it is what
  /// [getStorageFile]'s one-time migration still has to read. Unlike
  /// [getStorageFile] this creates and migrates nothing, so the updater can
  /// ask it at any time.
  bool configLivesInAppData() => _staleMirrorPath() != null;

  /// Where a stale mirror would be, beside the exe; null whenever
  /// [configLivesInAppData] is false.
  File? _staleMirrorPath() {
    try {
      final exeDir = exeDirectoryOverride ??
          (_isTestRunner ? null : File(Platform.resolvedExecutable).parent.path);
      if (exeDir == null) return null;
      if (File(p.join(exeDir, 'portable.txt')).existsSync()) return null;
      final configDir = storageDirectoryOverride ?? _appDataConfigDirectory();
      if (configDir == null) return null;
      final config = File(p.join(configDir, _configFileName));
      final mirror = File(p.join(exeDir, _configFileName));
      // With no AppData folder getStorageFile keeps the config beside the
      // exe, and the "mirror" is then the config itself.
      if (p.equals(p.absolute(config.path), p.absolute(mirror.path))) {
        return null;
      }
      if (!config.existsSync()) return null;
      // So is one the two paths reach by different names - the exe's folder
      // a junction or link to the config's, or either spelled another way
      // (a short name, a mapped drive) - which the comparison above misses:
      // both resolve to where the file really is.
      if (mirror.existsSync() && _sameFile(mirror, config)) return null;
      return mirror;
    } catch (_) {
      return null;
    }
  }

  /// Whether two existing files are one, reached by different paths. False
  /// when that cannot be told, leaving [_staleMirrorPath] to the plain path
  /// comparison.
  static bool _sameFile(File a, File b) {
    try {
      return p.equals(a.resolveSymbolicLinksSync(), b.resolveSymbolicLinksSync());
    } catch (_) {
      return false;
    }
  }

  /// Blanks the tokens in the copy of the config an older build mirrored
  /// beside the executable, keeping the rest of it, and returns a line
  /// saying what it did, for the startup log; null when there was nothing
  /// to do.
  ///
  /// Those builds wrote the whole config there on every save, the OAuth and
  /// browser tokens in plaintext, even for an installed copy (see the NOTE in
  /// [saveConfig]), and nothing reads it again once the config is in AppData.
  /// Scrubbed, not deleted: a portable copy whose portable.txt went missing,
  /// a folder moved or copied without it, looks exactly like this, and there
  /// the file is the user's real config. Deleted, putting portable.txt back
  /// no longer brought its channels and settings back; scrubbed, it costs
  /// one reconnect of the account. Call this only once the config has loaded
  /// from AppData: one that would not load is quarantined, and the next
  /// launch's migration then recovers from this copy. A config that is
  /// portable, or that is this file, is never touched.
  ///
  /// Rewritten through a temp file and a rename, byte for byte apart from
  /// the tokens (see [_decodeAsWritten]), and only when it holds one. It can
  /// only do that where this process may write - a per-user install, not
  /// Program Files, where the updater's elevated step deletes the file
  /// instead (`--drop-config-mirror`, see `UpdateService.updaterArguments`).
  String? scrubStaleConfigMirror() {
    final mirror = _staleMirrorPath();
    if (mirror == null) return null;
    final ({String text, Encoding encoding}) read;
    try {
      if (!mirror.existsSync()) return null;
      read = _decodeAsWritten(mirror.readAsBytesSync());
    } catch (_) {
      return null;
    }
    final scrubbed = ConfigSecrets.blankTokensInText(read.text);
    if (scrubbed == null) return null;

    final temp = File('${mirror.path}.scrubbing');
    var written = false;
    try {
      temp.writeAsBytesSync(read.encoding.encode(scrubbed), flush: true);
      written = true;
      temp.renameSync(mirror.path);
      return 'stale config mirror beside the exe scrubbed, its tokens blanked '
          'and the rest kept: ${mirror.path}';
    } on FileSystemException catch (e) {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {}
      final why = e.osError?.message.trim() ?? e.message;
      // No temp file beside it: the folder is not this process's to write,
      // which is the updater's case. A refused rename is the file's own
      // (read-only, or held open), and the next launch tries again.
      return written
          ? 'stale config mirror beside the exe still holds its tokens, as it '
              'cannot be rewritten ($why): ${mirror.path}'
          : 'stale config mirror beside the exe still holds its tokens, as '
              'this process cannot write that folder ($why); the next update '
              'removes it';
    } catch (_) {
      return null;
    }
  }

  /// [bytes] as text the same bytes can be written back from: UTF-8 when
  /// they are valid UTF-8, and otherwise byte by byte, so whatever made a
  /// file invalid survives a rewrite that only meant to change its tokens.
  static ({String text, Encoding encoding}) _decodeAsWritten(List<int> bytes) {
    try {
      return (text: utf8.decode(bytes), encoding: utf8);
    } on FormatException {
      return (text: latin1.decode(bytes), encoding: latin1);
    }
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

  /// Moves a damaged file aside so it is not silently overwritten by the
  /// next autosave, and can still be recovered by hand.
  ///
  /// Throws [StorageReadFailure] when it is still there afterwards: the move
  /// failed (it is held open, or the folder refuses it), and the next save
  /// would replace it with no copy left anywhere.
  void _quarantineCorruptFile(File file) {
    Object? refused;
    try {
      if (!file.existsSync()) return;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      file.renameSync('${file.path}.corrupt-$stamp');
    } catch (e) {
      refused = e;
    }
    _pruneQuarantine(file);
    if (refused != null) {
      throw _readFailure(file, 'damaged, and could not be moved aside: $refused');
    }
  }

  /// How long a read that failed waits before it is tried again.
  static const Duration _readRetryDelay = Duration(milliseconds: 200);

  /// [file]'s bytes, or null when there is no such file.
  ///
  /// A read that fails is tried twice more, as the writer retries: the usual
  /// cause is a scanner or a sync client holding the file for a moment.
  /// Throws [StorageReadFailure] when it still cannot be read. Only bytes are
  /// read here, so a failure is the file's access and never its content -
  /// readAsString reported text that is not UTF-8 the same way.
  Future<List<int>?> _readPatiently(File file) async {
    Object? error;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) await Future<void>.delayed(_readRetryDelay);
      try {
        if (!await file.exists()) return null;
        return await file.readAsBytes();
      } on FileSystemException catch (e) {
        error = e;
      }
    }
    throw _readFailure(file, error!);
  }

  static StorageReadFailure _readFailure(File file, Object error) {
    final failure = StorageReadFailure(file.path, error);
    storageReadFailure.value ??= failure;
    return failure;
  }

  /// [bytes] as JSON; null when they hold nothing but whitespace. Calls
  /// [damaged] instead when they are not JSON at all.
  static Object? _decodeJson(List<int> bytes,
      {required void Function() damaged}) {
    try {
      final content = utf8.decode(bytes);
      if (content.trim().isEmpty) return null;
      return json.decode(content);
    } catch (_) {
      damaged();
      return null;
    }
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

  /// Reads the config once for the whole startup; see [StartupConfig].
  Future<StartupConfig> loadStartupConfig() async {
    // Existence BEFORE loading: loadConfig() quarantines an unreadable file
    // and returns null, which is indistinguishable from a first run - so a
    // user whose config got corrupted was shown the onboarding wizard.
    final existed = configExists();
    try {
      final data = await loadConfig();
      return StartupConfig(existed: existed, data: data);
    } on StorageReadFailure catch (e) {
      return StartupConfig(existed: true, data: null, readFailure: e);
    }
  }

  /// The decoded config, with its tokens already decrypted, or null when there
  /// is none or it was damaged (and has been quarantined). Throws
  /// [StorageReadFailure] when it is there but could not be read.
  Future<Map<String, dynamic>?> loadConfig() async {
    final file = _getStorageFile();
    sweepTempFiles(file);
    final config = await _readConfig(file);
    // After the read, so a copy it has just quarantined is sealed too.
    await _sealQuarantinedCopies(file);
    return config;
  }

  /// Seals the plaintext tokens in the config's quarantined copies; see
  /// [ConfigSecrets.sealTokensInText].
  ///
  /// Every copy, not only the newest three the pruning keeps: builds from
  /// before the pruning never removed any. Each is rewritten through a temp
  /// file and a rename, and byte for byte apart from the tokens - as UTF-8
  /// when it is valid UTF-8, and otherwise byte by byte, since the damage
  /// that got it quarantined need not be. Nothing to do where nothing can
  /// seal: the config itself then holds the tokens in plaintext too.
  Future<void> _sealQuarantinedCopies(File file) async {
    if (_secrets.cipher == null) return;
    try {
      final prefix = '${p.basename(file.path)}.corrupt-';
      final dir = file.parent;
      if (!await dir.exists()) return;
      final copies = await dir
          .list()
          .where((e) => e is File && p.basename(e.path).startsWith(prefix))
          .cast<File>()
          .toList();
      for (final copy in copies) {
        try {
          final read = _decodeAsWritten(await copy.readAsBytes());
          final sealed = _secrets.sealTokensInText(read.text);
          if (sealed == null) continue;
          final temp = File('${copy.path}.sealing');
          await temp.writeAsBytes(read.encoding.encode(sealed), flush: true);
          await temp.rename(copy.path);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Throws [StorageReadFailure] for a config that is there but could not be
  /// read, or damaged and impossible to move aside.
  Future<Map<String, dynamic>?> _readConfig(File file) async {
    final bytes = await _readPatiently(file);
    if (bytes == null) return null;
    // Invalid JSON, or not an object: preserve it rather than letting the app
    // start from defaults and immediately autosave over the user's data.
    var damaged = false;
    final decoded = _decodeJson(bytes, damaged: () => damaged = true);
    if (damaged || (decoded != null && decoded is! Map<String, dynamic>)) {
      _quarantineCorruptFile(file);
      return null;
    }
    final config = decoded as Map<String, dynamic>?;
    // After the parse on purpose: nothing about the tokens may quarantine a
    // config that parsed.
    if (config != null) await _openSecrets(file, config);
    return config;
  }

  /// Decrypts the tokens of a freshly read [config] in place, and seals any
  /// that are still stored in plaintext.
  ///
  /// That migration rewrites the file at once rather than at the next save,
  /// so a session that happens never to save does not leave the plaintext on
  /// disk. It writes back the map just read with only the token values
  /// changed, so even keys this build does not know survive it.
  Future<void> _openSecrets(File file, Map<String, dynamic> config) async {
    final settings = config['settings'];
    if (settings is! Map<String, dynamic>) return;
    final sealedSettings = _secrets.openFromDisk(settings);
    if (sealedSettings == null) return;
    await _writerFor(file)
        .write(json.encode({...config, 'settings': sealedSettings}));
  }

  /// [downloadHistory] is every VOD ever downloaded (DownloadHistory), left
  /// out when null.
  Future<void> saveConfig(
    List<TwitchChannel> channels,
    AppSettings settings,
    Map<String, int> localProgress,
    Map<String, String> downloadedVods, {
    Map<String, int>? downloadHistory,
  }) async {
    final file = _getStorageFile();
    final config = {
      'channels': channels.map((c) => c.toJson()).toList(),
      'settings': _secrets.sealForDisk(settings.toJson()),
      'local_vods_progress': localProgress,
      'downloaded_vods': downloadedVods,
      'download_history': ?downloadHistory,
    };
    await _writerFor(file).write(json.encode(config));

    // NOTE: this used to also mirror the whole config next to the executable on
    // every save. That wrote the Twitch OAuth token and the browser auth token
    // into the install directory even for non-portable installs, from where the
    // updater's backup copied them into %TEMP% (and, during an elevated update,
    // into another user's profile). Portable installs are already served by the
    // portable.txt branch in getStorageFile.
    //
    // Nothing writes that mirror any more. One an older build left behind,
    // plaintext tokens and all, is dealt with in two places - never in a
    // portable copy, where that name is the real config, and never while
    // AppData has no config, since the one-time migration in getStorageFile
    // still reads it then:
    //
    // * At startup, once the config has loaded from AppData, the app
    //   scrubs it (scrubStaleConfigMirror): its tokens blanked, everything
    //   else kept. Not deleted, because the conditions cannot tell it from
    //   a portable copy that lost its portable.txt - a folder moved or
    //   copied without it - whose real config this is: deleting it lost the
    //   channels and settings that putting portable.txt back used to
    //   recover. That reaches only a folder the user can write, such as a
    //   per-user install: under Program Files only an elevated process can
    //   change the file, and the app never runs elevated now - which is
    //   also how such a mirror got there, as the updater used to relaunch
    //   the app with its administrator token.
    // * By the updater, which deletes it only where it needs elevation to
    //   write the install folder - the one case the scrub cannot reach, and
    //   one where no portable copy could have saved a config of its own -
    //   when the app passes --drop-config-mirror, which it does only on the
    //   same conditions, and no portable.txt is in that folder. In a folder
    //   the user can write it leaves the file to the scrub. Otherwise the
    //   updater still never replaces or deletes a channels_config.json
    //   there, and one from before the flag ignores it.
  }

  /// Throws [StorageReadFailure] for a list that is there but could not be
  /// read.
  Future<List<Map<String, dynamic>>> loadRecentWatchedVods() async {
    final file = getStorageFile('recent_watched_vods.json');
    final bytes = await _readPatiently(file);
    if (bytes == null) return [];
    var damaged = false;
    final decoded = _decodeJson(bytes, damaged: () => damaged = true);
    if (!damaged && decoded == null) return [];
    if (decoded is List) {
      return decoded.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    }
    _quarantineCorruptFile(file);
    return [];
  }

  Future<void> saveRecentWatchedVods(List<Map<String, dynamic>> list) async {
    final file = getStorageFile('recent_watched_vods.json');
    await _writerFor(file).write(json.encode(list));
  }

  /// Watch progress lives in its own file, not inside channels_config.json.
  ///
  /// `saveConfig` rewrites that config wholesale with no merge, so anything
  /// sharing it rides on every unrelated save — a window resize included. A
  /// position someone spent five hours reaching should not depend on the
  /// integrity of a file that is rewritten when the window moves. The flat
  /// `local_vods_progress` key stays in the config as a compatibility copy, so
  /// an older build still finds positions where it expects them.
  ///
  /// Throws [StorageReadFailure] for a sidecar that is there but could not be
  /// read.
  Future<Map<String, dynamic>> loadWatchProgress() async {
    final file = getStorageFile('watch_progress.json');
    final bytes = await _readPatiently(file);
    if (bytes == null) return {};
    var damaged = false;
    final decoded = _decodeJson(bytes, damaged: () => damaged = true);
    if (!damaged && decoded == null) return {};
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    _quarantineCorruptFile(file);
    return {};
  }

  Future<void> saveWatchProgress(Map<String, dynamic> data) async {
    final file = getStorageFile('watch_progress.json');
    await _writerFor(file).write(json.encode(data));
  }
}

/// The config as it was on disk at launch, read and decoded once, for
/// `main()` and the first load of the main screen to share.
///
/// Both used to read and decode the file, and parse the settings, on their
/// own: twice the startup IO (and twice the token decryption), two parse
/// paths free to drift apart, and if the file changed between the reads - a
/// sync client, another instance - the window and theme came from one
/// version and the app state from another.
///
/// A launch snapshot only. Anything that wants the config later must call
/// [StorageService.loadConfig], since saves move the file on from here.
class StartupConfig {
  const StartupConfig({
    required this.existed,
    required this.data,
    this.readFailure,
  });

  /// Whether a config file was present before loading, even one too damaged
  /// to read. Distinct from [data] being null: see [isFirstRun].
  final bool existed;

  /// The decoded config with its tokens decrypted, exactly as
  /// [StorageService.loadConfig] returned it; null when there was none or it
  /// was unreadable (and has been quarantined).
  final Map<String, dynamic>? data;

  /// Set when the config is there but could not be read (see
  /// [StorageReadFailure]): [data] is null, and nothing may be saved over it.
  final StorageReadFailure? readFailure;

  /// True only when there was no config file at all. A corrupted one is not a
  /// first run, and must not show the onboarding wizard to an existing user.
  bool get isFirstRun => !existed;

  /// The stored settings, or the defaults when there are none or they cannot
  /// be parsed.
  ///
  /// The single settings parse for startup. Each call returns a new and fully
  /// independent instance, parsed from a deep copy: `AppSettings` is mutable
  /// and keeps list values by reference, and `main()` holds its copy in a
  /// window callback while the main screen goes on to edit its own.
  AppSettings parseSettings() {
    final stored = data?['settings'];
    if (stored is Map<String, dynamic>) {
      // Runs before the first frame, so an unparseable config here would stop
      // the app from starting at all rather than falling back to defaults.
      try {
        final copy = json.decode(json.encode(stored)) as Map<String, dynamic>;
        return AppSettings.fromJson(copy);
      } catch (e) {
        print('[Config] Settings unreadable, using defaults: $e');
      }
    }
    return AppSettings();
  }
}
