import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/app_services.dart';
import 'package:streamlink_gui/app_startup.dart';
import 'package:streamlink_gui/main.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/oauth_loopback_server.dart';
import 'package:streamlink_gui/services/player_service.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

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
  final FakeShellLauncher shell = FakeShellLauncher();
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

  /// Every Connect Account sign-in started, oldest first.
  final List<FakeSignIn> signIns = <FakeSignIn>[];

  /// The settings a launch starts from when none are given: an account
  /// token, so the followed list and VOD lists load.
  ///
  /// And a download folder that does not exist. AppSettings fills an empty
  /// one in with the user's own Downloads\TwitchVODs - parsing a config
  /// does too - so the screen's downloaded-file scans looked in the real
  /// folder of whoever ran the tests. A test that downloads sets its own.
  static AppSettings defaultSettings() => AppSettings()
    ..twitchOauthToken = 'oauth:account-token'
    ..vodDownloadFolder = noDownloadFolder;

  /// Where [defaultSettings] says downloads go: nowhere that exists.
  static final String noDownloadFolder = p.join(
      Directory.systemTemp.path, 'streamlink_gui_screen_no_downloads');

  /// [defaultSettings] with a player named outright, for the tests that play
  /// a VOD: nothing goes looking for an installed one, and a player of no
  /// known kind has no interface to poll or seek, so where it is comes only
  /// from [RecordingPlayerService.feedPosition].
  static AppSettings playbackSettings() => defaultSettings()
    ..playerType = 'custom'
    ..customPlayerPath = r'C:\nowhere\player.exe';

  /// Starts the app with [favorites] in its config and runs its startup.
  ///
  /// [channels] are favourites with settings of their own, after
  /// [favorites]; [config] adds to or replaces the rest of the file.
  /// [files] are written into the storage folder, by name, before the app
  /// starts - yt-dlp's archive, for one. [watchProgress] and [recents] are
  /// what watch_progress.json and the recently-watched list hold.
  Future<void> launch(
    WidgetTester tester, {
    List<String> favorites = const <String>[],
    List<TwitchChannel> channels = const <TwitchChannel>[],
    AppSettings? settings,
    Map<String, dynamic> config = const <String, dynamic>{},
    Map<String, String> files = const <String, String>{},
    Map<String, dynamic> watchProgress = const <String, dynamic>{},
    List<TwitchVideo> recents = const <TwitchVideo>[],
    Size size = const Size(1400, 900),
    StorageReadFailure? configReadFailure,
    StorageReadFailure? historyReadFailure,
  }) async {
    final effective = settings ?? defaultSettings();
    final stored = <String, dynamic>{
      'channels': [
        for (final name in favorites) TwitchChannel(username: name).toJson(),
        for (final channel in channels) channel.toJson(),
      ],
      'settings': effective.toJson(),
      'local_vods_progress': <String, dynamic>{},
      'downloaded_vods': <String, dynamic>{},
      ...config,
    };
    storage = MemoryStorageService(log: log, config: stored)
      ..watchProgress = json.decode(json.encode(watchProgress))
          as Map<String, dynamic>
      ..recents = [for (final vod in recents) vod.toJson()]
      ..configReadFailure = configReadFailure
      ..historyReadFailure = historyReadFailure;
    files.forEach(
        (name, text) => storage.getStorageFile(name).writeAsStringSync(text));

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

    // A layout overflow fails the test, as in any widget test. They were set
    // aside here while the test font, which draws every glyph a full em
    // wide, ran the dashboard's 'OFFLINE' 5.6px out of its fixed-width
    // button (it fits on Windows); that label now scales down to fit.

    // The title bar asks window_manager whether the window is maximized.
    // No plugin answers here; a test that lets real time pass (runAsync)
    // lets the question land, and it would fail on the missing plugin.
    const windowManager = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowManager,
        (call) async => call.method == 'isMaximized' ? false : null);
    addTearDown(
        () => messenger.setMockMethodCallHandler(windowManager, null));

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(TwitchStreamlinkApp(
      // As main() hands it over: read and parsed once, before runApp.
      startup: StartupConfig(
        existed: true,
        data: configReadFailure != null
            ? null
            : json.decode(json.encode(stored)) as Map<String, dynamic>,
        readFailure: configReadFailure,
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
        launcher: shell,
        clock: () => helix.now,
        signInServer: ({required int port, required String clientId}) =>
            (signIns..add(FakeSignIn(port: port, clientId: clientId))).last,
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

  /// [name]'s row in the sidebar.
  static Finder sidebarRow(String name) => find.descendant(
      of: find.byType(SidebarPanel), matching: find.text(name));

  /// Clicks [name] in the sidebar, which opens its VOD list.
  Future<void> openChannel(WidgetTester tester, String name) async {
    await tester.tap(sidebarRow(name).first);
    await settle(tester);
  }

  /// Back to the welcome screen, from a channel.
  Future<void> goHome(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Dashboard Hub (Return Home)').first);
    await settle(tester);
  }

  /// Lets a dialog or a snackbar finish coming in (or going).
  Future<void> settleRoute(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  /// The player playing [vodId] exits by itself, as when the user closes it.
  ///
  /// A fake process ends on a zero-length timer, which only a pump that
  /// moves the clock fires; awaited here, it would never come.
  Future<void> playerExits(WidgetTester tester, String vodId,
      {int exitCode = 0}) async {
    unawaited(player.playerOf(vodId).exit(exitCode));
    await advance(tester, const Duration(milliseconds: 50),
        step: const Duration(milliseconds: 10));
  }

  /// Chooses Exit in the tray menu and lets the shutdown finish: the players
  /// it stops end on the same zero-length timers.
  Future<void> exitFromTray(WidgetTester tester) async {
    tray.choose('Exit');
    await advance(tester, const Duration(milliseconds: 100),
        step: const Duration(milliseconds: 10));
  }

  /// Requests to [path] since [mark] (an index into [FakeHelix.requests]).
  int requestsTo(String path, {int since = 0}) =>
      helix.requests.skip(since).where((r) => r.url.path == path).length;

  /// Unmounts the app and lets whatever its teardown started finish.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    storage.dispose();
  }
}

/// The real player service, with its stopAll on the shared log, a port
/// check that binds nothing, and a fake feed of where a playing VOD is.
class RecordingPlayerService extends PlayerService {
  RecordingPlayerService(
    this.events, {
    super.startProcess,
    super.runProcess,
    super.apiService,
  }) : _api = apiService ?? TwitchApiService();

  final List<String> events;
  final TwitchApiService _api;
  int _nextPort = PlayerService.firstPlayerPort;

  @override
  Future<void> stopAll() {
    events.add('player.stopAll');
    return super.stopAll();
  }

  /// A port of its own for each player, without the probe: binding a real
  /// socket never completes inside testWidgets' fake-async zone, so a launch
  /// stalled there. No process is real, so nothing listens on it either.
  @override
  Future<int> getNextAvailablePlayerPort() async => _nextPort++;

  /// The player playing [vodId] says it is at [seconds], [sessionAge] into
  /// its session; answers whether the app kept the position.
  ///
  /// Through the one seam the progress tracker reports through, with what
  /// it reports: the same progress fraction, the same age. The tracker
  /// itself - polling a player, corroborating what it says, holding back a
  /// session that has not landed - has its own tests against a fake VLC
  /// (watch_progress_sync_test, player_progress_test); this is what the
  /// screen does with a position once one arrives.
  bool feedPosition(
    String vodId,
    int seconds, {
    String? duration,
    Duration sessionAge = const Duration(minutes: 5),
  }) {
    final total =
        _api.parseDurationToSeconds(duration ?? activePlayerDurations[vodId] ?? '');
    final progress = total > 0 ? seconds / total : 0.0;
    return recordWatchProgress?.call(
            vodId, seconds, progress, sessionAge.inMilliseconds) ??
        true;
  }

  /// The fake process playing [vodId].
  FakeProcess playerOf(String vodId) {
    final proc = activePlayerProcesses[vodId];
    if (proc is! FakeProcess) {
      throw StateError('no player is running for $vodId');
    }
    return proc;
  }
}

/// A Connect Account sign-in that listens on nothing: the test ends it with
/// [succeed], [deny] or [timeOut], as Twitch's redirect (or its absence)
/// would. The real listener has its own tests (oauth_loopback_server_test).
class FakeSignIn extends OAuthLoopbackServer {
  FakeSignIn({required super.port, required super.clientId});

  final Completer<OAuthLoopbackResult> _done =
      Completer<OAuthLoopbackResult>();
  bool started = false;
  bool closed = false;

  @override
  Future<void> start() async => started = true;

  @override
  Future<OAuthLoopbackResult> get result => _done.future;

  @override
  Future<void> close() async {
    closed = true;
    _end(const OAuthLoopbackResult(OAuthLoopbackOutcome.cancelled));
  }

  void succeed(String token) => _end(
      OAuthLoopbackResult(OAuthLoopbackOutcome.token, accessToken: token));
  void deny(String why) =>
      _end(OAuthLoopbackResult(OAuthLoopbackOutcome.denied, error: why));
  void timeOut() =>
      _end(const OAuthLoopbackResult(OAuthLoopbackOutcome.timedOut));

  void _end(OAuthLoopbackResult result) {
    if (!_done.isCompleted) _done.complete(result);
  }
}
