import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:archive/archive.dart';

class UpdateInfo {
  final String version;
  final String tagName;
  final String releaseNotes;
  final String downloadUrl;
  final int fileSize;

  UpdateInfo({
    required this.version,
    required this.tagName,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.fileSize,
  });
}

class UpdateService {
  static const String currentVersion = '1.0.6';
  static const String githubRepoUrl = 'https://github.com/MohsenBlur/streamlink-gui';
  static const String githubApiReleaseUrl = 'https://api.github.com/repos/MohsenBlur/streamlink-gui/releases/latest';

  bool isNewerVersion(String latestTag, String currentVer) {
    final latestClean = latestTag.replaceAll(RegExp(r'[^0-9.]'), '');
    final currentClean = currentVer.replaceAll(RegExp(r'[^0-9.]'), '');
    
    final lParts = latestClean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final cParts = currentClean.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    final maxLength = lParts.length > cParts.length ? lParts.length : cParts.length;
    for (int i = 0; i < maxLength; i++) {
      final l = i < lParts.length ? lParts[i] : 0;
      final c = i < cParts.length ? cParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return false;
  }

  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse(githubApiReleaseUrl),
        headers: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'Twitch-Streamlink-GUI-App',
        },
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final tagName = data['tag_name'] as String? ?? '';
        final body = data['body'] as String? ?? '';
        final assets = data['assets'] as List<dynamic>? ?? [];

        if (isNewerVersion(tagName, currentVersion)) {
          String? downloadUrl;
          int size = 0;
          for (final asset in assets) {
            final name = (asset['name'] as String? ?? '').toLowerCase();
            if (name.endsWith('.zip') && (name.contains('windows') || name.contains('gui'))) {
              downloadUrl = asset['browser_download_url'] as String?;
              size = asset['size'] as int? ?? 0;
              break;
            }
          }

          if (downloadUrl != null) {
            return UpdateInfo(
              version: tagName.replaceAll('v', ''),
              tagName: tagName,
              releaseNotes: body,
              downloadUrl: downloadUrl,
              fileSize: size,
            );
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<File> downloadUpdate(String downloadUrl, void Function(double progress) onProgress) async {
    final client = http.Client();
    final request = http.Request('GET', Uri.parse(downloadUrl));
    request.headers['User-Agent'] = 'Twitch-Streamlink-GUI-App';
    
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw Exception('Failed to download update file (HTTP ${response.statusCode})');
    }

    final contentLength = response.contentLength ?? 0;
    final tempDir = Directory.systemTemp.createTempSync('streamlink_gui_update_');
    final zipFile = File(path.join(tempDir.path, 'update.zip'));
    final sink = zipFile.openWrite();

    int downloadedBytes = 0;
    await response.stream.listen((chunk) {
      downloadedBytes += chunk.length;
      sink.add(chunk);
      if (contentLength > 0) {
        final pct = downloadedBytes / contentLength;
        onProgress(pct.clamp(0.0, 1.0));
      }
    }).asFuture();

    await sink.close();
    client.close();
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

    bool hasExe = false;
    for (final file in archive) {
      final filename = file.name;
      if (file.isFile) {
        final data = file.content as List<int>;
        final outFile = File(path.join(extractDir.path, filename));
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(data);

        if (path.basename(filename).toLowerCase() == 'streamlink_gui.exe') {
          hasExe = true;
        }
      } else {
        Directory(path.join(extractDir.path, filename)).createSync(recursive: true);
      }
    }

    if (!hasExe) {
      throw Exception('Downloaded update archive does not contain streamlink_gui.exe!');
    }

    return extractDir;
  }

  Future<void> applyUpdateAndRestart(Directory extractDir) async {
    final exeFile = File(Platform.resolvedExecutable);
    final appDir = exeFile.parent.path;
    final currentPid = pid;

    final tempDir = extractDir.parent.path;
    final backupDir = path.join(tempDir, 'backup');
    final batPath = path.join(tempDir, 'updater.bat');

    // Create space-quoted, fail-safe Windows batch updater script with atomic backup & rollback
    final scriptContent = '''@echo off
setlocal enabledelayedexpansion
set "APP_PID=$currentPid"
set "APP_DIR=$appDir"
set "EXTRACT_DIR=${extractDir.path}"
set "BACKUP_DIR=$backupDir"
set "EXE_PATH=${exeFile.path}"

:wait_loop
taskkill /F /PID %APP_PID% >NUL 2>&1
timeout /t 1 /nobreak >NUL
tasklist /FI "PID eq %APP_PID%" 2>NUL | find /I "%APP_PID%" >NUL
if %ERRORLEVEL%==0 goto wait_loop

if exist "%BACKUP_DIR%" rmdir /S /Q "%BACKUP_DIR%"
mkdir "%BACKUP_DIR%"
xcopy /E /Y /Q "%APP_DIR%\\*" "%BACKUP_DIR%\\" >NUL

xcopy /E /Y /Q "%EXTRACT_DIR%\\*" "%APP_DIR%\\" >NUL
if %ERRORLEVEL% neq 0 (
    xcopy /E /Y /Q "%BACKUP_DIR%\\*" "%APP_DIR%\\" >NUL
    start "" "%EXE_PATH%"
    exit /b 1
)

rmdir /S /Q "%BACKUP_DIR%" >NUL 2>&1
rmdir /S /Q "%EXTRACT_DIR%" >NUL 2>&1

start "" "%EXE_PATH%"
exit /b 0
''';

    final batFile = File(batPath);
    await batFile.writeAsString(scriptContent);

    // Launch updater script in detached shell
    await Process.start(
      'cmd.exe',
      ['/c', 'start', '/min', batPath, currentPid.toString(), appDir, extractDir.path, backupDir],
      runInShell: false,
    );

    // Terminate current process immediately to release file lock
    exit(0);
  }
}
