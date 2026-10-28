import 'services/desktop_shell.dart';
import 'services/player_service.dart';
import 'services/startup_service.dart';
import 'services/storage_service.dart';
import 'services/twitch_api_service.dart';
import 'services/update_service.dart';

/// Everything the main screen talks to outside itself, in one place.
///
/// The screen used to construct each of these itself, as field initializers,
/// which is why no test could pump it: the window, the tray and the toasts
/// are plugins with no implementation under `flutter test`, the storage
/// writes the real config, and the player starts real processes. The
/// defaults are exactly what it constructed; tests hand in fakes.
class AppServices {
  AppServices({
    StorageService? storage,
    TwitchApiService? api,
    PlayerService? player,
    this.window = const PluginAppWindow(),
    AppTray? tray,
    this.notifications = const PluginNotifications(),
    StartupService? startup,
    UpdateService? updates,
    this.clock = DateTime.now,
  })  : storage = storage ?? StorageService(),
        api = api ?? TwitchApiService(),
        player = player ?? PlayerService(),
        tray = tray ?? PluginAppTray(),
        startup = startup ?? StartupService(),
        updates = updates ?? UpdateService();

  final StorageService storage;
  final TwitchApiService api;
  final PlayerService player;
  final AppWindow window;
  final AppTray tray;
  final AppNotifications notifications;

  /// The Run key that launches the app at sign-in.
  final StartupService startup;

  /// The GitHub release check and the update apply.
  final UpdateService updates;

  /// What the refresh controllers read the time from, so "how old is this
  /// list" agrees with a test's fake Twitch.
  final DateTime Function() clock;
}
