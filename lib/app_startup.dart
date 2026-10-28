import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'models/app_settings.dart';
import 'services/crash_log.dart';
import 'services/file_dialogs.dart';
import 'services/native_window.dart';
import 'state/app_shell_controller.dart';
import 'theme/material/app_material.dart';
import 'theme/neu_theme.dart';
import 'theme/theme_notifier.dart';
import 'utils/color_utils.dart';
import 'utils/window_bounds.dart';

/// What main() does to the window and the look before and just after the
/// first frame, outside any screen: seeding the stored look, the frame style
/// and placement, and the check once the first frame is up.

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

