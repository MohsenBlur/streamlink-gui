import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/crash_log.dart';
import 'package:streamlink_gui/services/desktop_shell.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/update_service.dart';
import 'package:streamlink_gui/state/app_shell_controller.dart';
import 'package:streamlink_gui/state/settings_repository.dart';

import 'support/fake_desktop.dart';

/// The shell on its own: a fake window, tray and toasts, a real
/// [SettingsRepository] over writers that log, and the screen's side as
/// counters. What the screen does with these hooks is main_screen_test's.
class _Rig {
  final List<String> log = <String>[];
  late final FakeAppWindow window = FakeAppWindow(log);
  late final FakeAppTray tray = FakeAppTray(log);
  final FakeNotifications notifications = FakeNotifications();
  late final FakeUpdateService updates = FakeUpdateService(log);
  final AppSettings settings = AppSettings();
  late final SettingsRepository repository = SettingsRepository(
    writeConfig: () async => log.add('save.config'),
    writeProgress: () async => log.add('save.progress'),
    writeRecents: () async => log.add('save.recents'),
  )
    ..markConfigLoaded()
    ..markHistoryLoaded();

  /// When set, stopAll waits for it.
  Completer<void>? stopGate;
  bool confirm = true;
  List<String> live = <String>[];
  final List<String> messages = <String>[];
  final List<String> watched = <String>[];
  int cameBack = 0;
  int visibilityChanges = 0;
  int libraryOpened = 0;
  int confirmations = 0;

  late final AppShellController shell = AppShellController(
    window: window,
    tray: tray,
    notifications: notifications,
    updates: updates,
    repository: repository,
    settings: () => settings,
    stopAll: () async {
      log.add('player.stopAll');
      await stopGate?.future;
    },
    liveFavorites: () => live,
    startHidden: false,
    onVisibilityChanged: () => visibilityChanges++,
    onCameBack: () => cameBack++,
    confirmExit: () async {
      confirmations++;
      return confirm;
    },
    showMessage: messages.add,
    onTrayWatch: watched.add,
    onTrayOpenLibrary: () => libraryOpened++,
    onExitCommitted: () => log.add('screen.timersStopped'),
    onSessionEnding: () => log.add('downloads.freeze'),
    onSessionContinues: () => log.add('downloads.unfreeze'),
  );

  Future<void> attach(WidgetTester tester) async {
    shell.attach();
    await tester.pump();
  }

  /// Takes the shell down and lets its timers run out, inside the test: the
  /// pending-timer check runs before any tearDown.
  Future<void> finish(WidgetTester tester) async {
    shell.dispose();
    repository.dispose();
    await tester.pump(const Duration(seconds: 2));
  }

  static final UpdateInfo update = UpdateInfo(
    version: '99.0.0',
    releaseNotes: '',
    zipDownloadUrl: 'https://example.invalid/app.zip',
    isUpdateAvailable: true,
  );
}

/// A method call from the runner on [channel], answered as the runner would
/// wait for it.
Future<Object?> _fromRunner(
    WidgetTester tester, String channel, String method) async {
  const codec = StandardMethodCodec();
  Object? reply;
  var replied = false;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    channel,
    codec.encodeMethodCall(MethodCall(method)),
    (data) {
      replied = true;
      reply = data == null ? null : codec.decodeEnvelope(data);
    },
  );
  await tester.pump();
  expect(replied, isTrue, reason: '$method was answered');
  return reply;
}

void main() {
  setUp(() {
    AppShellController.windowHiddenByUser = false;
    storageWriteFailure.value = null;
  });
  tearDown(() {
    AppShellController.windowHiddenByUser = false;
    storageWriteFailure.value = null;
  });

  group('the window', () {
    testWidgets('hidden by the user is marked so, and showing it clears that',
        (tester) async {
      // main()'s check after the first frame reads the mark: a window the
      // user put in the tray within a second of launch must stay there.
      final rig = _Rig();
      await rig.attach(tester);

      await rig.shell.hideWindow();
      expect(AppShellController.windowHiddenByUser, isTrue);
      await rig.shell.showWindow();
      expect(AppShellController.windowHiddenByUser, isFalse);

      await rig.finish(tester);
    });

    testWidgets('its visibility is read back from its events', (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      expect(rig.shell.windowVisible, isTrue);

      await rig.shell.hideWindow();
      await tester.pump();
      expect(rig.shell.windowVisible, isFalse);
      expect(rig.visibilityChanges, 1);

      rig.window.visible = true;
      rig.window.userMinimizes();
      await tester.pump();
      expect(rig.shell.windowVisible, isFalse, reason: 'minimized is hidden');

      await rig.shell.showWindow();
      await tester.pump();
      expect(rig.shell.windowVisible, isTrue);

      await rig.finish(tester);
    });

    testWidgets('a second launch brings the bookkeeping up to date',
        (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      await rig.shell.hideWindow();
      await tester.pump();
      expect(rig.shell.windowVisible, isFalse);

      // The runner has already shown it by the time it says so.
      rig.window.visible = true;
      await _fromRunner(tester, 'streamlink_gui/single_instance', 'activate');
      expect(rig.shell.windowVisible, isTrue);
      expect(rig.window.calls['focus'], 1);

      await rig.finish(tester);
    });

    testWidgets('a second launch clears the hidden-by-user mark',
        (tester) async {
      // The runner shows the window itself, past showWindow, which is what
      // clears the mark: a window back on screen stayed marked as put away.
      final rig = _Rig();
      await rig.attach(tester);
      await rig.shell.hideWindow();
      await tester.pump();
      expect(AppShellController.windowHiddenByUser, isTrue);

      rig.window.visible = true;
      await _fromRunner(tester, 'streamlink_gui/single_instance', 'activate');
      expect(AppShellController.windowHiddenByUser, isFalse);
      expect(rig.window.calls['showNative'], isNull,
          reason: 'the runner already showed it; Dart only keeps count');

      await rig.finish(tester);
    });

    testWidgets('coming back is debounced, and never answered while exiting',
        (tester) async {
      final rig = _Rig();
      await rig.attach(tester);

      rig.window.userRefocuses();
      rig.window.emit('show');
      rig.window.emit('restore');
      await tester.pump(const Duration(milliseconds: 299));
      expect(rig.cameBack, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(rig.cameBack, 1, reason: 'one refresh for the whole burst');

      rig.window.userRefocuses();
      await rig.shell.shutDownAndExit();
      rig.window.userRefocuses();
      await tester.pump(const Duration(seconds: 1));
      expect(rig.cameBack, 1);

      await rig.finish(tester);
    });

    testWidgets('a move or resize saves the config once, debounced, and only '
        'the config', (tester) async {
      // Every move, resize and trip to the tray rewrote the progress sidecar
      // too, each write fsync'd.
      final rig = _Rig();
      await rig.attach(tester);

      for (var i = 0; i < 5; i++) {
        rig.window.emit('moved');
        rig.window.emit('resized');
      }
      rig.window.emit('maximize');
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.settings.windowPlacement, isNotNull);
      await tester.pump(rig.repository.saveDelay);
      expect(rig.log.where((e) => e.startsWith('save.')), ['save.config']);
      expect(rig.window.calls['state'], 1, reason: 'captured once, at rest');

      await rig.finish(tester);
    });

    testWidgets('a close hides to the tray with a one-time notice; with '
        '"close exits" set it asks to exit', (tester) async {
      final rig = _Rig();
      await rig.attach(tester);

      rig.window.userCloses();
      await tester.pump();
      expect(rig.window.visible, isFalse);
      expect(rig.notifications.titles, ['Still running in the tray']);
      expect(rig.settings.trayNoticeShown, isTrue);
      expect(rig.log, contains('save.config'),
          reason: 'the notice is shown once, ever');

      rig.window.visible = true;
      rig.settings.closeAction = 'exit';
      rig.window.userCloses();
      await tester.pump();
      expect(rig.confirmations, 1);
      expect(rig.window.destroyed, isTrue);

      await rig.finish(tester);
    });

    testWidgets('minimize goes to the tray only when set to', (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      rig.window.userMinimizes();
      await tester.pump();
      expect(rig.window.calls['hide'], isNull);

      rig.settings.minimizeAction = 'tray';
      rig.window.minimized = false;
      rig.window.userMinimizes();
      await tester.pump();
      expect(rig.window.calls['hide'], 1);

      await rig.finish(tester);
    });
  });

  group('the tray menu', () {
    testWidgets('is rebuilt only when the live favourites it lists change',
        (tester) async {
      // system_tray leaks the native menu on every rebuild.
      final rig = _Rig();
      rig.live = ['alpha'];
      await rig.attach(tester);
      expect(rig.tray.menus, hasLength(1));
      expect(rig.tray.menuLabels,
          ['Watch alpha', 'Show App', 'Hide App', 'Open Library', 'Exit']);
      expect(rig.tray.toolTips.last, 'Twitch Streamlink GUI - 1 favorite live');
      expect(rig.tray.images.last, 'assets/app_icon_live.ico');

      await rig.shell.rebuildTrayMenu();
      expect(rig.tray.menus, hasLength(1));

      rig.live = ['alpha', 'beta', 'c', 'd', 'e', 'f'];
      await rig.shell.rebuildTrayMenu();
      expect(rig.tray.menus, hasLength(2));
      expect(rig.tray.menuLabels.where((l) => l.startsWith('Watch')),
          hasLength(5), reason: 'at most five');

      rig.settings.trayLiveMenuEnabled = false;
      await rig.shell.rebuildTrayMenu(force: true);
      expect(rig.tray.menuLabels, ['Show App', 'Hide App', 'Open Library', 'Exit']);
      expect(rig.tray.images.last, 'assets/app_icon.ico');

      await rig.finish(tester);
    });

    testWidgets('its items reach the screen, the window and the exit',
        (tester) async {
      final rig = _Rig();
      rig.live = ['alpha'];
      await rig.attach(tester);

      rig.tray.choose('Watch alpha');
      expect(rig.watched, ['alpha']);

      rig.tray.choose('Hide App');
      await tester.pump();
      expect(rig.window.visible, isFalse);
      rig.tray.choose('Open Library');
      await tester.pump();
      expect(rig.window.visible, isTrue);
      expect(rig.libraryOpened, 1);

      rig.tray.fire(TrayEvent.rightClick);
      expect(rig.log, contains('tray.popUp'));

      rig.tray.choose('Exit');
      await tester.pump();
      expect(rig.window.destroyed, isTrue);

      await rig.finish(tester);
    });
  });

  group('exit', () {
    testWidgets(
        'stops the timers, captures the window, stops the players, saves, '
        'and only then removes the tray and the window - logging each step',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('shell_exit_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final previous = CrashLog.current;
      CrashLog.current = CrashLog(File('${dir.path}/crash.log'));
      addTearDown(() => CrashLog.current = previous);

      final rig = _Rig();
      await rig.attach(tester);
      rig.log.clear();

      await rig.shell.shutDownAndExit();
      expect(rig.log, [
        'screen.timersStopped',
        'window.state',
        'player.stopAll',
        'save.config',
        'save.progress',
        'save.recents',
        'tray.destroy',
        'window.destroy',
      ]);
      expect(rig.window.listenerCount(), 0);
      expect(rig.shell.isExiting, isTrue);

      // An exit seen taking 6.9s left nothing to say which step it was.
      final lines = CrashLog.current!.file.readAsLinesSync();
      final steps = [
        for (final l in lines)
          if (l.contains('[exit]')) l.substring(l.indexOf('[exit]')),
      ];
      expect(steps.first, '[exit] requested');
      expect(steps[1], startsWith('[exit] players stopped (+'));
      expect(steps[2], startsWith('[exit] saved (+'));
      expect(steps[3], startsWith('[exit] tray destroyed (+'));
      expect(steps.last, '[exit] saved and stopped; closing');

      await rig.shell.shutDownAndExit();
      expect(rig.window.calls['destroy'], 1, reason: 'once');

      await rig.finish(tester);
    });

    testWidgets('a stop that never returns does not strand it', (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      rig.stopGate = Completer<void>();

      unawaited(rig.shell.shutDownAndExit());
      await tester.pump(const Duration(seconds: 4));
      expect(rig.window.destroyed, isFalse);
      await tester.pump(AppShellController.stopAllTimeout);
      expect(rig.window.destroyed, isTrue);

      await rig.finish(tester);
    });

    testWidgets('one the user turns down leaves everything running',
        (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      rig.confirm = false;

      await rig.shell.requestExit();
      expect(rig.shell.isExiting, isFalse);
      expect(rig.log, isNot(contains('player.stopAll')));

      rig.confirm = true;
      await rig.shell.requestExit();
      expect(rig.window.destroyed, isTrue, reason: 'and can be asked again');

      await rig.finish(tester);
    });
  });

  group('the update', () {
    testWidgets('refuses Exit while it installs', (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      unawaited(rig.shell
          .applyUpdate(_Rig.update, report: ({status, fraction}) {})
          .catchError((Object _) {}));
      await tester.pump();
      expect(rig.shell.isUpdateInProgress, isTrue);
      expect(rig.shell.isUpdateActive, isTrue);

      await rig.shell.requestExit();
      expect(rig.messages.single, contains('An update is being installed'));
      expect(rig.confirmations, 0);
      expect(rig.window.destroyed, isFalse);

      rig.updates.download.completeError(Exception('offline'));
      await tester.pump();
      expect(rig.shell.isUpdateInProgress, isFalse);

      await rig.finish(tester);
    });

    testWidgets(
        'a close while it hands over to the updater is not a normal close, '
        'and the app exits once the updater runs', (tester) async {
      // The updater can signal that it is ready, and close the window, up to
      // a poll before the app sees the signal and starts exiting.
      final rig = _Rig();
      await rig.attach(tester);
      final statuses = <String>[];
      var finished = false;
      unawaited(rig.shell
          .applyUpdate(_Rig.update, report: ({status, fraction}) {
        if (status != null) statuses.add(status);
      }).then((_) => finished = true));
      rig.updates.download.complete(File('update.zip'));
      await tester.pump();
      expect(rig.log, contains('update.startUpdater'));
      expect(rig.log.indexOf('player.stopAll'),
          lessThan(rig.log.indexOf('update.startUpdater')),
          reason: 'nothing may run from the folder being replaced');
      expect(statuses.last, 'Applying update and restarting...');

      rig.window.userCloses();
      await tester.pump();
      expect(rig.window.visible, isTrue, reason: 'not hidden to the tray');
      expect(rig.notifications.shown, isEmpty);

      rig.updates.starting.complete();
      await tester.pump();
      expect(finished, isTrue);
      expect(rig.window.destroyed, isTrue);
      expect(rig.tray.destroyed, isTrue, reason: 'no ghost icon beside the '
          'relaunched app');

      await rig.finish(tester);
    });

    testWidgets('a handover that fails leaves the app closable as usual',
        (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      Object? failure;
      unawaited(rig.shell
          .applyUpdate(_Rig.update, report: ({status, fraction}) {})
          .catchError((Object e) => failure = e));
      rig.updates.download.complete(File('update.zip'));
      await tester.pump();
      rig.updates.starting.completeError(Exception('updater missing'));
      await tester.pump();

      expect(failure, isA<Exception>());
      expect(rig.shell.isUpdateInProgress, isFalse);
      expect(rig.updates.discarded, isEmpty,
          reason: 'a late updater may still be copying out of it');
      rig.window.userCloses();
      await tester.pump();
      expect(rig.window.visible, isFalse, reason: 'hidden, as any close');

      await rig.finish(tester);
    });

    testWidgets('stops before the downloads when their queue could not be '
        'saved, and throws the extracted build away', (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      storageWriteFailure.value =
          StorageWriteFailure('channels_config.json', 'disk full', DateTime(2026));
      Object? failure;
      unawaited(rig.shell
          .applyUpdate(_Rig.update, report: ({status, fraction}) {})
          .catchError((Object e) => failure = e));
      rig.updates.download.complete(File('update.zip'));
      await tester.pump();

      expect('$failure', contains('could not save the download queue'));
      expect(rig.log, isNot(contains('player.stopAll')));
      expect(rig.updates.discarded, ['update.zip.extracted']);

      await rig.finish(tester);
    });
  });

  group('a session end', () {
    testWidgets('freezes the queue and saves before it is answered; one the '
        'process outlives lets the queue go', (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      rig.log.clear();

      final answer = await _fromRunner(tester, 'streamlink_gui/session', 'end');
      expect(answer, isTrue);
      expect(rig.log.take(3), ['downloads.freeze', 'window.state', 'save.config']);
      expect(rig.log, isNot(contains('downloads.unfreeze')));

      await tester.pump(const Duration(seconds: 31));
      expect(rig.log.last, 'downloads.unfreeze',
          reason: 'the Restart Manager only asked; the app carries on');

      await rig.finish(tester);
    });

    testWidgets(
        'keeps a maximized window maximized when it never left the tray',
        (tester) async {
      // Started at login into the tray from a maximized session and never
      // opened: the frame is not zoomed until its first show, and saving
      // that at the session's end brought the next launch up at normal size.
      final rig = _Rig();
      rig.settings.isWindowMaximized = true;
      rig.window
        ..visible = false
        ..shown = false;
      await rig.attach(tester);

      await _fromRunner(tester, 'streamlink_gui/session', 'end');
      expect(rig.log, contains('save.config'));
      expect(rig.settings.isWindowMaximized, isTrue);
      expect(rig.settings.windowWidth, 1400,
          reason: 'the planned normal bounds are still saved');

      // Once it has been on screen, what it reports is how it was left.
      await rig.shell.showWindow();
      await _fromRunner(tester, 'streamlink_gui/session', 'end');
      expect(rig.settings.isWindowMaximized, isFalse);

      await tester.pump(const Duration(seconds: 31));
      await rig.finish(tester);
    });

    testWidgets('one that is called off lets the queue go at once',
        (tester) async {
      final rig = _Rig();
      await rig.attach(tester);
      await _fromRunner(tester, 'streamlink_gui/session', 'queryEnd');
      await _fromRunner(tester, 'streamlink_gui/session', 'cancelled');
      expect(rig.log, containsAllInOrder(['downloads.freeze', 'downloads.unfreeze']));

      await rig.finish(tester);
    });
  });
}
