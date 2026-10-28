import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/app_services.dart';
import 'package:streamlink_gui/main.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';

import 'fake_desktop.dart';
import 'fake_helix.dart';
import 'fake_process.dart';
import 'memory_storage.dart';

/// The whole app, pumped: the real [TwitchStreamlinkApp] and [MainScreen],
/// with the real refresh controllers, settings repository, player service
/// and Twitch client, over fakes for everything outside the process - a fake
/// Twitch ([FakeHelix]), fake processes, an in-memory config, and a fake
/// window, tray and toasts.
///
/// Before this, no test pumped the main screen at all, so its wiring - which
/// refresh a poll tick starts, what a window coming back does, what saving
/// Settings resets, the order an exit runs in - was checked only by reading
/// the source.
class ScreenHarness {
  ScreenHarness({DateTime? now}) : helix = FakeHelix(now: now);

  final FakeHelix helix;

  /// Every fake writes its calls here, in order.
  final List<String> log = <String>[];

  late final FakeAppWindow window = FakeAppWindow(log);
  late final FakeAppTray tray = FakeAppTray(log);
  final FakeNotifications notifications = FakeNotifications();
  final FakeStartupService startup = FakeStartupService();
  final FakeUpdateService updates = FakeUpdateService();
  final FakeLauncher launcher = FakeLauncher();
  late final FakeTaskkill taskkill = FakeTaskkill(launcher);
  late final TwitchApiService api = helix.service(auth: twitchAuth);
  late final RecordingPlayerService player = RecordingPlayerService(
    log,
    startProcess: launcher.start,
    runProcess: taskkill.run,
    apiService: api,
  );
  late MemoryStorageService storage;

  /// Layout overflows, kept rather than failed on. `flutter test` draws
  /// every glyph as a full em square, so a label sized for Segoe UI - the
  /// dashboard's 'OFFLINE' in its 88px button - overflows here and fits on
  /// Windows. Layout belongs to the sweeps in test/layout; this harness is
  /// about wiring.
  final List<String> overflows = <String>[];
  FlutterExceptionHandler? _onError;
  bool _onErrorReplaced = false;

  void _restoreOnError() {
    if (!_onErrorReplaced) return;
    FlutterError.onError = _onError;
    _onErrorReplaced = false;
  }

  /// The settings a launch starts from when none are given: an account
  /// token, so the followed list and VOD lists load.
  static AppSettings defaultSettings() =>
      AppSettings()..twitchOauthToken = 'oauth:account-token';

  /// Starts the app with [favorites] in its config and runs its startup.
  Future<void> launch(
    WidgetTester tester, {
    List<String> favorites = const <String>[],
    AppSettings? settings,
    Size size = const Size(1400, 900),
  }) async {
    final effective = settings ?? defaultSettings();
    final config = <String, dynamic>{
      'channels': [
        for (final name in favorites) TwitchChannel(username: name).toJson(),
      ],
      'settings': effective.toJson(),
      'local_vods_progress': <String, dynamic>{},
      'downloaded_vods': <String, dynamic>{},
    };
    storage = MemoryStorageService(log: log, config: config);

    // The global look, as main() seeds it before runApp, and put back
    // afterwards for the next test.
    final material = NeuTheme.activeMaterial;
    final dark = themeNotifier.isDarkTheme;
    final light = themeNotifier.lightAccentColor;
    final darkAccent = themeNotifier.darkAccentColor;
    final active = themeNotifier.activeProgressColor;
    final watched = themeNotifier.watchedProgressColor;
    addTearDown(() {
      NeuTheme.activeMaterial = material;
      themeNotifier
        ..isDarkTheme = dark
        ..lightAccentColor = light
        ..darkAccentColor = darkAccent
        ..activeProgressColor = active
        ..watchedProgressColor = watched;
    });
    seedStoredLook(effective);

    _onError = FlutterError.onError;
    _onErrorReplaced = true;
    FlutterError.onError = (details) {
      final text = details.exception.toString();
      if (details.exception is FlutterError && text.contains('overflowed')) {
        overflows.add(text.split('\n').first);
        return;
      }
      _onError?.call(details);
    };
    addTearDown(_restoreOnError);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(TwitchStreamlinkApp(
      // As main() hands it over: read and parsed once, before runApp.
      startup: StartupConfig(
        existed: true,
        data: json.decode(json.encode(config)) as Map<String, dynamic>,
      ),
      services: AppServices(
        storage: storage,
        api: api,
        player: player,
        window: window,
        tray: tray,
        notifications: notifications,
        startup: startup,
        updates: updates,
        clock: () => helix.now,
      ),
    ));
    await settle(tester);
  }

  /// Lets the screen's chains of awaits against the fakes finish, a frame
  /// at a time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump();
    }
  }

  /// Moves the clock the app and the fake Twitch share, and fake time with
  /// it, in [step]s - so each timer on the way fires with the clock where it
  /// would be.
  Future<void> advance(
    WidgetTester tester,
    Duration by, {
    Duration step = const Duration(seconds: 5),
  }) async {
    var left = by;
    while (left > Duration.zero) {
      final next = left < step ? left : step;
      helix.now = helix.now.add(next);
      await tester.pump(next);
      left -= next;
    }
    await settle(tester);
  }

  /// Requests to [path] since [mark] (an index into [FakeHelix.requests]).
  int requestsTo(String path, {int since = 0}) =>
      helix.requests.skip(since).where((r) => r.url.path == path).length;

  /// Unmounts the app and lets whatever its teardown started finish.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    _restoreOnError();
    storage.dispose();
  }
}

/// The real player service, with its stopAll on the shared log.
class RecordingPlayerService extends PlayerService {
  RecordingPlayerService(
    this.events, {
    super.startProcess,
    super.runProcess,
    super.apiService,
  });

  final List<String> events;

  @override
  Future<void> stopAll() {
    events.add('player.stopAll');
    return super.stopAll();
  }
}
