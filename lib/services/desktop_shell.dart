import 'dart:io';

import 'package:local_notifier/local_notifier.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import '../utils/window_bounds.dart';
import 'native_window.dart';

/// The desktop around the app: its window, its tray icon and its toasts.
///
/// Three thin seams, one call each per plugin call the main screen makes, so
/// the screen can be pumped in a test with fakes standing in for
/// window_manager, system_tray, local_notifier and the runner's window
/// channel. None of them decides anything; what the screen does with the
/// answers stays where it was.

/// The app's window: window_manager for events, visibility and teardown, and
/// the runner's own channel ([NativeWindow]) for showing and geometry.
abstract class AppWindow {
  void addListener(WindowListener listener);
  void removeListener(WindowListener listener);

  Future<bool> isPreventClose();
  Future<bool> isVisible();
  Future<bool> isMinimized();

  /// window_manager's show and focus, the fallback when the runner's own
  /// [showNative] is unavailable.
  Future<void> show();
  Future<void> focus();
  Future<void> hide();

  /// Ends the message loop; no Dart runs after it.
  Future<void> destroy();

  /// [NativeWindow.show]: back the way the runner restored it.
  Future<void> showNative();

  /// [NativeWindow.state]: physical bounds, the monitor, minimized/maximized.
  Future<WindowState?> state();
}

/// The real window.
class PluginAppWindow implements AppWindow {
  const PluginAppWindow();

  @override
  void addListener(WindowListener listener) => windowManager.addListener(listener);

  @override
  void removeListener(WindowListener listener) =>
      windowManager.removeListener(listener);

  @override
  Future<bool> isPreventClose() => windowManager.isPreventClose();

  @override
  Future<bool> isVisible() => windowManager.isVisible();

  @override
  Future<bool> isMinimized() => windowManager.isMinimized();

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> destroy() => windowManager.destroy();

  @override
  Future<void> showNative() => NativeWindow.show();

  @override
  Future<WindowState?> state() => NativeWindow.state();
}

/// What the tray icon reports. Anything else it sends is ignored.
enum TrayEvent { click, doubleClick, rightClick }

/// One row of the tray's context menu; [separator] draws a rule instead.
class TrayMenuEntry {
  const TrayMenuEntry(this.label, this.onClicked);
  const TrayMenuEntry.separator()
      : label = null,
        onClicked = null;

  final String? label;
  final void Function()? onClicked;

  bool get isSeparator => label == null;
}

/// The notification-area icon and its menu.
abstract class AppTray {
  Future<void> init({
    required String title,
    required String iconPath,
    required String toolTip,
  });

  void onEvent(void Function(TrayEvent event) handler);

  Future<void> popUpMenu();

  /// Builds [entries] into a menu and installs it.
  Future<void> setMenu(List<TrayMenuEntry> entries);

  Future<void> setToolTip(String toolTip);
  Future<void> setImage(String iconPath);
  Future<void> destroy();
}

/// The real tray icon (system_tray).
class PluginAppTray implements AppTray {
  PluginAppTray();

  final SystemTray _tray = SystemTray();

  @override
  Future<void> init({
    required String title,
    required String iconPath,
    required String toolTip,
  }) =>
      _tray.initSystemTray(title: title, iconPath: iconPath, toolTip: toolTip);

  @override
  void onEvent(void Function(TrayEvent event) handler) {
    _tray.registerSystemTrayEventHandler((eventName) {
      switch (eventName) {
        case kSystemTrayEventClick:
          handler(TrayEvent.click);
        case kSystemTrayEventDoubleClick:
          handler(TrayEvent.doubleClick);
        case kSystemTrayEventRightClick:
          handler(TrayEvent.rightClick);
      }
    });
  }

  @override
  Future<void> popUpMenu() => _tray.popUpContextMenu();

  @override
  Future<void> setMenu(List<TrayMenuEntry> entries) async {
    final menu = Menu();
    await menu.buildFrom([
      for (final entry in entries)
        if (entry.isSeparator)
          MenuSeparator()
        else
          MenuItemLabel(
            label: entry.label!,
            onClicked: (menuItem) => entry.onClicked?.call(),
          ),
    ]);
    await _tray.setContextMenu(menu);
  }

  @override
  Future<void> setToolTip(String toolTip) => _tray.setToolTip(toolTip);

  @override
  Future<void> setImage(String iconPath) => _tray.setImage(iconPath);

  @override
  Future<void> destroy() => _tray.destroy();
}

/// One toast. [onClick] runs when the user clicks it.
class AppNotification {
  AppNotification({
    required this.title,
    required this.body,
    this.silent = false,
    this.onClick,
  });

  final String title;
  final String body;
  final bool silent;
  final Future<void> Function()? onClick;
}

/// Windows toasts.
abstract class AppNotifications {
  /// Shows [notification]. Throws what the platform throws; callers decide
  /// whether a refused toast matters.
  Future<void> show(AppNotification notification);
}

/// The real toasts (local_notifier).
class PluginNotifications implements AppNotifications {
  const PluginNotifications();

  @override
  Future<void> show(AppNotification notification) {
    final toast = LocalNotification(
      title: notification.title,
      body: notification.body,
      silent: notification.silent,
    );
    final onClick = notification.onClick;
    if (onClick != null) toast.onClick = () => onClick();
    return toast.show();
  }
}

/// Hands things to the Windows shell: a link to the default browser, a file
/// to Explorer.
abstract class AppLauncher {
  /// Whether this platform can do either.
  bool get isSupported;

  Future<void> openUrl(String url);

  /// Opens the folder holding [filePath], with the file selected.
  Future<void> reveal(String filePath);
}

/// The real shell: explorer.exe, started detached.
class ExplorerLauncher implements AppLauncher {
  const ExplorerLauncher();

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<void> openUrl(String url) async {
    // Launched via Explorer, NOT `cmd /c start`.
    //
    // The app now runs inside a job object with KILL_ON_JOB_CLOSE so its
    // helper processes cannot outlive it. Anything the app spawns inherits
    // that job - so a browser started through cmd became a job member and was
    // killed the moment the app closed. Explorer is already running outside
    // our job, so handing the URL to it launches the browser out of reach.
    //
    // THE TRAILING SPACE IS LOAD-BEARING. Do not "clean it up".
    //
    // explorer.exe does not parse its command line with the standard argv
    // rules - handed a bare URL containing `&` it splits it and passes a
    // fragment to the shell. The Twitch sign-in URL ends in
    // `scope=user:read:follows`, so Windows was asked to open a `user:`
    // protocol and answered with "Get an app to open this 'user' link"
    // instead of opening a browser. Every link with a query string was
    // affected; the OAuth one just happened to end in something that looks
    // like a URL scheme.
    //
    // Dart quotes an argument only when it contains a space, tab or quote,
    // and a URL contains none of those, so it arrived unquoted. Appending a
    // space forces the quoting, and a quoted URL is what explorer accepts
    // whole. Measured against a local listener: bare delivers nothing,
    // quoted delivers the full query string, and explorer trims the space.
    await Process.start('explorer.exe', ['$url '],
        mode: ProcessStartMode.detached);
  }

  /// Opens Explorer with [filePath] selected. Launched detached via
  /// explorer.exe so the shell window is not inside our kill-on-close job.
  @override
  Future<void> reveal(String filePath) async {
    await Process.start(
      'explorer.exe',
      ['/select,${filePath.replaceAll('/', r'\')}'],
      mode: ProcessStartMode.detached,
    );
  }
}
