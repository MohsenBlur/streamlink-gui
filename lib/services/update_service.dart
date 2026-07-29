import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

class UpdateInfo {
  final String version;
  final String releaseNotes;
  final String zipDownloadUrl;
  final bool isUpdateAvailable;

  UpdateInfo({
    required this.version,
    required this.releaseNotes,
    required this.zipDownloadUrl,
    required this.isUpdateAvailable,
  });

  String get tagName => version.startsWith('v') ? version : 'v$version';
  String get downloadUrl => zipDownloadUrl;
}

class UpdateService {
  static const String currentVersion = '1.0.59';


  static const String githubRepoUrl = 'https://github.com/MohsenBlur/streamlink-gui';
  static const String githubApiReleaseUrl = 'https://api.github.com/repos/MohsenBlur/streamlink-gui/releases/latest';

  int _versionToComparableInt(String version) {
    final clean = version.replaceAll(RegExp(r'[^0-9.]'), '');
    final parts = clean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return (parts[0] * 1000000) + (parts[1] * 1000) + parts[2];
  }

  Future<UpdateInfo?> checkForUpdates() async {
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
      for (final asset in assets) {
        if (asset is Map<String, dynamic>) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          final downloadUrl = asset['browser_download_url'] as String? ?? '';
          if (name.endsWith('.zip') && downloadUrl.isNotEmpty) {
            zipUrl = downloadUrl;
            break;
          }
        }
      }

      final latestVerInt = _versionToComparableInt(tagName);
      final currentVerInt = _versionToComparableInt(currentVersion);

      final isAvailable = (latestVerInt > currentVerInt) && zipUrl.isNotEmpty && zipUrl.startsWith('http');

      return UpdateInfo(
        version: tagName.startsWith('v') ? tagName.substring(1) : tagName,
        releaseNotes: body,
        zipDownloadUrl: zipUrl,
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
    final request = http.Request('GET', Uri.parse(zipUrl));
    final response = await http.Client().send(request);

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
  }

  Future<Directory> extractAndVerifyZip(File zipFile) async {
    final bytes = zipFile.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    
    final extractDir = Directory(path.join(zipFile.parent.path, 'extracted'));
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
    extractDir.createSync(recursive: true);

    for (final file in archive) {
      final filename = file.name;
      if (file.isFile) {
        final data = file.content as List<int>;
        final outFile = File(path.join(extractDir.path, filename));
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(data);
      } else {
        Directory(path.join(extractDir.path, filename)).createSync(recursive: true);
      }
    }

    final exeMatches = extractDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => path.basename(f.path).toLowerCase() == 'streamlink_gui.exe')
        .toList();

    if (exeMatches.isEmpty) {
      throw Exception('Downloaded update archive does not contain streamlink_gui.exe!');
    }

    return exeMatches.first.parent;
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

