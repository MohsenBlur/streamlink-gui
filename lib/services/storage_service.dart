import 'dart:convert';
import 'dart:io';
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';

class StorageService {
  File getStorageFile(String filename) {
    try {
      final exePath = Platform.resolvedExecutable;
      if (exePath.contains('flutter_tester') || exePath.contains('flutter_tools') || exePath.contains('dart')) {
        return File(filename);
      }
      final exeDir = Directory(exePath).parent.path;
      final exeFile = File('$exeDir/$filename');

      // Helper to check if a directory is writable by attempting to create and delete a temporary file
      bool isDirWritable(String path) {
        try {
          final testFile = File('$path/.write_test');
          testFile.writeAsStringSync('test');
          testFile.deleteSync();
          return true;
        } catch (_) {
          return false;
        }
      }

      // If the executable directory is writable, keep portable mode configuration in exeDir
      if (isDirWritable(exeDir)) {
        return exeFile;
      }

      // If not writable (e.g., Program Files), use the user's AppData/Config directory
      String? appDataDir;
      if (Platform.isWindows) {
        appDataDir = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'];
      } else if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          appDataDir = '$home/Library/Application Support';
        }
      } else if (Platform.isLinux) {
        appDataDir = Platform.environment['XDG_CONFIG_HOME'];
        if (appDataDir == null || appDataDir.isEmpty) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            appDataDir = '$home/.config';
          }
        }
      }

      if (appDataDir != null) {
        final configDir = Directory('$appDataDir/TwitchStreamlinkGUI');
        final appDataFile = File('${configDir.path}/$filename');

        // Migrate existing config file from exeDir if it exists but the AppData config doesn't
        if (!appDataFile.existsSync() && exeFile.existsSync()) {
          try {
            if (!configDir.existsSync()) {
              configDir.createSync(recursive: true);
            }
            exeFile.copySync(appDataFile.path);
          } catch (_) {
            // Ignore migration failure, fallback to clean config creation
          }
        } else if (!appDataFile.existsSync()) {
          try {
            if (!configDir.existsSync()) {
              configDir.createSync(recursive: true);
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

  Future<Map<String, dynamic>?> loadConfig() async {
    try {
      final file = _getStorageFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = json.decode(content);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveConfig(
    List<TwitchChannel> channels,
    AppSettings settings,
    Map<String, int> localProgress,
    Map<String, String> downloadedVods,
  ) async {
    final file = _getStorageFile();
    final usernames = channels.map((c) => c.username).toList();
    final config = {
      'channels': usernames,
      'settings': settings.toJson(),
      'local_vods_progress': localProgress,
      'downloaded_vods': downloadedVods,
    };
    final content = json.encode(config);
    final tempFile = File('${file.path}.tmp');
    try {
      if (!tempFile.parent.existsSync()) {
        tempFile.parent.createSync(recursive: true);
      }
      await tempFile.writeAsString(content, flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);
    } catch (e) {
      // Fallback if atomic rename fails
      try {
        await file.writeAsString(content, flush: true);
      } catch (_) {}
    }
  }
}
