import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/window_bounds.dart';

/// The desk the geometry bugs were found on, in physical pixels exactly as
/// the runner reports it: a 150% portrait monitor to the left of, and
/// reaching above and far below, a 100% ultrawide primary. Windows lists the
/// portrait one FIRST.
const portrait = MonitorInfo(
  name: r'\\.\DISPLAY1',
  bounds: Rect.fromLTWH(-2160, -813, 2160, 3840),
  workArea: Rect.fromLTWH(-2160, -813, 2160, 3840),
  dpi: 144,
);
const ultrawide = MonitorInfo(
  name: r'\\.\DISPLAY2',
  bounds: Rect.fromLTWH(0, 0, 3440, 1440),
  workArea: Rect.fromLTWH(0, 0, 3440, 1440),
  dpi: 96,
  isPrimary: true,
);
const desk = [portrait, ultrawide];

/// What the runner would report for a window placed at [bounds] on [desk].
WindowState placedAt(Rect bounds, {bool maximized = false}) {
  final home = dominantMonitor(bounds, desk)!;
  return WindowState(
    bounds: bounds,
    maximized: maximized,
    minimized: false,
    visible: true,
    contentVisible: true,
    dpi: home.dpi,
    monitorName: home.name,
    monitorBounds: home.bounds,
  );
}

void main() {
  group('primaryMonitor', () {
    test('is the flagged primary, not the first listed', () {
      // The old sanitizer took displays.first as the primary and clamped a
      // 1864px-wide window to the portrait monitor's width.
      expect(primaryMonitor(desk), ultrawide);
    });

    test('without a flag, is the monitor holding the virtual origin', () {
      final unflagged = [
        portrait,
        const MonitorInfo(
          name: 'B',
          bounds: Rect.fromLTWH(0, 0, 1920, 1080),
          workArea: Rect.fromLTWH(0, 0, 1920, 1040),
          dpi: 96,
        ),
      ];
      expect(primaryMonitor(unflagged)!.name, 'B');
    });

    test('is null with no monitors', () {
      expect(primaryMonitor(const []), isNull);
    });
  });

  group('channel parsing', () {
    test('a monitor entry parses, and garbage does not', () {
      final m = MonitorInfo.fromMap({
        'name': r'\\.\DISPLAY1',
        'left': -2160, 'top': -813, 'width': 2160, 'height': 3840,
        'workLeft': -2160, 'workTop': -813, 'workWidth': 2160,
        'workHeight': 3800,
        'dpi': 144,
        'primary': false,
      })!;
      expect(m.bounds, const Rect.fromLTWH(-2160, -813, 2160, 3840));
      expect(m.workArea, const Rect.fromLTWH(-2160, -813, 2160, 3800));
      expect(m.scale, 1.5);
      expect(m.isPrimary, isFalse);

      expect(MonitorInfo.fromMap(null), isNull);
      expect(MonitorInfo.fromMap({'name': 'x'}), isNull);
      expect(MonitorInfo.fromMap({'left': 0, 'top': 0, 'width': 0, 'height': 0}),
          isNull);
    });

    test('a window state parses, content visibility included', () {
      final s = WindowState.fromMap({
        'left': 10, 'top': 20, 'width': 1280, 'height': 720,
        'maximized': true,
        'minimized': false,
        'visible': true,
        'contentVisible': false,
        'dpi': 96,
        'monitor': r'\\.\DISPLAY2',
        'monitorLeft': 0, 'monitorTop': 0, 'monitorWidth': 3440,
        'monitorHeight': 1440,
      })!;
      expect(s.bounds, const Rect.fromLTWH(10, 20, 1280, 720));
      expect(s.maximized, isTrue);
      expect(s.contentVisible, isFalse);
      expect(s.monitorBounds, ultrawide.bounds);
      expect(s.shown, isTrue, reason: 'a runner that does not say');
      expect(WindowState.fromMap('nope'), isNull);
      expect(
          WindowState.fromMap(
              {'left': 0, 'top': 0, 'width': 10, 'height': 10, 'shown': false})!
              .shown,
          isFalse);
    });
  });

  group('SavedWindowPlacement', () {
    test('round-trips through JSON', () {
      final saved = SavedWindowPlacement.fromState(
          placedAt(const Rect.fromLTWH(-1134, 1214, 1864, 1237)));
      expect(SavedWindowPlacement.fromJson(saved.toJson()), saved);
    });

    test('an incomplete or nonsensical record reads as absent', () {
      // Absent sends the restore to the legacy fields rather than to garbage.
      expect(SavedWindowPlacement.fromJson(null), isNull);
      expect(SavedWindowPlacement.fromJson({'left': 1, 'top': 2, 'width': 3}),
          isNull);
      expect(
          SavedWindowPlacement.fromJson(
              {'left': 1, 'top': 2, 'width': 300, 'height': -5}),
          isNull);
      expect(
          SavedWindowPlacement.fromJson(
              {'left': double.nan, 'top': 2, 'width': 300, 'height': 400}),
          isNull);
    });
  });

  group('migrateLegacyBounds', () {
    test("the user's saved geometry reads at the portrait monitor's scale", () {
      // channels_config.json as v1.10.0 left it: x -1134, y 1214,
      // 1864 x 1236.67. The .67 is 1855 / 1.5 - getBounds divided the frame
      // by the 150% monitor's scale. Read at 1.0 instead it would sit mostly
      // on that 150% monitor, which is not where a 1.0 reading comes from.
      final r = migrateLegacyBounds(
          x: -1134, y: 1214, width: 1864, height: 1236.666666666667,
          monitors: desk)!;
      expect(r.left, -1701);
      expect(r.top, 1821);
      expect(r.width, 2796);
      expect(r.height, closeTo(1855, 0.001));
    });

    test('a window saved on the 100% primary is unchanged', () {
      final r = migrateLegacyBounds(
          x: 200, y: 150, width: 1600, height: 1000, monitors: desk)!;
      expect(r, const Rect.fromLTWH(200, 150, 1600, 1000));
    });

    test('the logical fields the app still writes migrate back exactly', () {
      // _captureWindowState keeps window_x/y/w/h as physical / scale, the
      // meaning older builds gave them, so a downgrade and upgrade lands the
      // window where it was.
      for (final physical in const [
        Rect.fromLTWH(-2000, 100, 1800, 2400), // portrait
        Rect.fromLTWH(200, 150, 1600, 1000), // primary
        Rect.fromLTWH(-1134, 1214, 1864, 1237), // straddling, mostly portrait
      ]) {
        final s = placedAt(physical).scale;
        final back = migrateLegacyBounds(
            x: physical.left / s,
            y: physical.top / s,
            width: physical.width / s,
            height: physical.height / s,
            monitors: desk)!;
        expect(back.left, closeTo(physical.left, 0.001), reason: '$physical');
        expect(back.top, closeTo(physical.top, 0.001), reason: '$physical');
        expect(back.width, closeTo(physical.width, 0.001), reason: '$physical');
        expect(back.height, closeTo(physical.height, 0.001),
            reason: '$physical');
      }
    });

    test('no position, or not a number, is no migration', () {
      expect(
          migrateLegacyBounds(
              x: null, y: 10, width: 1280, height: 720, monitors: desk),
          isNull);
      expect(
          migrateLegacyBounds(
              x: double.nan, y: 10, width: 1280, height: 720, monitors: desk),
          isNull);
    });
  });

  group('planWindowRestore', () {
    test("the user's legacy geometry comes back on the portrait monitor", () {
      // Migrated, it hangs 1095px into the space right of the portrait
      // monitor and below the ultrawide - no monitor at all - and 649px below
      // the portrait's bottom edge: the drift the old restore suffered from.
      // It is pulled fully onto the monitor it was mostly on, keeping its
      // height and as much of its width as fits.
      final plan = planWindowRestore(
        monitors: desk,
        legacyX: -1134,
        legacyY: 1214,
        legacyWidth: 1864,
        legacyHeight: 1236.666666666667,
      );
      expect(plan.bounds, const Rect.fromLTWH(-2160, 1172, 2160, 1855));
      expect(portrait.workArea.contains(plan.bounds!.topLeft), isTrue);
      expect(portrait.workArea.bottom, plan.bounds!.bottom);
      expect(titleStripReachable(plan.bounds!, desk), isTrue);
      expect(plan.source, contains('legacy'));
      expect(plan.maximized, isFalse);
    });

    test('a saved window straddling both monitors comes back exactly', () {
      // Physical (-1134, 1214) 1864x1237: mostly on the portrait monitor,
      // its top-right corner on the ultrawide. Straddling is a choice, and a
      // record this build wrote on unchanged monitors is trusted.
      const bounds = Rect.fromLTWH(-1134, 1214, 1864, 1237);
      final plan = planWindowRestore(
          monitors: desk,
          saved: SavedWindowPlacement.fromState(placedAt(bounds)));
      expect(plan.bounds, bounds);
      expect(plan.source, 'saved');
    });

    test('a saved window on either monitor comes back exactly', () {
      for (final bounds in const [
        Rect.fromLTWH(-2000, 100, 1800, 2400),
        Rect.fromLTWH(200, 150, 1600, 1000),
      ]) {
        final plan = planWindowRestore(
            monitors: desk,
            saved: SavedWindowPlacement.fromState(placedAt(bounds)));
        expect(plan.bounds, bounds);
      }
    });

    test('maximized restores the normal bounds, flagged maximized', () {
      const bounds = Rect.fromLTWH(-2000, 100, 1800, 2400);
      final plan = planWindowRestore(
        monitors: desk,
        saved: SavedWindowPlacement.fromState(
            placedAt(bounds, maximized: true)),
        maximized: true,
      );
      expect(plan.bounds, bounds);
      expect(plan.maximized, isTrue);
    });

    test('no drift across five save and restore cycles', () {
      // The old loop saved getBounds divided by whichever scale applied at
      // that instant and restored through a different one, so every session
      // stored a different value. Physical in, physical out.
      for (final start in const [
        Rect.fromLTWH(-1134, 1214, 1864, 1237),
        Rect.fromLTWH(-2000, 100, 1800, 2400),
        Rect.fromLTWH(200, 150, 1600, 1000),
      ]) {
        var saved = SavedWindowPlacement.fromState(placedAt(start));
        for (var session = 0; session < 5; session++) {
          final plan = planWindowRestore(monitors: desk, saved: saved);
          expect(plan.bounds, start, reason: 'session $session');
          saved = SavedWindowPlacement.fromState(placedAt(plan.bounds!));
        }
      }
    });

    test('a legacy migration is stable from then on', () {
      // The first save after migrating writes the physical record; from it
      // the window comes back exactly where the migration put it.
      final first = planWindowRestore(
        monitors: desk,
        legacyX: -1134,
        legacyY: 1214,
        legacyWidth: 1864,
        legacyHeight: 1236.666666666667,
      ).bounds!;
      var saved = SavedWindowPlacement.fromState(placedAt(first));
      for (var session = 0; session < 5; session++) {
        final plan = planWindowRestore(monitors: desk, saved: saved);
        expect(plan.bounds, first);
        saved = SavedWindowPlacement.fromState(placedAt(plan.bounds!));
      }
    });

    test('a monitor that moved carries its window along', () {
      const bounds = Rect.fromLTWH(-2000, 100, 1800, 2400);
      final saved = SavedWindowPlacement.fromState(placedAt(bounds));
      const lowered = MonitorInfo(
        name: r'\\.\DISPLAY1',
        bounds: Rect.fromLTWH(-2160, 0, 2160, 3840),
        workArea: Rect.fromLTWH(-2160, 0, 2160, 3840),
        dpi: 144,
      );
      final plan =
          planWindowRestore(monitors: const [lowered, ultrawide], saved: saved);
      expect(plan.bounds, const Rect.fromLTWH(-2000, 913, 1800, 2400));
    });

    test('a monitor that changed scale rescales its window', () {
      const bounds = Rect.fromLTWH(-2000, 100, 1800, 2400);
      final saved = SavedWindowPlacement.fromState(placedAt(bounds));
      const at100 = MonitorInfo(
        name: r'\\.\DISPLAY1',
        bounds: Rect.fromLTWH(-2160, -813, 2160, 3840),
        workArea: Rect.fromLTWH(-2160, -813, 2160, 3840),
        dpi: 96,
      );
      final plan =
          planWindowRestore(monitors: const [at100, ultrawide], saved: saved);
      // Same corner offset and size, at 96/144 of the size, in whole pixels.
      expect(plan.bounds!.width, 1200);
      expect(plan.bounds!.height, 1600);
      expect(plan.bounds!.left, (-2160 + 160 * 96 / 144).roundToDouble());
      expect(plan.bounds!.top, (-813 + 913 * 96 / 144).roundToDouble());
    });

    test('a window whose monitor is gone is rescued to the primary', () {
      final saved = SavedWindowPlacement.fromState(
          placedAt(const Rect.fromLTWH(-2000, 100, 1800, 1200)));
      final plan = planWindowRestore(monitors: const [ultrawide], saved: saved);
      expect(plan.bounds, const Rect.fromLTWH(820, 120, 1800, 1200));
      expect(plan.source, contains('rescued'));
    });

    test('a title bar above the top of the screen is brought down', () {
      // The window overlaps the portrait monitor but its title strip is
      // above it: unreachable, so it is moved into the work area.
      final saved = SavedWindowPlacement.fromState(
          placedAt(const Rect.fromLTWH(-2000, -900, 1800, 1200)));
      final plan = planWindowRestore(monitors: desk, saved: saved);
      expect(plan.bounds, const Rect.fromLTWH(-2000, -813, 1800, 1200));
      expect(titleStripReachable(plan.bounds!, desk), isTrue);
    });

    test('a title bar under the taskbar is not reachable', () {
      const laptop = MonitorInfo(
        name: 'L',
        bounds: Rect.fromLTWH(0, 0, 1920, 1080),
        workArea: Rect.fromLTWH(0, 0, 1920, 1040),
        dpi: 96,
        isPrimary: true,
      );
      expect(
          titleStripReachable(
              const Rect.fromLTWH(100, 1045, 1280, 720), const [laptop]),
          isFalse);
      final plan = planWindowRestore(
        monitors: const [laptop],
        saved: const SavedWindowPlacement(
            bounds: Rect.fromLTWH(100, 1045, 1280, 720)),
      );
      expect(plan.bounds, const Rect.fromLTWH(100, 320, 1280, 720));
    });

    test('a window in the space between monitors is rescued', () {
      // Right of the portrait monitor, below the ultrawide: on no monitor.
      final plan = planWindowRestore(
        monitors: desk,
        saved: const SavedWindowPlacement(
            bounds: Rect.fromLTWH(500, 1600, 1000, 800)),
      );
      expect(plan.bounds, const Rect.fromLTWH(1220, 320, 1000, 800));
    });

    test('a size below the minimum is replaced at the monitor scale', () {
      final plan = planWindowRestore(
        monitors: desk,
        saved: const SavedWindowPlacement(
            bounds: Rect.fromLTWH(-2000, 100, 200, 300)),
      );
      // The 1280x720 default at 150%.
      expect(plan.bounds!.size, const Size(1920, 1080));
      expect(plan.source, contains('size repaired'));
    });

    test('first run centres the default size on the primary', () {
      final plan = planWindowRestore(monitors: desk);
      expect(plan.bounds, const Rect.fromLTWH(1080, 360, 1280, 720));
      expect(plan.source, 'default');
    });

    test('no monitor information leaves the window where it is', () {
      final plan = planWindowRestore(monitors: const [],
          legacyX: 10, legacyY: 10);
      expect(plan.bounds, isNull);
    });

    test('a default larger than a small monitor fits it', () {
      const small = MonitorInfo(
        name: 'S',
        bounds: Rect.fromLTWH(0, 0, 1024, 600),
        workArea: Rect.fromLTWH(0, 0, 1024, 560),
        dpi: 96,
        isPrimary: true,
      );
      final plan = planWindowRestore(monitors: const [small]);
      expect(plan.bounds, const Rect.fromLTWH(0, 0, 1024, 560));
    });
  });

  group('the check after the first frame', () {
    WindowState state({bool visible = true, bool content = true}) =>
        WindowState(
          bounds: const Rect.fromLTWH(0, 0, 1280, 720),
          maximized: false,
          minimized: false,
          visible: visible,
          contentVisible: content,
          dpi: 96,
        );

    test('shows again a frame or content view that is not visible', () {
      for (final s in [state(visible: false), state(content: false)]) {
        expect(
            shouldReshowAfterFirstFrame(s,
                startHidden: false, hiddenByUser: false),
            isTrue,
            reason: '$s');
      }
      expect(
          shouldReshowAfterFirstFrame(state(),
              startHidden: false, hiddenByUser: false),
          isFalse);
    });

    test('leaves a window the user put in the tray where it is', () {
      // Closed to the tray within 1.5s of launching, it popped back.
      expect(
          shouldReshowAfterFirstFrame(state(visible: false),
              startHidden: false, hiddenByUser: true),
          isFalse);
    });

    test('leaves a window that started hidden alone', () {
      expect(
          shouldReshowAfterFirstFrame(state(visible: false),
              startHidden: true, hiddenByUser: false),
          isFalse);
      expect(
          shouldReshowAfterFirstFrame(null,
              startHidden: false, hiddenByUser: false),
          isFalse,
          reason: 'the runner could not say');
    });
  });

  group("the runner's DescribeWindow", () {
    // The runner's C++ has no tests of its own, and no launch here can show
    // this: the offset only exists with a taskbar on the top or left edge of
    // a monitor. So the source is read, as the main.dart checks do.
    test('converts a restore rectangle with the work area of its own monitor',
        () {
      // Not the monitor the window is maximized or minimized on: it can
      // restore to another, whose taskbar is not the same.
      final source =
          File('windows/runner/window_placement.cpp').readAsStringSync();
      final start = source.indexOf('EncodableMap DescribeWindow(');
      expect(start, greaterThan(0));
      final conversion = source.substring(
          source.indexOf('rcNormalPosition;', start),
          source.indexOf('GetWindowRect(window, &normal)', start));
      expect(conversion, contains('MonitorFromRect(&normal'));
      expect(conversion, isNot(contains('MonitorFromWindow(')));
    });
  });
}
