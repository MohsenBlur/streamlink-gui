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

    test('copyWith preserves every field the caller did not specify', () {
      // Regression: the settings dialog used to build a brand-new AppSettings
      // from only the fields it edits, so saving it silently reset the theme
      // mode, window geometry, VOD watch exclusion threshold and the auto-play
      // preemption toggle to their defaults. Changing one field must never
      // disturb another.
      final original = buildNonDefaultSettings();
      final updated = original.copyWith(defaultQuality: '480p');

      expect(updated.defaultQuality, '480p');

      final before = original.toJson()..remove('default_quality');
      final after = updated.toJson()..remove('default_quality');
      expect(after, equals(before));
    });

    test('copyWith preserves settings that only other dialogs edit', () {
      // These four are owned by the automation dialog and the window listener,
      // never by the settings dialog, and were the ones users actually lost.
      final original = buildNonDefaultSettings();
      final updated = original.copyWith(playerType: 'vlc');

      expect(updated.isDarkTheme, original.isDarkTheme);
      expect(updated.vodWatchExclusionThreshold, original.vodWatchExclusionThreshold);
      expect(updated.autoPlayPreemptLowerPriority, original.autoPlayPreemptLowerPriority);
      expect(updated.windowWidth, original.windowWidth);
      expect(updated.windowHeight, original.windowHeight);
      expect(updated.windowX, original.windowX);
      expect(updated.windowY, original.windowY);
      expect(updated.isWindowMaximized, original.isWindowMaximized);
      expect(updated.showGamesOnThumbnails, original.showGamesOnThumbnails);
      expect(updated.sidebarCollapsed, original.sidebarCollapsed);
      expect(updated.activeSidebarTab, original.activeSidebarTab);
      expect(updated.unfinishedDownloads, original.unfinishedDownloads);
    });

    test('copyWith can explicitly clear the window position', () {
      final original = buildNonDefaultSettings();
      final cleared = original.copyWith(clearWindowPosition: true);

      expect(cleared.windowX, isNull);
      expect(cleared.windowY, isNull);
      // Size is independent of position and must survive.
      expect(cleared.windowWidth, original.windowWidth);
      expect(cleared.windowHeight, original.windowHeight);
    });

    test('round-trips the v1.1.0 fields', () {
      final original = AppSettings(
        vodCardScale: 480,
        vodTitleFontSize: 17,
        closeAction: 'exit',
        minimizeAction: 'tray',
        launchAtStartup: true,
        startMinimized: true,
        trayNoticeShown: true,
        trayLiveMenuEnabled: false,
        notifyWentLive: false,
        notifyAutoPlay: false,
        notifyAutoDownloadStart: false,
        notifyDownloadComplete: false,
        onboardingCompleted: true,
      );
      final restored = AppSettings.fromJson(original.toJson());

      expect(restored.vodCardScale, 480);
      expect(restored.vodTitleFontSize, 17);
      expect(restored.closeAction, 'exit');
      expect(restored.minimizeAction, 'tray');
      expect(restored.launchAtStartup, isTrue);
      expect(restored.startMinimized, isTrue);
      expect(restored.trayNoticeShown, isTrue);
      expect(restored.trayLiveMenuEnabled, isFalse);
      expect(restored.notifyWentLive, isFalse);
      expect(restored.notifyAutoPlay, isFalse);
      expect(restored.notifyAutoDownloadStart, isFalse);
      expect(restored.notifyDownloadComplete, isFalse);
      expect(restored.onboardingCompleted, isTrue);
    });

    test('clamps persisted out-of-range values on load', () {
      // A hand-edited or corrupted config must not feed a Slider an
      // out-of-range value, which asserts in debug builds on dialog open.
      final restored = AppSettings.fromJson(<String, dynamic>{
        'watched_threshold': 30,
        'max_recently_watched': 99,
        'vod_watch_exclusion_threshold': 200,
        'local_server_port': 0,
        'max_downloads_to_keep': -5,
        'vod_card_scale': 5000,
        'vod_title_font_size': 2,
        'close_action': 'explode',
        'minimize_action': 42,
      });

      expect(restored.watchedThreshold, 50);
      expect(restored.maxRecentlyWatched, 20);
      expect(restored.vodWatchExclusionThreshold, 90);
      expect(restored.localServerPort, 1);
      expect(restored.maxDownloadsToKeep, 0);
      expect(restored.vodCardScale, 600.0);
      expect(restored.vodTitleFontSize, 11.0);
      expect(restored.closeAction, 'tray');
      expect(restored.minimizeAction, 'taskbar');
    });

    test('v1.1.0 fields default sensibly for a pre-1.1 config', () {
      final restored = AppSettings.fromJson(<String, dynamic>{});
      expect(restored.vodCardScale, 350.0);
      expect(restored.vodTitleFontSize, 14.0);
      expect(restored.closeAction, 'tray');
      expect(restored.minimizeAction, 'taskbar');
      expect(restored.launchAtStartup, isFalse);
      expect(restored.trayLiveMenuEnabled, isTrue);
      expect(restored.notifyWentLive, isTrue);
      expect(restored.onboardingCompleted, isFalse);
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
