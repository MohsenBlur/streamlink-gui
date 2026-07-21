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

      // Check if user explicitly wants portable mode (by placing portable.txt in exeDir)
      final portableMarker = File('$exeDir/portable.txt');
      if (portableMarker.existsSync()) {
        return exeFile;
      }

      // Default persistent storage: AppData directory
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

  Future<List<Map<String, dynamic>>> loadRecentWatchedVods() async {
    try {
      final file = getStorageFile('recent_watched_vods.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = json.decode(content);
          if (decoded is List) {
            return decoded.map((item) => Map<String, dynamic>.from(item)).toList();
          }
        }
      }
    } catch (_) {}
    return [];
  }

  Future<void> saveRecentWatchedVods(List<Map<String, dynamic>> list) async {
    final file = getStorageFile('recent_watched_vods.json');
    final content = json.encode(list);
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
    } catch (_) {
      try {
        await file.writeAsString(content, flush: true);
      } catch (_) {}
    }
  }
}
