import 'dart:async';
import 'dart:io' show pid;

import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

import 'models/app_settings.dart';
import 'services/crash_log.dart';
import 'services/file_dialogs.dart';
import 'services/native_window.dart';
import 'services/startup_service.dart';
import 'services/storage_service.dart';
import 'services/update_service.dart';
import 'state/app_shell_controller.dart';
import 'theme/material/app_material.dart';
import 'theme/material/lit_surface.dart';
import 'theme/neu_theme.dart';
import 'theme/theme_notifier.dart';
import 'theme/type_probe.dart';
import 'utils/color_utils.dart';
import 'utils/window_bounds.dart';

/// What main() does before and just after the first frame, outside any
/// screen: the startup itself ([startApp]), seeding the stored look, the
/// frame style and placement, and the check once the first frame is up.

/// Seeds the look from the settings main() already parsed, BEFORE the first
/// frame.
///
/// `NeuTheme.activeMaterial` defaults to rack and `themeNotifier.isDarkTheme`
/// to true, and both were only corrected later, inside `_loadChannels`'s
/// second config read. The window is shown from the first-frame callback
/// (`flutter_window.cpp`), so a user on Soft, or on the light theme, saw at
/// least one fully presented frame of the wrong look before it snapped -
/// a flash of a different material, not just a different colour.
///
/// The first load's own `setMaterial`/`setDarkTheme`/accent/progress calls
/// then no-op, because every setter early-returns when the value is
/// unchanged. They have to: the first load runs from MainScreen's initState,
/// inside the build, and a notification from there marks the app's own
/// ListenableBuilder dirty mid-build. The progress colours were left out of
/// this seeding and `updateTheme` notified unconditionally, so every launch
/// did exactly that - an assertion on each debug launch, and a second build
/// of the whole MaterialApp in the first frame of a release one.
void seedStoredLook(AppSettings settings) {
  final storedMaterial = AppMaterial.fromKey(settings.material);
  if (storedMaterial != null && MaterialSpec.isImplemented(storedMaterial)) {
    NeuTheme.activeMaterial = storedMaterial;
  }
  themeNotifier.isDarkTheme = settings.isDarkTheme;
  themeNotifier.lightAccentColor = parseHexColor(
      settings.lightAccentColorHex, NeuTheme.defaultLightAccent);
  themeNotifier.darkAccentColor =
      parseHexColor(settings.darkAccentColorHex, NeuTheme.defaultDarkAccent);
  // User-configurable hex settings; these are their defaults, as the first
  // load reads them (_loadChannels), not theme colors.
  themeNotifier.activeProgressColor = parseHexColor(
      settings.activeProgressColorHex, const Color(0xFF9146FF));
  themeNotifier.watchedProgressColor = parseHexColor(
      settings.watchedProgressColorHex, const Color(0x804CAF50));
}

/// The stored look, through the notifying setters: what the first load does
/// with the settings it read (MainScreen's _loadChannels), which may be a
/// fresher read than the one [seedStoredLook] had. Every setter returns early
/// on an unchanged value, so after a seed from the same settings this
/// notifies nothing (see [seedStoredLook]).
void applyStoredLook(AppSettings settings) {
  themeNotifier.setDarkTheme(settings.isDarkTheme);
  // Resolved, not clamped. An unknown key - a material this build does not
  // have, from a newer one that did - falls back for the session and is left
  // alone in the file, rather than being rewritten to `rack` by the next
  // window resize.
  final storedMaterial = AppMaterial.fromKey(settings.material);
  if (storedMaterial != null && MaterialSpec.isImplemented(storedMaterial)) {
    themeNotifier.setMaterial(storedMaterial);
  }

  // Restore the accent the user actually picked. Previously this read
  // `primaryColorHex`, a field no code path ever wrote, so it was always the
  // default purple and silently overwrote the saved accent on every launch
  // while the real value sat unused in the config.
  themeNotifier.setLightAccent(
    parseHexColor(settings.lightAccentColorHex, NeuTheme.defaultLightAccent),
  );
  themeNotifier.setDarkAccent(
    parseHexColor(settings.darkAccentColorHex, NeuTheme.defaultDarkAccent),
  );
  themeNotifier.updateTheme(
    // User-configurable hex settings; these are their defaults, not theme
    // colors.
    activeProgress: parseHexColor(
        settings.activeProgressColorHex, const Color(0xFF9146FF)),
    watchedProgress: parseHexColor(
        settings.watchedProgressColorHex, const Color(0x804CAF50)),
  );
}

/// The frame style, close interception and geometry - all before the first
/// frame, while the window is still hidden.
///
/// The runner creates the window hidden and shows it from its first-frame
/// callback. Everything that changes the frame therefore has to land before
/// that frame, or the user watches it happen: the window used to appear at
/// the runner's default spot on the primary monitor and then jump, across
/// monitors and a DPI change, to where it was saved - and that move racing
/// the first frame is when the content view was found hidden (the
/// invisible-window bug, audit C1).
///
/// Geometry no longer goes through window_manager. Its setSize and
/// setPosition convert with the window's devicePixelRatio of that instant,
/// which during startup on mixed-DPI monitors is whichever monitor the
/// window happens to be on; the runner's channel places it in physical
/// pixels instead, and shows it maximized as part of the show itself.
Future<void> prepareWindow(
  AppSettings settings, {
  required bool startHidden,
  required void Function(String) milestone,
  required CrashLog log,
}) async {
  try {
    await windowManager.ensureInitialized();
    // No size, position or show in here (see above). The hidden title bar
    // does belong before the first frame: it changes the client area, so it
    // decides the size that frame is laid out at.
    await windowManager.waitUntilReadyToShow(const WindowOptions(
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    ));
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(kMinWindowSize);
    // The owner of every file and folder dialog (FileDialogs): window_manager
    // reports the runner's top-level window, the root of the view.
    FileDialogs.ownerWindow = await windowManager.getId();
  } catch (e, st) {
    log.error('window setup', e, st);
  }

  try {
    final monitors = await NativeWindow.monitors();
    milestone('monitors: ${monitors.join('; ')}');
    final plan = planWindowRestore(
      monitors: monitors,
      saved: settings.windowPlacement,
      legacyX: settings.windowX,
      legacyY: settings.windowY,
      legacyWidth: settings.windowWidth,
      legacyHeight: settings.windowHeight,
      maximized: settings.isWindowMaximized,
    );
    final placed = await NativeWindow.setInitialPlacement(plan.bounds,
        maximized: plan.maximized, hidden: startHidden);
    milestone('placement: $plan${startHidden ? ', starting hidden' : ''}; '
        'window now $placed');
  } catch (e, st) {
    // The window stays where the runner created it, and the runner still
    // shows it on the first frame.
    log.error('window placement', e, st);
  }
}

/// Records what the window looks like once the first frame is up, and puts
/// right what it can.
///
/// This is the evidence the invisible-window reports never had: whether the
/// frame was shown, whether the content view inside it was, where, at which
/// DPI. The runner already re-asserts the content view whenever the frame is
/// shown or moved; asking it to show again here covers a frame that never
/// appeared at all.
Future<void> checkWindowAfterFirstFrame({
  required bool startHidden,
  required void Function(String) milestone,
}) async {
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  try {
    final state = await NativeWindow.state();
    // What the engine laid out at, beside what the frame is: a DPI change
    // the engine missed shows up here as a ratio that does not match the
    // window's DPI (content laid out at a stale size, audit M2).
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final view = views.isEmpty ? null : views.first;
    final layout = view == null
        ? ''
        : '; laid out at ${view.physicalSize.width.round()}x'
            '${view.physicalSize.height.round()} @ ${view.devicePixelRatio}';
    milestone('window after first frame: $state$layout');
    if (!startHidden && AppShellController.windowHiddenByUser) {
      milestone('hidden to the tray since; leaving it as it is');
    }
    if (shouldReshowAfterFirstFrame(state,
        startHidden: startHidden,
        hiddenByUser: AppShellController.windowHiddenByUser)) {
      milestone('window or its content is not visible; showing it again');
      await NativeWindow.show();
      milestone('window after re-show: ${await NativeWindow.state()}');
    }
  } catch (e, st) {
    CrashLog.current?.error('window check', e, st);
  }
}

/// Everything main() does before and around runApp, inside its guarded
/// zone: the crash log and the startup milestones, the one read of the
/// config, the surface engine, toasts, the Run key, the window and the
/// look - then [app], the app itself, built from the config read and
/// whether the window starts hidden.
///
/// Here rather than in main.dart, which holds the app; [app] is how it is
/// handed over without this file importing that one.
Future<void> startApp(
  List<String> args, {
  required Widget Function(StartupConfig? startup, bool startHidden) app,
}) async {
  final launch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  final storage = StorageService();
  // Beside the config, so portable mode keeps it beside the exe too.
  final crashLog = CrashLog(storage.getStorageFile(CrashLog.fileName));
  CrashLog.install(crashLog);
  // Startup milestones. Each one is a line in crash.log, so a launch that
  // never shows its window still says how far it got.
  void milestone(String message) =>
      crashLog.milestone('[startup +${launch.elapsedMilliseconds}ms] $message');
  milestone('launch v${UpdateService.currentVersion}, pid $pid'
      '${args.isEmpty ? '' : ', args $args'}');

  // One read and one parse of the config for the whole startup. main() used
  // to read and decrypt it here and _loadChannels read and decrypted it all
  // again a moment later; the snapshot now goes down to the first load.
  //
  // Nothing before runApp may throw: the window is only ever shown by the
  // first frame, so an exception here is an app that never appears. A load
  // that fails outright leaves the snapshot out, and the first load reads
  // the file again itself - never an empty snapshot that the next autosave
  // would write over a config that is still on disk.
  StartupConfig? startup;
  try {
    startup = await storage.loadStartupConfig();
    milestone(startup.isFirstRun
        ? 'config: none, first run'
        : (startup.data == null
            ? 'config: unreadable, quarantined; using defaults'
            : 'config: loaded'));
    // The plaintext copy an older build left beside the exe. Only after a
    // load: a config that would not load is quarantined, and the next
    // launch's migration recovers from that copy.
    if (startup.data != null) {
      final mirror = storage.dropStaleConfigMirror();
      if (mirror != null) milestone(mirror);
    }
  } catch (e, st) {
    crashLog.error('config', e, st);
  }
  final settings = startup?.parseSettings() ?? AppSettings();

  // The material engine's fragment program, before the first frame so the
  // first paint is already lit. Milliseconds; degrades to the Canvas engine
  // on failure rather than to a blank window. Settings' "Simple rendering"
  // and --canvas-engine skip the shader outright - the switch for a machine
  // where it renders, but slowly or wrongly, which no self-test can see.
  final canvasReason = args.contains('--canvas-engine')
      ? '--canvas-engine flag'
      : (settings.canvasEngine ? 'Simple rendering setting' : null);
  await LitSurfaceProgram.load(
      forceCanvas: canvasReason != null, forceCanvasReason: canvasReason);
  milestone('surface engine: ${LitSurfaceProgram.status}');

  // The typography gate. Off unless asked for, and it cannot be a unit test:
  // `flutter test` has no system fonts and CI is ubuntu, so an assertion about
  // Bahnschrift there would measure the fallback against itself and pass.
  if (TypeProbe.enabled) {
    await TypeProbe.run();
  }
  try {
    await localNotifier.setup(
      appName: 'Twitch Streamlink GUI',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );
  } catch (e, st) {
    // Toasts are a nicety; a failure here must not stop the window appearing.
    crashLog.error('notifications', e, st);
  }

  // Autostart launches pass --start-minimized; the manual-launch preference
  // does the same thing without the flag.
  final bool startMinimized =
      args.contains('--start-minimized') || settings.startMinimized;

  // Re-writing the Run value at every launch silently heals a moved install.
  if (settings.launchAtStartup) {
    StartupService().sync(true);
  }

  await prepareWindow(settings,
      startHidden: startMinimized, milestone: milestone, log: crashLog);

  seedStoredLook(settings);

  runApp(app(startup, startMinimized));
  milestone('runApp');

  unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
    milestone('first frame rasterized');
    return checkWindowAfterFirstFrame(
        startHidden: startMinimized, milestone: milestone);
  }));
}
