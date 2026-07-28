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
  static const String currentVersion = '1.0.48';
  static const String githubRepoUrl = 'https://github.com/MohsenBlur/streamlink-gui';
  static const String githubApiReleaseUrl = 'https://api.github.com/repos/MohsenBlur/streamlink-gui/releases/latest';

  int _versionToComparableInt(String version) {
    final clean = version.replaceAll(RegExp(r'[^0-9.]'), '');
    final parts = clean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return (parts[0] * 10000) + (parts[1] * 100) + parts[2];
  }

  Future<UpdateInfo?> checkForUpdates() async {
    try {
      final response = await http.get(
        Uri.parse(githubApiReleaseUrl),
        headers: {'Accept': 'application/vnd.github.v3+json'},
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

    final List<int> bytesList = [];
    int downloadedBytes = 0;

    await for (final chunk in response.stream) {
      bytesList.addAll(chunk);
      downloadedBytes += chunk.length;
      if (contentLength > 0 && onProgress != null) {
        onProgress(downloadedBytes / contentLength);
      }
    }

    await zipFile.writeAsBytes(bytesList);
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
    final currentPid = pid;

    final tempDir = sourceDir.parent.path;
    final backupDir = path.join(tempDir, 'backup');
    final ps1Path = path.join(tempDir, 'updater.ps1');

    final normAppDir = path.normalize(appDir).replaceAll('\\', '/');
    final normSourceDir = path.normalize(sourceDir.path).replaceAll('\\', '/');
    final normBackupDir = path.normalize(backupDir).replaceAll('\\', '/');
    final normExePath = path.normalize(exeFile.path).replaceAll('\\', '/');
    final normPs1Path = path.normalize(ps1Path).replaceAll('\\', '/');

    final scriptContent = '''
# Auto-generated Single Self-Elevating Updater Script for Twitch Streamlink GUI
\$ErrorActionPreference = "Stop"

\$AppPid = $currentPid
\$AppDir = "$normAppDir"
\$SourceDir = "$normSourceDir"
\$BackupDir = "$normBackupDir"
\$ExePath = "$normExePath"

\$WinAppDir = \$AppDir.Replace('/', '\\')
\$WinSourceDir = \$SourceDir.Replace('/', '\\')
\$WinBackupDir = \$BackupDir.Replace('/', '\\')
\$WinExePath = \$ExePath.Replace('/', '\\')

# Check write permission for target directory
\$testFile = Join-Path \$WinAppDir ".perm_test"
\$needsElevation = \$false
try {
    [System.IO.File]::WriteAllText(\$testFile, "test")
    Remove-Item \$testFile -Force -ErrorAction SilentlyContinue
} catch {
    \$needsElevation = \$true
}

# If target directory requires elevation and we are not admin, self-elevate
if (\$needsElevation -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$normPs1Path`"" -Verb RunAs
    exit
}

# 1. Wait for parent process to fully terminate
\$maxWait = 15
while (\$maxWait -gt 0 -and (Get-Process -Id \$AppPid -ErrorAction SilentlyContinue)) {
    Stop-Process -Id \$AppPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    \$maxWait--
}
Stop-Process -Name "streamlink_gui" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "streamlink" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# 2. Backup & File Replacement (Protect channels_config.json & portable.txt)
try {
    if (Test-Path "\$WinBackupDir") { Remove-Item -Path "\$WinBackupDir" -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path "\$WinBackupDir" -Force | Out-Null
    
    & robocopy "\$WinAppDir" "\$WinBackupDir" /E /NP /R:3 /W:1 /XF "updater.ps1" "channels_config.json" "portable.txt"
    & robocopy "\$WinSourceDir" "\$WinAppDir" /E /IS /IT /NP /R:5 /W:1 /XF "channels_config.json" "portable.txt"
    if (\$LASTEXITCODE -ge 8) {
        throw "Robocopy failed with exit code \$LASTEXITCODE during file installation."
    }

    Remove-Item -Path "\$WinBackupDir" -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    if (Test-Path "\$WinBackupDir") {
        & robocopy "\$WinBackupDir" "\$WinAppDir" /E /IS /IT /NP /R:3 /W:1
    }
    
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "The application update could not be completed.`n`nError details: \$_`n`nThe previous version of Streamlink GUI has been restored.",
            "Streamlink GUI Update Failure",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch {}
}

# 3. Re-launch updated application
try {
    Start-Process "\$WinExePath"
} catch {
    Start-Process "cmd.exe" -ArgumentList "/c start `"`" `"\$WinExePath`""
}
''';

    await File(ps1Path).writeAsString(scriptContent);

    await Process.start(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ps1Path],
      mode: ProcessStartMode.detached,
    );

    await Future.delayed(const Duration(milliseconds: 300));
    exit(0);
  }
}
