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
  static const String currentVersion = '1.0.27';
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

    final scriptContent = '''
param(
    [int]\$AppPid,
    [string]\$AppDir,
    [string]\$SourceDir,
    [string]\$BackupDir,
    [string]\$ExePath
)

\$Host.UI.RawUI.WindowTitle = "Twitch Streamlink GUI - Application Self-Updater"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       Twitch Streamlink GUI - Self-Updater              " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Wait for parent process to fully terminate
Write-Host "[1/4] Waiting for main application (PID \$AppPid) to close..." -ForegroundColor Yellow
\$maxWait = 10
while (\$maxWait -gt 0 -and (Get-Process -Id \$AppPid -ErrorAction SilentlyContinue)) {
    Stop-Process -Id \$AppPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    \$maxWait--
}
Stop-Process -Name "streamlink_gui" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "streamlink" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Host "      Application closed successfully." -ForegroundColor Green
Write-Host ""

\$updateFailed = \$false
\$errorMessage = ""

try {
    # 2. Create safety backup using robocopy
    Write-Host "[2/4] Creating safety backup of existing files..." -ForegroundColor Yellow
    if (Test-Path \$BackupDir) { Remove-Item -Path \$BackupDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path \$BackupDir -Force | Out-Null
    
    & robocopy "\$AppDir" "\$BackupDir" /E /NP /R:3 /W:1 /XF "updater.ps1" "run_update.bat"
    if (\$LASTEXITCODE -ge 8) {
        throw "Backup failed with robocopy exit code \$LASTEXITCODE"
    }
    Write-Host "      Safety backup created." -ForegroundColor Green
    Write-Host ""

    # 3. Install update files using robocopy (retries up to 5 times for locked files)
    Write-Host "[3/4] Installing updated files..." -ForegroundColor Yellow
    & robocopy "\$SourceDir" "\$AppDir" /E /IS /IT /NP /R:5 /W:1
    if (\$LASTEXITCODE -ge 8) {
        throw "Update installation failed with robocopy exit code \$LASTEXITCODE"
    }

    Remove-Item -Path \$BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path \$SourceDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "      Files installed successfully!" -ForegroundColor Green
    Write-Host ""
} catch {
    \$updateFailed = \$true
    \$errorMessage = \$_
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "      [ERROR] Update failed: \$_" -ForegroundColor Red
    Write-Host "      Rolling back to backup..." -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    
    if (Test-Path \$BackupDir) {
        & robocopy "\$BackupDir" "\$AppDir" /E /IS /IT /NP /R:3 /W:1
    }
    
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "The application update could not be completed.`n`nDetails: \$_`n`nThe previous version of Streamlink GUI has been restored.",
            "Streamlink GUI Update Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } catch {}
}

# 4. Re-launch application as normal user via explorer.exe (non-elevated & fully detached)
Write-Host "[4/4] Launching Twitch Streamlink GUI..." -ForegroundColor Green
Start-Process "explorer.exe" -ArgumentList "`"\$ExePath`""
Start-Sleep -Seconds 1

# Force-close parent cmd, OpenConsole, and WindowsTerminal host processes to ensure no empty terminal windows remain
try {
    \$currentPid = \$PID
    \$parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId = \$currentPid").ParentProcessId
    while (\$parentPid) {
        \$proc = Get-Process -Id \$parentPid -ErrorAction SilentlyContinue
        if (\$null -eq \$proc) { break }
        \$procName = \$proc.ProcessName
        \$nextParentPid = (Get-CimInstance Win32_Process -Filter "ProcessId = \$parentPid").ParentProcessId
        if (\$procName -eq "cmd" -or \$procName -eq "powershell" -or \$procName -eq "OpenConsole" -or \$procName -eq "WindowsTerminal") {
            Stop-Process -Id \$parentPid -Force -ErrorAction SilentlyContinue
        }
        if (\$procName -eq "WindowsTerminal" -or \$procName -eq "explorer") { break }
        \$parentPid = \$nextParentPid
    }
} catch {}

[System.Environment]::Exit(0)
''';

    final ps1File = File(ps1Path);
    await ps1File.writeAsString(scriptContent);

    // Launch PowerShell elevated via single clean Start-Process -Verb RunAs
    final psCommand = "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"\"\"$ps1Path\"\"\" -AppPid $currentPid -AppDir \"\"\"$appDir\"\"\" -SourceDir \"\"\"${sourceDir.path}\"\"\" -BackupDir \"\"\"$backupDir\"\"\" -ExePath \"\"\"${exeFile.path}\"\"\"' -Verb RunAs";

    await Process.start(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', psCommand],
      mode: ProcessStartMode.detached,
    );

    await Future.delayed(const Duration(milliseconds: 500));
    exit(0);
  }
}
