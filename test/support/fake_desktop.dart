import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:streamlink_gui/services/desktop_shell.dart';
import 'package:streamlink_gui/services/startup_service.dart';
import 'package:streamlink_gui/services/update_service.dart';
import 'package:streamlink_gui/utils/window_bounds.dart';
import 'package:window_manager/window_manager.dart';

/// The desktop the main screen runs on, for tests: a window, a tray icon and
/// toasts that record what was asked of them, and that the test drives as
/// Windows would (a close, a minimize, coming back from the tray).
///
/// Every fake writes to an optional shared [log], so a test can check the
/// order things happened in across all of them.

/// A window that is shown, hidden and destroyed in memory.
///
/// Showing and hiding report their events the way window_manager does on
/// Windows - asynchronously, after the call - so the screen sees the same
/// sequence a real show from the tray produces.
class FakeAppWindow implements AppWindow {
  FakeAppWindow([this.log]);

  final List<String>? log;
  final List<WindowListener> _listeners = <WindowListener>[];

  bool visible = true;
  bool minimized = false;
  bool maximized = false;
  bool preventClose = true;
  bool destroyed = false;

  /// What the runner reports for [state]. Physical pixels, one monitor.
  Rect bounds = const Rect.fromLTWH(100, 100, 1400, 900);

  /// How many times each call was made.
  final Map<String, int> calls = <String, int>{};

  int listenerCount() => _listeners.length;

  void _record(String call) {
    calls[call] = (calls[call] ?? 0) + 1;
    log?.add('window.$call');
  }

  /// Delivers [eventName] to every listener the way window_manager's channel
  /// handler does: onWindowEvent first, then the named callback.
  void emit(String eventName) {
    for (final listener in List<WindowListener>.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      listener.onWindowEvent(eventName);
      switch (eventName) {
        case kWindowEventClose:
          listener.onWindowClose();
        case kWindowEventFocus:
          listener.onWindowFocus();
        case kWindowEventBlur:
          listener.onWindowBlur();
        case kWindowEventMaximize:
          listener.onWindowMaximize();
        case kWindowEventUnmaximize:
          listener.onWindowUnmaximize();
        case kWindowEventMinimize:
          listener.onWindowMinimize();
        case kWindowEventRestore:
          listener.onWindowRestore();
        case kWindowEventResized:
          listener.onWindowResized();
        case kWindowEventMoved:
          listener.onWindowMoved();
      }
    }
  }

  void _emitLater(String eventName) =>
      scheduleMicrotask(() => emit(eventName));

  /// The user pressed the title bar's close button.
  void userCloses() => emit(kWindowEventClose);

  /// The user minimized the window: minimized first, then the event, as the
  /// real window reports it.
  void userMinimizes() {
    minimized = true;
    emit(kWindowEventMinimize);
  }

  /// Another window took the foreground, and then this one got it back.
  void userRefocuses() {
    emit(kWindowEventBlur);
    emit(kWindowEventFocus);
  }

  @override
  void addListener(WindowListener listener) => _listeners.add(listener);

  @override
  void removeListener(WindowListener listener) => _listeners.remove(listener);

  @override
  Future<bool> isPreventClose() async => preventClose;

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<bool> isMinimized() async => minimized;

  @override
  Future<void> show() async {
    _record('show');
    if (!visible) {
      visible = true;
      _emitLater('show');
    }
  }

  @override
  Future<void> focus() async {
    _record('focus');
    _emitLater(kWindowEventFocus);
  }

  @override
  Future<void> hide() async {
    _record('hide');
    if (visible) {
      visible = false;
      _emitLater('hide');
    }
  }

  @override
  Future<void> destroy() async {
    _record('destroy');
    destroyed = true;
  }

  /// The runner's show: back from the tray or from minimized, then focused.
  @override
  Future<void> showNative() async {
    _record('showNative');
    if (!visible) {
      visible = true;
      _emitLater('show');
    } else if (minimized) {
      minimized = false;
      _emitLater(kWindowEventRestore);
    }
    _emitLater(kWindowEventFocus);
  }

  @override
  Future<WindowState?> state() async {
    _record('state');
    return WindowState(
      bounds: bounds,
      maximized: maximized,
      minimized: minimized,
      visible: visible,
      contentVisible: visible,
      dpi: 96,
      monitorName: r'\\.\DISPLAY1',
      monitorBounds: const Rect.fromLTWH(0, 0, 2560, 1440),
    );
  }
}

/// A tray icon that records its menus, tooltips and icons.
class FakeAppTray implements AppTray {
  FakeAppTray([this.log]);

  final List<String>? log;

  bool initialised = false;
  bool destroyed = false;
  void Function(TrayEvent event)? _handler;

  /// Every menu installed, newest last.
  final List<List<TrayMenuEntry>> menus = <List<TrayMenuEntry>>[];
  final List<String> toolTips = <String>[];
  final List<String> images = <String>[];

  List<TrayMenuEntry> get menu => menus.isEmpty ? const [] : menus.last;

  List<String> get menuLabels => [
        for (final entry in menu)
          if (!entry.isSeparator) entry.label!,
      ];

  /// Clicks the menu item labelled [label].
  void choose(String label) =>
      menu.firstWhere((e) => e.label == label).onClicked!.call();

  void fire(TrayEvent event) => _handler?.call(event);

  @override
  Future<void> init({
    required String title,
    required String iconPath,
    required String toolTip,
  }) async {
    initialised = true;
    log?.add('tray.init');
  }

  @override
  void onEvent(void Function(TrayEvent event) handler) => _handler = handler;

  @override
  Future<void> popUpMenu() async => log?.add('tray.popUp');

  @override
  Future<void> setMenu(List<TrayMenuEntry> entries) async {
    menus.add(List<TrayMenuEntry>.of(entries));
    log?.add('tray.setMenu');
  }

  @override
  Future<void> setToolTip(String toolTip) async => toolTips.add(toolTip);

  @override
  Future<void> setImage(String iconPath) async => images.add(iconPath);

  @override
  Future<void> destroy() async {
    destroyed = true;
    log?.add('tray.destroy');
  }
}

/// Toasts that are kept rather than shown.
class FakeNotifications implements AppNotifications {
  final List<AppNotification> shown = <AppNotification>[];

  List<String> get titles => [for (final n in shown) n.title];

  @override
  Future<void> show(AppNotification notification) async =>
      shown.add(notification);
}

/// Records the Run-key writes instead of running reg.exe.
class FakeStartupService extends StartupService {
  final List<bool> syncs = <bool>[];

  @override
  Future<void> sync(bool enabled) async => syncs.add(enabled);
}

/// An update service with nothing on the network or the disk: [available] is
/// what the release check finds, the download waits for [download] and the
/// updater's start for [starting] - so a test can hold an update at either
/// step for as long as it likes.
class FakeUpdateService extends UpdateService {
  FakeUpdateService([this.log]);

  final List<String>? log;

  UpdateInfo? available;

  /// Completed by the test: with a file to go on, with an error to fail.
  final Completer<File> download = Completer<File>();
  int downloads = 0;

  /// Completed by the test once the updater "is running"; an error fails
  /// the handover.
  final Completer<void> starting = Completer<void>();

  /// Extracted builds thrown away after a failure.
  final List<String> discarded = <String>[];

  @override
  Future<UpdateInfo?> checkForUpdates() async => available;

  @override
  Future<File> downloadUpdate(
    String zipUrl,
    void Function(double progress)? onProgress,
  ) {
    downloads++;
    log?.add('update.download');
    return download.future;
  }

  @override
  Future<void> verifyChecksum(File zipFile, String checksumUrl,
      {String? assetName}) async {}

  @override
  Future<Directory> extractAndVerifyZip(File zipFile) async =>
      Directory('${zipFile.path}.extracted');

  @override
  Future<void> startUpdater(Directory sourceDir) {
    log?.add('update.startUpdater');
    return starting.future;
  }

  @override
  Future<void> discardExtractedUpdate(Directory appRoot) async =>
      discarded.add(appRoot.path);
}
