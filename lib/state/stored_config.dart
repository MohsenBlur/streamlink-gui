import '../models/app_settings.dart';
import '../models/twitch_channel.dart';

/// channels_config.json as the first load reads it: every part that can be
/// read, and nothing that cannot.
///
/// The parse lived inline in the main screen's first load, where each of its
/// rules had been learnt from a config that lost data: one malformed channel
/// threw out of the whole load before any channel was installed, and the
/// next autosave wrote the empty list to disk; one unreadable setting, or one
/// position stored as a double, did the same to everything after it. Each
/// part is read on its own now, and a part that cannot be read is left out
/// rather than taking the rest with it.
class StoredConfig {
  const StoredConfig({
    required this.channels,
    required this.skippedChannels,
    required this.settings,
    required this.settingsError,
    required this.localProgress,
    required this.registry,
    required this.downloadHistory,
  });

  /// The favourites that could be read, in order.
  final List<TwitchChannel> channels;

  /// Entries that were there but could not be read as a channel.
  final int skippedChannels;

  /// Null when the file has none, or they cannot be read
  /// ([settingsError]): the defaults stand.
  final AppSettings? settings;
  final Object? settingsError;

  /// The flat watch positions, every usable one; null when the file has no
  /// such map, so what is in memory stands.
  final Map<String, int>? localProgress;

  /// Downloaded VOD id to file path; null when the file has no such map.
  final Map<String, String>? registry;

  /// Every VOD ever downloaded, id to when it first was (DownloadHistory);
  /// null when the file has no such map - one written before it existed,
  /// whose downloads the registry has to stand in for.
  final Map<String, int>? downloadHistory;

  factory StoredConfig.parse(Map<String, dynamic> config) {
    final channels = <TwitchChannel>[];
    var skipped = 0;
    final channelsJson = config['channels'];
    if (channelsJson is List) {
      for (final item in channelsJson) {
        // Per-item parsing: a single malformed entry previously threw out to
        // the outer catch before any channel was installed, leaving the list
        // empty - and the next autosave then wrote that empty list to disk.
        final channel = TwitchChannel.tryFromJson(item);
        if (channel != null) {
          channels.add(channel);
        } else if (item != null) {
          skipped++;
        }
      }
    }

    AppSettings? settings;
    Object? settingsError;
    final settingsJson = config['settings'];
    if (settingsJson is Map<String, dynamic>) {
      try {
        settings = AppSettings.fromJson(settingsJson);
      } catch (e) {
        // Keep going with default settings rather than aborting the whole
        // load - the outer catch would abandon the channel list too, and
        // the next autosave would persist the loss.
        settingsError = e;
      }
    }

    // Skip unusable entries rather than letting one bad value (`v as int`
    // on a double or string) abort the entire config load.
    final progress = _intsOf(config['local_vods_progress']);

    Map<String, String>? registry;
    final downloadedVodsJson = config['downloaded_vods'];
    if (downloadedVodsJson is Map) {
      registry = <String, String>{};
      downloadedVodsJson.forEach((k, v) {
        if (v != null) registry![k.toString()] = v.toString();
      });
    }

    return StoredConfig(
      channels: channels,
      skippedChannels: skipped,
      settings: settings,
      settingsError: settingsError,
      localProgress: progress,
      registry: registry,
      downloadHistory: _intsOf(config['download_history']),
    );
  }

  /// A map of whole numbers, keeping every usable value; null when [json]
  /// is not a map at all.
  static Map<String, int>? _intsOf(Object? json) {
    if (json is! Map) return null;
    final ints = <String, int>{};
    json.forEach((k, v) {
      final value = v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
      if (value != null) ints[k.toString()] = value;
    });
    return ints;
  }
}
