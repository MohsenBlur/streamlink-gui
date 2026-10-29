import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/services/storage_service.dart';

/// The app's three files, kept in memory.
///
/// For pumping the main screen: a real file read or write never completes
/// inside testWidgets' fake-async zone (it waits on the real event loop,
/// which `pump` does not run), so the screen's load would stall at its first
/// read. What goes into each file is the real shape - the same keys
/// [StorageService.saveConfig] writes - so a test reads back what the app
/// would have saved. Sealing tokens at rest is StorageService's own concern,
/// with its own tests, and is left out.
class MemoryStorageService extends StorageService {
  MemoryStorageService({this.log, Map<String, dynamic>? config})
      : config = config == null ? null : _copy(config);

  /// Shared with the other fakes, to check the order of an exit's steps.
  final List<String>? log;

  /// channels_config.json, as last written; null before the first save.
  Map<String, dynamic>? config;
  Map<String, dynamic> watchProgress = <String, dynamic>{};
  List<Map<String, dynamic>> recents = <Map<String, dynamic>>[];

  int configWrites = 0;
  int progressWrites = 0;
  int recentsWrites = 0;

  /// When set, reading the config throws it: the file is there but could
  /// not be read (see StorageReadFailure).
  StorageReadFailure? configReadFailure;

  /// The same for the watch-progress sidecar and the recents list.
  StorageReadFailure? historyReadFailure;

  /// The settings as last saved.
  AppSettings? get savedSettings {
    final stored = config?['settings'];
    return stored is Map<String, dynamic> ? AppSettings.fromJson(_copy(stored)) : null;
  }

  late final Directory _dir =
      Directory.systemTemp.createTempSync('streamlink_gui_screen_');

  /// A path only: nothing here reads or writes it.
  @override
  File getStorageFile(String filename) => File(p.join(_dir.path, filename));

  @override
  Future<Map<String, dynamic>?> loadConfig() async {
    final failure = configReadFailure;
    if (failure != null) throw failure;
    return config == null ? null : _copy(config!);
  }

  @override
  Future<void> saveConfig(
    List<TwitchChannel> channels,
    AppSettings settings,
    Map<String, int> localProgress,
    Map<String, String> downloadedVods, {
    Map<String, int>? downloadHistory,
  }) async {
    configWrites++;
    log?.add('save.config');
    config = _copy({
      'channels': channels.map((c) => c.toJson()).toList(),
      'settings': settings.toJson(),
      'local_vods_progress': localProgress,
      'downloaded_vods': downloadedVods,
      'download_history': ?downloadHistory,
    });
  }

  @override
  Future<Map<String, dynamic>> loadWatchProgress() async {
    final failure = historyReadFailure;
    if (failure != null) throw failure;
    return _copy(watchProgress);
  }

  @override
  Future<void> saveWatchProgress(Map<String, dynamic> data) async {
    progressWrites++;
    log?.add('save.progress');
    watchProgress = _copy(data);
  }

  @override
  Future<List<Map<String, dynamic>>> loadRecentWatchedVods() async => [
        for (final item in recents) _copy(item),
      ];

  @override
  Future<void> saveRecentWatchedVods(List<Map<String, dynamic>> list) async {
    recentsWrites++;
    log?.add('save.recents');
    recents = [for (final item in list) _copy(item)];
  }

  void dispose() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  /// Through JSON, as the file would be: no shared references either way.
  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      json.decode(json.encode(value)) as Map<String, dynamic>;
}
