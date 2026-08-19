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

    try {
      final response = await http.get(
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

  Future<File> downloadUpdate(
    String zipUrl,
    void Function(double progress)? onProgress,
  ) async {
    if (zipUrl.isEmpty || !zipUrl.startsWith('http')) {
      throw Exception('No valid download URL provided for update.');
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(zipUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Failed to download update file (HTTP ${response.statusCode})');
      }

      final contentLength = response.contentLength ?? 0;
      final tempDir = await Directory.systemTemp.createTemp('streamlink_gui_update_');
      final zipFile = File(path.join(tempDir.path, 'update.zip'));
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
      return zipFile;
    } finally {
      client.close();
    }
  }

  /// Verifies [zipFile] against the release's published SHA256SUMS.
  ///
  /// Throws if the checksum is present but does not match. A release without a
  /// checksum asset (anything published before they were added) is allowed
  /// through, so older installs can still update.
  Future<void> verifyChecksum(File zipFile, String checksumUrl) async {
    if (checksumUrl.isEmpty) return;

    String expected;
    try {
      final response = await http
          .get(Uri.parse(checksumUrl), headers: {'User-Agent': 'TwitchStreamlinkGUI-App'})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return;
      // Format: "<hex>  streamlink-gui-windows.zip"
      final match = RegExp(r'([a-fA-F0-9]{64})').firstMatch(response.body);
      if (match == null) return;
      expected = match.group(1)!.toLowerCase();
    } catch (_) {
      // A network failure fetching the checksum must not block the update.
      return;
    }

    final digest = await Isolate.run(() => sha256.convert(zipFile.readAsBytesSync()).toString());
    if (digest.toLowerCase() != expected) {
      throw Exception(
        'The downloaded update failed its integrity check and was discarded.\n'
        'Expected $expected but got $digest.',
      );
    }
  }

  Future<Directory> extractAndVerifyZip(File zipFile) async {
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

  Future<void> applyUpdateAndRestart(Directory sourceDir) async {
    final exeFile = File(Platform.resolvedExecutable);
    final appDir = exeFile.parent.path;
    final exeName = path.basename(exeFile.path);

    // Normalize paths and strip trailing slashes to prevent Windows CommandLineToArgvW quote escape corruption (\" -> ")
    final targetPath = path.normalize(appDir).replaceAll(RegExp(r'[/\\]+$'), '');
    final sourcePath = path.normalize(sourceDir.path).replaceAll(RegExp(r'[/\\]+$'), '');

    // 1. Locate updater.exe helper binary
    File helperExe = File(path.join(targetPath, 'updater.exe'));
    if (!helperExe.existsSync()) {
      // Check in extracted source directory if missing from local app directory
      final extractedHelper = File(path.join(sourcePath, 'updater.exe'));
      if (extractedHelper.existsSync()) {
        helperExe = extractedHelper;
      }
    }

    if (!helperExe.existsSync()) {
      throw Exception('Update helper binary (updater.exe) not found.');
    }

    // 2. Copy helper binary to %TEMP% to prevent self-locking during directory swap
    final tempRunner = File(path.join(Directory.systemTemp.path, 'streamlink_updater_runner.exe'));
    await helperExe.copy(tempRunner.path);

    // 3. Spawn detached native helper executable
    // Arguments: [TargetAppDir, SourceStagingDir, ExeName]
    await Process.start(
      tempRunner.path,
      [targetPath, sourcePath, exeName],
      mode: ProcessStartMode.detached,
    );

    // 4. Gracefully terminate main application process
    await Future.delayed(const Duration(milliseconds: 200));
    exit(0);
  }
}

