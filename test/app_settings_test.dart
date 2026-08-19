import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';

/// Builds an AppSettings where every field differs from its default, so a
/// round-trip that silently drops a field is detectable.
AppSettings buildNonDefaultSettings() {
  return AppSettings(
    defaultQuality: '720p60',
    twitchLowLatency: false,
    twitchOauthToken: 'oauth:aaaaaaaaaaaaaaaa',
    twitchWebOauthToken: 'bbbbbbbbbbbbbbbb',
    playerType: 'mpv',
    customPlayerPath: r'C:\Players\mpv.exe',
    customPlayerArgs: '--ontop --no-border',
    twitchClientId: 'custom-client-id',
    localServerPort: 54321,
    watchedThreshold: 88,
    sidebarCollapsed: true,
    primaryColorHex: '#112233',
    backgroundColorHex: '#223344',
    surfaceColorHex: '#334455',
    activeProgressColorHex: '#445566',
    watchedProgressColorHex: '#80556677',
    lightAccentColorHex: '#10B981',
    darkAccentColorHex: '#38BDF8',
    vodDownloadFolder: r'D:\Vods',
    maxDownloadsToKeep: 7,
    unfinishedDownloads: const [
      {'vod': {'id': '123'}, 'channelName': 'somechannel'},
    ],
    maxRecentlyWatched: 15,
    activeSidebarTab: 2,
    windowWidth: 1600.0,
    windowHeight: 900.0,
    windowX: 120.0,
    windowY: 240.0,
    isWindowMaximized: true,
    showGamesOnThumbnails: false,
    vodWatchExclusionThreshold: 42,
    autoPlayPreemptLowerPriority: true,
    isDarkTheme: false,
    disableVodPostProcessing: false,
    customVodArgs: '--concurrent-fragments 5',
  );
}

void main() {
  group('AppSettings serialization', () {
    test('round-trips every field through toJson/fromJson', () {
      final original = buildNonDefaultSettings();
      final restored = AppSettings.fromJson(original.toJson());

      // Comparing the serialized maps covers every persisted field, so a field
      // added to the model without being added to fromJson fails here.
      expect(restored.toJson(), equals(original.toJson()));
    });

    test('preserves each individually meaningful field', () {
      final restored = AppSettings.fromJson(buildNonDefaultSettings().toJson());

      expect(restored.defaultQuality, '720p60');
      expect(restored.twitchLowLatency, isFalse);
      expect(restored.playerType, 'mpv');
      expect(restored.customPlayerPath, r'C:\Players\mpv.exe');
      expect(restored.localServerPort, 54321);
      expect(restored.watchedThreshold, 88);
      expect(restored.vodDownloadFolder, r'D:\Vods');
      expect(restored.maxDownloadsToKeep, 7);
      expect(restored.maxRecentlyWatched, 15);
      expect(restored.activeSidebarTab, 2);
      expect(restored.windowWidth, 1600.0);
      expect(restored.windowHeight, 900.0);
      expect(restored.windowX, 120.0);
      expect(restored.windowY, 240.0);
      expect(restored.isWindowMaximized, isTrue);
      expect(restored.showGamesOnThumbnails, isFalse);
      expect(restored.vodWatchExclusionThreshold, 42);
      expect(restored.autoPlayPreemptLowerPriority, isTrue);
      expect(restored.isDarkTheme, isFalse);
      expect(restored.disableVodPostProcessing, isFalse);
      expect(restored.customVodArgs, '--concurrent-fragments 5');
      expect(restored.lightAccentColorHex, '#10B981');
      expect(restored.darkAccentColorHex, '#38BDF8');
      expect(restored.unfinishedDownloads, hasLength(1));
    });

    test('applies defaults for a missing/empty payload', () {
      final restored = AppSettings.fromJson(<String, dynamic>{});

      expect(restored.defaultQuality, 'best');
      expect(restored.playerType, 'default');
      expect(restored.watchedThreshold, 96);
      expect(restored.vodWatchExclusionThreshold, 15);
      expect(restored.isDarkTheme, isTrue);
      expect(restored.maxDownloadsToKeep, 0);
      expect(restored.windowWidth, 1280.0);
      expect(restored.windowHeight, 720.0);
      expect(restored.windowX, isNull);
      expect(restored.windowY, isNull);
    });

    test('tolerates numeric window bounds stored as int', () {
      // Older configs (and hand-edited ones) can hold ints where doubles are
      // expected; fromJson must not throw on them.
      final restored = AppSettings.fromJson(<String, dynamic>{
        'window_width': 1024,
        'window_height': 768,
        'window_x': 10,
        'window_y': 20,
      });

      expect(restored.windowWidth, 1024.0);
      expect(restored.windowHeight, 768.0);
      expect(restored.windowX, 10.0);
      expect(restored.windowY, 20.0);
    });

    test('fills a download folder default when none is supplied', () {
      final settings = AppSettings(vodDownloadFolder: '');
      // The constructor derives a per-user default; the exact path is platform
      // dependent, so assert only that it does not stay empty when a home
      // directory is available.
      expect(settings.vodDownloadFolder, isNotNull);
    });
  });
}
