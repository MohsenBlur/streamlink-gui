import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

class UpdateInfo {
  final String version;
  final String releaseNotes;
  final String zipDownloadUrl;

  /// URL of the release's SHA256SUMS asset, when published.
  final String checksumUrl;

  final bool isUpdateAvailable;

  UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.zipDownloadUrl,
    required this.isUpdateAvailable,
    this.checksumUrl = '',
  });

  String get tagName => version.startsWith('v') ? version : 'v$version';
  String get downloadUrl => zipDownloadUrl;
}

class UpdateService {
  /// [client] and [tempRoot] exist for tests; the app passes neither, so
  /// requests use a fresh client and update files go to the system temp.
  UpdateService({http.Client? client, Directory? tempRoot})
      : _client = client,
        _tempRootOverride = tempRoot;

  final http.Client? _client;
  final Directory? _tempRootOverride;

  Directory get _tempRoot => _tempRootOverride ?? Directory.systemTemp;

  /// Every update attempt works in its own `<temp>/<prefix>*` directory, which
  /// holds the ~300 MB archive and then its extracted copy.
  static const String updateDirPrefix = 'streamlink_gui_update_';

  /// How long a leftover update directory is kept before the startup sweep
  /// deletes it.
  ///
  /// The updater copies the new build out of the extracted directory after
  /// this app exits, and nothing deletes it afterwards. A day is far past any
  /// swap, an elevated one waiting on its UAC prompt included, while still
  /// reclaiming the space within a launch or two.
  static const Duration staleUpdateDirAge = Duration(hours: 24);

  /// Update directories this process is still working in, which the sweep
  /// must not touch however old they look: a directory's timestamp does not
  /// move while a slow download is still appending to the file inside it.
  static final Set<String> _activeUpdateDirs = {};

  /// Sentinel used when the app is built without `--dart-define=APP_VERSION`,
  /// i.e. `flutter run` during development.
  static const String devVersion = '0.0.0-dev';

  /// Injected at build time from `pubspec.yaml` so this can never drift from
  /// the published release tag. See `build.ps1` and `.github/workflows/release.yml`.
  static const String currentVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: devVersion,
  );

  /// Development builds must never self-update: doing so would replace the
  /// developer's working tree with a released build.
  static bool get isDevBuild => currentVersion == devVersion;

  static const String githubRepoUrl = 'https://github.com/MohsenBlur/streamlink-gui';
  static const String githubApiReleaseUrl = 'https://api.github.com/repos/MohsenBlur/streamlink-gui/releases/latest';

  /// Parses a version like `v1.2.3` / `1.2.3` into its numeric components.
  static List<int> parseVersion(String version) {
    final clean = version.replaceAll(RegExp(r'[^0-9.]'), '');
    final parts = clean
        .split('.')
        .where((p) => p.isNotEmpty)
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }

  /// Compares two versions component by component.
  /// Returns <0 if [a] is older than [b], 0 if equal, >0 if newer.
  ///
  /// Compared per component rather than packed into a single int: the previous
  /// implementation computed `major*1000000 + minor*1000 + patch`, so any
  /// component reaching 1000 carried into the next field and made, for example,
  /// 1.0.1000 compare equal to 1.1.0.
  static int compareVersions(String a, String b) {
    final pa = parseVersion(a);
    final pb = parseVersion(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va < vb ? -1 : 1;
    }
    return 0;
  }

  Future<UpdateInfo?> checkForUpdates() async {
    // A development build has no meaningful version to compare against, and
    // self-updating would replace the developer's working tree with a release.
    if (isDevBuild) return null;

    // Reclaims what earlier attempts left behind. This runs on the startup
    // check and on a manual check from Settings, so it can overlap an update
    // in this process - whose directories the sweep skips - but never one a
    // previous run's updater could still be copying from, which is far
    // younger than the age limit. Not awaited: deleting a few hundred MB must
    // not delay the prompt.
    unawaited(sweepStaleUpdateDirs());

    try {
      final response = await _get(
        Uri.parse(githubApiReleaseUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'TwitchStreamlinkGUI-App',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return null;
      }

      final data = json.decode(response.body);
      if (data is! Map<String, dynamic>) return null;

      final tagName = data['tag_name'] as String? ?? '';
      final body = data['body'] as String? ?? 'No release notes provided.';
      final assets = data['assets'] as List<dynamic>? ?? [];

      String zipUrl = '';
      String checksumUrl = '';
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = (asset['name'] as String? ?? '').toLowerCase();
        final downloadUrl = asset['browser_download_url'] as String? ?? '';
        if (downloadUrl.isEmpty) continue;
        if (zipUrl.isEmpty && name.endsWith('.zip')) {
          zipUrl = downloadUrl;
        } else if (checksumUrl.isEmpty && name == 'sha256sums') {
          checksumUrl = downloadUrl;
        }
      }

      final isNewer = compareVersions(tagName, currentVersion) > 0;

      final isAvailable = isNewer && zipUrl.isNotEmpty && zipUrl.startsWith('http');

      return UpdateInfo(
        version: tagName.startsWith('v') ? tagName.substring(1) : tagName,
        releaseNotes: body,
        zipDownloadUrl: zipUrl,
        checksumUrl: checksumUrl,
        isUpdateAvailable: isAvailable,
      );
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _get(Uri url, {Map<String, String>? headers}) {
    final client = _client;
    return client != null
        ? client.get(url, headers: headers)
        : http.get(url, headers: headers);
  }

  /// The name a downloaded update is saved under: the release asset's own
  /// name, so [verifyChecksum] can find that asset's line in SHA256SUMS.
  /// Anything that is not a plain `*.zip` file name falls back to a fixed one.
  static String zipFileNameFor(String zipUrl) {
    final segments = Uri.tryParse(zipUrl)?.pathSegments ?? const <String>[];
    final last = segments.isEmpty ? '' : segments.last;
    final plainZipName =
        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$', caseSensitive: false);
    return plainZipName.hasMatch(last) ? last : 'update.zip';
  }

  Future<File> downloadUpdate(
    String zipUrl,
    void Function(double progress)? onProgress,
  ) async {
    if (zipUrl.isEmpty || !zipUrl.startsWith('http')) {
      throw Exception('No valid download URL provided for update.');
    }
    final client = _client ?? http.Client();
    try {
      final request = http.Request('GET', Uri.parse(zipUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Failed to download update file (HTTP ${response.statusCode})');
      }

      final contentLength = response.contentLength ?? 0;
      final tempDir = await _tempRoot.createTemp(updateDirPrefix);
      _activeUpdateDirs.add(tempDir.path);
      try {
        final zipFile = File(path.join(tempDir.path, zipFileNameFor(zipUrl)));
        final sink = zipFile.openWrite();

        int downloadedBytes = 0;
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            downloadedBytes += chunk.length;
            if (contentLength > 0 && onProgress != null) {
              onProgress(downloadedBytes / contentLength);
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }

        // A connection that ends early can close the stream cleanly, and a
        // release published without SHA256SUMS has no checksum to catch it.
        if (contentLength > 0 && downloadedBytes != contentLength) {
          throw Exception(
            'The update download was cut short ($downloadedBytes of '
            '$contentLength bytes). Your current version is unchanged.',
          );
        }
        return zipFile;
      } catch (_) {
        // Every failed attempt used to leave its partial archive in %TEMP%.
        await _discardUpdateDir(tempDir);
        rethrow;
      }
    } finally {
      if (_client == null) client.close();
    }
  }

  /// Verifies [zipFile] against the release's published SHA256SUMS, and
  /// deletes the download if it cannot be verified.
  ///
  /// Fails closed. This used to return silently when the checksum list could
  /// not be fetched (a non-200, a timeout, a dropped connection) or held no
  /// digest, so a flaky network that lost only that small request let an
  /// unverified archive straight through to the installer. Now any of those
  /// stops the update; the user retries, and nothing has been changed.
  ///
  /// [assetName] is the line to match in a multi-file list; by default the
  /// name [downloadUpdate] saved the archive under, which is the asset's own.
  ///
  /// A release that publishes no SHA256SUMS at all ([checksumUrl] empty) is
  /// still let through. The list comes from the same release as the archive,
  /// so it only ever guarded against corruption, never tampering, and the
  /// length check in [downloadUpdate] still catches a truncated transfer.
  Future<void> verifyChecksum(File zipFile, String checksumUrl,
      {String? assetName}) async {
    if (checksumUrl.isEmpty) return;

    try {
      final expected = await _fetchExpectedDigest(
          checksumUrl, assetName ?? path.basename(zipFile.path));

      final digest = await Isolate.run(() => sha256.convert(zipFile.readAsBytesSync()).toString());
      if (digest.toLowerCase() != expected) {
        throw Exception(
          'The downloaded update failed its integrity check and was discarded.\n'
          'Expected $expected but got $digest.',
        );
      }
    } catch (_) {
      // "Was discarded" used to be untrue: nothing deleted the download.
      await _discardUpdateDir(zipFile.parent);
      rethrow;
    }
  }

  Future<String> _fetchExpectedDigest(String checksumUrl, String assetName) async {
    const notApplied = 'so the download could not be verified and was not '
        'applied. Your current version is unchanged; try again later.';
    final http.Response response;
    try {
      response = await _get(Uri.parse(checksumUrl),
              headers: {'User-Agent': 'TwitchStreamlinkGUI-App'})
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      final reason = e is TimeoutException ? 'timed out' : 'network error';
      throw Exception("Could not download the update's checksum ($reason), $notApplied");
    }
    if (response.statusCode != 200) {
      throw Exception(
          "Could not download the update's checksum (HTTP ${response.statusCode}), $notApplied");
    }
    final expected = expectedDigestFor(response.body, assetName);
    if (expected == null) {
      throw Exception(
          "The update's checksum list has no entry for $assetName, $notApplied");
    }
    return expected;
  }

  /// The lowercase SHA-256 that a `sha256sum`-style [sums] list gives for
  /// [assetName], or null when it gives none.
  ///
  /// Lines look like `<64 hex>  name` (or `<64 hex> *name` in binary mode).
  /// The line naming the asset wins, matched case-insensitively on its file
  /// name, so a list covering several files can never hand back another
  /// file's digest. A list holding exactly one digest is taken as the
  /// archive's whatever it names: this app's releases publish one line, and
  /// a wrong digest still fails the comparison rather than passing it.
  static String? expectedDigestFor(String sums, String assetName) {
    final line = RegExp(r'^([a-fA-F0-9]{64})(?:\s+\*?(.+))?$');
    final entries = <({String digest, String? name})>[];
    for (final raw in const LineSplitter().convert(sums)) {
      final match = line.firstMatch(raw.trim());
      if (match == null) continue;
      entries.add((
        digest: match.group(1)!.toLowerCase(),
        name: match.group(2)?.trim(),
      ));
    }

    final wanted = assetName.toLowerCase();
    for (final entry in entries) {
      final name = entry.name;
      if (name == null) continue;
      if (name.split(RegExp(r'[/\\]')).last.toLowerCase() == wanted) {
        return entry.digest;
      }
    }
    return entries.length == 1 ? entries.single.digest : null;
  }

  /// Whether [dir] is an update working directory this service created, and
  /// so safe to delete wholesale.
  bool _isUpdateDir(Directory dir) =>
      path.basename(dir.path).startsWith(updateDirPrefix) &&
      path.isWithin(_tempRoot.path, dir.path);

  /// Deletes the update working directory [appRoot] was extracted into, for a
  /// caller whose own step failed after [extractAndVerifyZip] returned (the
  /// download queue could not be saved, say).
  ///
  /// Only ever before [startUpdater] has been called: from then on
  /// the updater may be copying out of it. Does nothing for a directory that
  /// is not inside one of this service's update directories.
  Future<void> discardExtractedUpdate(Directory appRoot) async {
    var dir = appRoot.absolute;
    while (true) {
      if (_isUpdateDir(dir)) {
        await _discardUpdateDir(dir);
        return;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) return;
      dir = parent;
    }
  }

  Future<void> _discardUpdateDir(Directory dir) async {
    if (!_isUpdateDir(dir)) return;
    _activeUpdateDirs.remove(dir.path);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Something still holds a file open (a scanner reading the archive);
      // the startup sweep reclaims it on a later launch.
    }
  }

  /// Deletes update working directories older than [olderThan] that earlier
  /// runs left in the temp folder.
  ///
  /// Each attempt leaves one: a successful update's extracted build (the
  /// updater copies out of it and never deletes it), and before failures
  /// cleaned up after themselves, every failed attempt's archive too, at
  /// about 300 MB apiece. Only real directories carrying [updateDirPrefix]
  /// are touched (links are not followed), and never one this process is
  /// still working in.
  Future<void> sweepStaleUpdateDirs({Duration olderThan = staleUpdateDirAge}) async {
    try {
      final now = DateTime.now();
      await for (final entity in _tempRoot.list(followLinks: false)) {
        if (entity is! Directory) continue;
        if (!path.basename(entity.path).startsWith(updateDirPrefix)) continue;
        if (_activeUpdateDirs.contains(entity.path)) continue;
        try {
          final modified = (await entity.stat()).modified;
          if (now.difference(modified) < olderThan) continue;
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Unpacks [zipFile] next to itself and checks it is a complete build.
  ///
  /// On success the archive itself is deleted, since only the extracted copy
  /// is used from here on; on failure the whole attempt is.
  Future<Directory> extractAndVerifyZip(File zipFile) async {
    final workDir = zipFile.parent;
    try {
      final appRoot = await _extractAndVerifyZip(zipFile);
      if (_isUpdateDir(workDir)) {
        try {
          await zipFile.delete();
        } catch (_) {}
      }
      return appRoot;
    } catch (_) {
      await _discardUpdateDir(workDir);
      rethrow;
    }
  }

  Future<Directory> _extractAndVerifyZip(File zipFile) async {
    final extractDir = Directory(path.join(zipFile.parent.path, 'extracted'));
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
    extractDir.createSync(recursive: true);

    final zipPath = zipFile.path;
    final extractPath = extractDir.path;

    // Decoding and writing a ~300 MB archive on the UI isolate froze the app for
    // the whole extraction.
    await Isolate.run(() {
      final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      final root = Directory(extractPath).absolute.path;

      for (final entry in archive) {
        // Zip Slip: an archive entry can contain '..' segments that escape the
        // extraction directory and overwrite arbitrary files. Resolve and
        // confirm every destination stays inside the target.
        final destination = path.normalize(path.join(root, entry.name));
        if (!path.isWithin(root, destination)) {
          throw Exception('Update archive contains an unsafe path: ${entry.name}');
        }

        if (entry.isFile) {
          final outFile = File(destination);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(entry.content as List<int>);
        } else {
          Directory(destination).createSync(recursive: true);
        }
      }
    });

    final exeMatches = extractDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => path.basename(f.path).toLowerCase() == 'streamlink_gui.exe')
        .toList();

    if (exeMatches.isEmpty) {
      throw Exception('Downloaded update archive does not contain streamlink_gui.exe!');
    }

    final appRoot = exeMatches.first.parent;

    // Refuse an archive that unpacked without the bundled runtime: applying it
    // would replace a working install with one that cannot play or download
    // anything.
    const required = [
      'updater.exe',
      'bin/bin/streamlink.exe',
      'bin/yt-dlp.exe',
      'bin/ffmpeg.exe',
    ];
    final missing = required
        .where((rel) => !File(path.join(appRoot.path, rel.replaceAll('/', path.separator))).existsSync())
        .toList();
    if (missing.isNotEmpty) {
      throw Exception('Update archive is incomplete (missing: ${missing.join(', ')}).');
    }

    return appRoot;
  }

  /// Starts the native updater on the build extracted at [sourceDir], and
  /// returns once it has confirmed it is running outside this app's job.
  ///
  /// The caller must then end this process promptly, through its normal
  /// shutdown: the updater waits for the app to exit (its mutex, then a
  /// WM_CLOSE and finally a kill for anything still running from the
  /// install folder) before it swaps the files and relaunches the app. This
  /// used to end the process itself with exit(0), which skipped everything
  /// the app does on the way out - the tray icon stayed behind as a ghost
  /// until the mouse passed over it, and the runner's ordered teardown of
  /// the engine, plugins and window never ran.
  ///
  /// Throws, with the installation untouched, when the updater cannot be
  /// found or copied, or never confirms it started.
  Future<void> startUpdater(Directory sourceDir) async {
    final exeFile = File(Platform.resolvedExecutable);
    final appDir = exeFile.parent.path;
    final exeName = path.basename(exeFile.path);

    // Normalize paths and strip trailing slashes to prevent Windows CommandLineToArgvW quote escape corruption (\" -> ")
    final targetPath = path.normalize(appDir).replaceAll(RegExp(r'[/\\]+$'), '');
    final sourcePath = path.normalize(sourceDir.path).replaceAll(RegExp(r'[/\\]+$'), '');

    // 1. Locate the updater, preferring the one shipped WITH the update.
    //
    // The incoming updater is the one written to install this payload, so it is
    // the correct choice; the installed copy can be arbitrarily old. This order
    // used to be reversed, which meant a released fix to the updater only took
    // effect one version after it shipped.
    File helperExe = File(path.join(sourcePath, 'updater.exe'));
    if (!helperExe.existsSync()) {
      helperExe = File(path.join(targetPath, 'updater.exe'));
    }

    // Until the updater is started nothing else can be using the extracted
    // build, so a failure up to that point takes its ~300 MB with it rather
    // than leaving it for the sweep a day later.
    final tempRunner = File(path.join(Directory.systemTemp.path, 'streamlink_updater_runner.exe'));
    try {
      if (!helperExe.existsSync()) {
        throw Exception('Update helper binary (updater.exe) not found.');
      }

      // 2. Copy helper binary to %TEMP% to prevent self-locking during directory swap
      await helperExe.copy(tempRunner.path);
    } catch (_) {
      await discardExtractedUpdate(sourceDir);
      rethrow;
    }

    // 3. Spawn the native helper.
    //
    // ProcessStartMode.detached passes DETACHED_PROCESS but NOT
    // CREATE_BREAKAWAY_FROM_JOB, so the updater starts INSIDE this app's job
    // object (KILL_ON_JOB_CLOSE). It only escapes once its own EnsureOutsideJob
    // re-launches it. If this process exited first, closing the job would kill
    // the updater mid-update and leave the user with neither the update nor a
    // running app.
    //
    // A fixed sleep was a guess. Instead the updater touches a sentinel file
    // once it is safely outside the job, and we wait for that before exiting.
    final sentinel = File(path.join(
      Directory.systemTemp.path,
      'streamlink_updater_ready_${DateTime.now().microsecondsSinceEpoch}',
    ));
    if (sentinel.existsSync()) {
      try {
        sentinel.deleteSync();
      } catch (_) {}
    }

    await Process.start(
      tempRunner.path,
      [targetPath, sourcePath, exeName, '--ready-file', sentinel.path],
      mode: ProcessStartMode.detached,
    );

    // 4. Wait for the updater to confirm it has broken out of our job.
    const timeout = Duration(seconds: 15);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (sentinel.existsSync()) break;
      await Future.delayed(const Duration(milliseconds: 50));
    }

    // If the handshake never arrived the updater could not break away and would
    // die with us, so leave the installation untouched and let the caller
    // report the failure rather than killing the app for nothing.
    //
    // The extracted build is deliberately NOT deleted here, unlike the other
    // failure paths: a late updater may still be about to copy out of it, and
    // pulling it away mid-swap would break the install. The startup sweep
    // reclaims it once it is a day old.
    if (!sentinel.existsSync()) {
      throw Exception(
        'The updater did not start correctly, so the update was not applied. '
        'Your current version is unchanged.',
      );
    }
    // Its job is done; every update used to leave one behind in %TEMP%.
    try {
      sentinel.deleteSync();
    } catch (_) {}

    // 5. The caller exits, through its own shutdown (see above).
  }
}

