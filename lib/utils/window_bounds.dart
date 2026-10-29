import 'dart:math' as math;
import 'dart:ui';

/// Window geometry, in PHYSICAL pixels.
///
/// Every rectangle here is in virtual-screen physical pixels, the one
/// coordinate system all monitors agree on, as the native runner reports and
/// applies it (windows/runner/window_placement.cpp). The previous restore
/// worked in logical pixels from two plugins that disagree about what a
/// logical pixel is: screen_retriever divided each MONITOR by its own scale,
/// window_manager divided the WINDOW by the scale of whichever monitor it sat
/// on at that moment. Across a 100% and a 150% monitor the two systems do not
/// line up, so the saved position was in neither, the window grew by 1.5x on
/// some launches, and every save stored a slightly different mix.
///
/// Logical sizes (the 380x500 minimum, the 1280x720 default) are converted
/// with the scale of the monitor the window lands on, which is the scale the
/// app is then laid out at.

/// The smallest window the app's layout supports, in logical pixels.
const Size kMinWindowSize = Size(380, 500);

/// The size of a window with no usable saved geometry, in logical pixels.
const Size kDefaultWindowSize = Size(1280, 720);

/// One monitor as the runner reports it.
class MonitorInfo {
  const MonitorInfo({
    required this.name,
    required this.bounds,
    required this.workArea,
    required this.dpi,
    this.isPrimary = false,
  });

  /// The device name (`\\.\DISPLAY1`). Stable for as long as the monitor
  /// stays plugged into the same output, which is what identifies "the
  /// monitor the window was on" across sessions.
  final String name;

  /// The whole monitor.
  final Rect bounds;

  /// The monitor minus the taskbar and docked toolbars: where a window can
  /// usefully be.
  final Rect workArea;

  final int dpi;

  final bool isPrimary;

  /// The UI scale on this monitor; 1.5 at 144 dpi.
  double get scale => dpi > 0 ? dpi / 96.0 : 1.0;

  /// Parses one entry of the runner's `getMonitors` reply; null when it is
  /// not one.
  static MonitorInfo? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final bounds = _rect(raw, '');
    if (bounds == null || bounds.isEmpty) return null;
    final work = _rect(raw, 'work');
    final dpi = raw['dpi'];
    return MonitorInfo(
      name: raw['name'] is String ? raw['name'] as String : '',
      bounds: bounds,
      workArea: (work == null || work.isEmpty) ? bounds : work,
      dpi: dpi is int && dpi > 0 ? dpi : 96,
      isPrimary: raw['primary'] == true,
    );
  }

  @override
  String toString() => '$name ${describeRect(bounds)} work '
      '${describeRect(workArea)} ${dpi}dpi${isPrimary ? ' primary' : ''}';
}

/// What the runner reports about the window (`getPlacement`).
class WindowState {
  const WindowState({
    required this.bounds,
    required this.maximized,
    required this.minimized,
    required this.visible,
    required this.contentVisible,
    required this.dpi,
    this.monitorName,
    this.monitorBounds,
    this.shown = true,
  });

  /// The normal bounds: the live frame, or while maximized or minimized the
  /// rectangle the window returns to.
  final Rect bounds;
  final bool maximized;
  final bool minimized;
  final bool visible;

  /// Whether the frame has been on screen yet. One that started hidden (in
  /// the tray) is not maximized until its first show, however that show
  /// will present it, so until then [maximized] says nothing about how the
  /// user left the window.
  final bool shown;

  /// Whether the engine's content view has its own visible flag set: false
  /// is the invisible-window bug, which shows as a frame with nothing in it.
  /// The view's own flag rather than whether it is on screen, so the answer
  /// is meaningful while the frame is still hidden too.
  final bool contentVisible;
  final int dpi;
  final String? monitorName;
  final Rect? monitorBounds;

  double get scale => dpi > 0 ? dpi / 96.0 : 1.0;

  static WindowState? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final bounds = _rect(raw, '');
    if (bounds == null) return null;
    final dpi = raw['dpi'];
    return WindowState(
      bounds: bounds,
      maximized: raw['maximized'] == true,
      minimized: raw['minimized'] == true,
      visible: raw['visible'] == true,
      contentVisible: raw['contentVisible'] == true,
      dpi: dpi is int && dpi > 0 ? dpi : 96,
      monitorName: raw['monitor'] is String ? raw['monitor'] as String : null,
      monitorBounds: _rect(raw, 'monitor'),
      shown: raw['shown'] != false,
    );
  }

  @override
  String toString() => '${describeRect(bounds)} ${dpi}dpi'
      '${maximized ? ' maximized' : ''}${minimized ? ' minimized' : ''} '
      'visible=$visible content=$contentVisible'
      '${monitorName == null ? '' : ' on $monitorName'}';
}

/// Whether the check a moment after the first frame should show the window
/// again: the frame or its content view is not visible, and nobody meant it
/// to be hidden.
///
/// Not when the app started hidden (Start minimized), and not when the user
/// has since hidden it on purpose ([hiddenByUser]: closed or minimized to the
/// tray). The check runs 1.5s after the first frame, and a window closed to
/// the tray inside that time used to pop straight back.
bool shouldReshowAfterFirstFrame(
  WindowState? state, {
  required bool startHidden,
  required bool hiddenByUser,
}) {
  if (state == null || startHidden || hiddenByUser) return false;
  return !state.visible || !state.contentVisible;
}

/// The persisted geometry: where the window was, in physical pixels, and on
/// which monitor.
///
/// The monitor is recorded so a rearranged desk does not strand the window: a
/// monitor that is still connected but has moved in the virtual screen (or
/// changed its scale) carries the window with it.
class SavedWindowPlacement {
  const SavedWindowPlacement({
    required this.bounds,
    this.dpi,
    this.monitorName,
    this.monitorBounds,
  });

  /// The normal (restored) bounds.
  final Rect bounds;

  /// The window's DPI when it was saved.
  final int? dpi;

  final String? monitorName;

  /// [monitorName]'s bounds when it was saved.
  final Rect? monitorBounds;

  factory SavedWindowPlacement.fromState(WindowState state) =>
      SavedWindowPlacement(
        bounds: state.bounds,
        dpi: state.dpi,
        monitorName: state.monitorName,
        monitorBounds: state.monitorBounds,
      );

  Map<String, dynamic> toJson() => {
        'left': bounds.left.round(),
        'top': bounds.top.round(),
        'width': bounds.width.round(),
        'height': bounds.height.round(),
        if (dpi != null) 'dpi': dpi,
        if (monitorName != null) 'monitor': monitorName,
        if (monitorBounds != null) ...{
          'monitor_left': monitorBounds!.left.round(),
          'monitor_top': monitorBounds!.top.round(),
          'monitor_width': monitorBounds!.width.round(),
          'monitor_height': monitorBounds!.height.round(),
        },
      };

  /// Null for anything that is not a complete, finite rectangle: a hand
  /// edit or a truncated file must fall back to the legacy fields rather
  /// than restore garbage.
  static SavedWindowPlacement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double? n(String key) {
      final v = raw[key];
      return v is num && v.isFinite ? v.toDouble() : null;
    }

    final left = n('left'), top = n('top');
    final width = n('width'), height = n('height');
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;
    final ml = n('monitor_left'), mt = n('monitor_top');
    final mw = n('monitor_width'), mh = n('monitor_height');
    final dpi = raw['dpi'];
    return SavedWindowPlacement(
      bounds: Rect.fromLTWH(left, top, width, height),
      dpi: dpi is int && dpi > 0 ? dpi : null,
      monitorName: raw['monitor'] is String ? raw['monitor'] as String : null,
      monitorBounds: (ml != null && mt != null && mw != null && mh != null)
          ? Rect.fromLTWH(ml, mt, mw, mh)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedWindowPlacement &&
      other.bounds == bounds &&
      other.dpi == dpi &&
      other.monitorName == monitorName &&
      other.monitorBounds == monitorBounds;

  @override
  int get hashCode => Object.hash(bounds, dpi, monitorName, monitorBounds);
}

/// Where and how the window should come up.
class WindowRestorePlan {
  const WindowRestorePlan({
    required this.bounds,
    required this.maximized,
    required this.source,
  });

  /// Physical normal bounds, or null to leave the window where the runner
  /// created it (no monitor information at all).
  final Rect? bounds;

  /// Show maximized, on the monitor [bounds] is on.
  final bool maximized;

  /// Where [bounds] came from, for the startup log: `saved`, `legacy`
  /// (migrated from the old logical fields), `default`, plus any repair.
  final String source;

  @override
  String toString() => '${bounds == null ? 'unchanged' : describeRect(bounds!)}'
      '${maximized ? ' maximized' : ''} ($source)';
}

/// `(x,y) WxH`, rounded, for logs.
String describeRect(Rect r) => '(${r.left.round()},${r.top.round()}) '
    '${r.width.round()}x${r.height.round()}';

/// The primary monitor: the one the system flags, else the one holding the
/// virtual-screen origin (which is the primary's top-left by definition),
/// else the first.
///
/// Not simply the first: EnumDisplayMonitors makes no promise about order,
/// and on the machine this was found on it lists a portrait secondary
/// first, so "never larger than the primary" clamped a 1864px-wide window to
/// the portrait monitor's 1440.
MonitorInfo? primaryMonitor(List<MonitorInfo> monitors) {
  if (monitors.isEmpty) return null;
  for (final m in monitors) {
    if (m.isPrimary) return m;
  }
  for (final m in monitors) {
    if (m.bounds.contains(Offset.zero)) return m;
  }
  return monitors.first;
}

double _area(Rect r) => r.isEmpty ? 0 : r.width * r.height;

double _overlap(Rect a, Rect b) {
  if (!a.overlaps(b)) return 0;
  return _area(a.intersect(b));
}

/// The monitor holding the largest part of [rect], which is also the one
/// Windows takes the window's DPI from; null when it is on none.
MonitorInfo? dominantMonitor(Rect rect, List<MonitorInfo> monitors) {
  MonitorInfo? best;
  var bestArea = 0.0;
  for (final m in monitors) {
    final a = _overlap(rect, m.bounds);
    if (a > bestArea) {
      bestArea = a;
      best = m;
    }
  }
  return best;
}

/// Converts the pre-1.11 logical geometry to physical bounds.
///
/// Those values came from window_manager's getBounds, which divides the
/// physical frame by the scale of the monitor the window was on when it was
/// saved - a scale the file never recorded. The consistent reading is the
/// one that puts the window back on a monitor of the scale it was divided
/// by: on a 100% primary beside a 150% portrait, (-1134, 1214) 1864x1237 read
/// at 1.5 lands on the 150% monitor (consistent), while read at 1.0 it would
/// sit mostly on that same 150% monitor (inconsistent). Among consistent
/// readings the one most on screen wins; with none, the primary's scale.
Rect? migrateLegacyBounds({
  required double? x,
  required double? y,
  required double width,
  required double height,
  required List<MonitorInfo> monitors,
}) {
  if (x == null || y == null) return null;
  if (!x.isFinite || !y.isFinite || !width.isFinite || !height.isFinite) {
    return null;
  }
  if (width <= 0 || height <= 0 || monitors.isEmpty) return null;

  final scales = <double>{for (final m in monitors) m.scale}.toList()..sort();
  Rect? best;
  var bestOnScreen = -1.0;
  for (final s in scales) {
    final candidate = Rect.fromLTWH(x * s, y * s, width * s, height * s);
    final home = dominantMonitor(candidate, monitors);
    if (home == null || home.scale != s) continue;
    final onScreen = _overlap(candidate, home.bounds) / _area(candidate);
    if (onScreen > bestOnScreen) {
      bestOnScreen = onScreen;
      best = candidate;
    }
  }
  if (best != null) return best;
  final s = primaryMonitor(monitors)!.scale;
  return Rect.fromLTWH(x * s, y * s, width * s, height * s);
}

/// The strip a user grabs to move the window: the custom title bar.
///
/// Logical height of the reachable part. Not the whole bar: a window whose
/// top half-bar is on screen can still be dragged.
const double _grabStripHeight = 24.0;

/// Logical width of title strip that must be on one monitor to count as
/// reachable: room to aim a mouse at, clear of the window buttons.
const double _minGrabWidth = 120.0;

/// Whether the title strip of [rect] can be grabbed: enough of it lies
/// inside some monitor's work area (not under the taskbar, not above the top
/// of the screen).
bool titleStripReachable(Rect rect, List<MonitorInfo> monitors) {
  for (final m in monitors) {
    final s = m.scale;
    final strip = Rect.fromLTWH(
        rect.left, rect.top, rect.width, _grabStripHeight * s);
    if (!strip.overlaps(m.workArea)) continue;
    final part = strip.intersect(m.workArea);
    final wanted = math.min(_minGrabWidth * s, rect.width);
    if (part.width >= wanted - 0.5 && part.height >= strip.height - 0.5) {
      return true;
    }
  }
  return false;
}

/// Decides where the window comes up.
///
/// [saved] is the physical record; when it is absent the old logical fields
/// ([legacyX] and friends) are migrated. The result is kept exactly as saved
/// whenever its title strip is reachable - a window the user parked half off
/// a monitor, or straddling two, comes back the same - and is only repaired
/// when it would otherwise be lost:
///
///  * a monitor that still exists under the same name but has moved, or
///    changed scale, carries the window with it;
///  * a size below the layout's minimum (on the target monitor's scale), or
///    not finite, falls back to the default size;
///  * a window whose title strip is unreachable but which still overlaps a
///    monitor is moved, and if need be shrunk, into that monitor's work area;
///  * one that is on no monitor at all is centred on the primary.
WindowRestorePlan planWindowRestore({
  required List<MonitorInfo> monitors,
  SavedWindowPlacement? saved,
  double? legacyX,
  double? legacyY,
  double legacyWidth = 1280,
  double legacyHeight = 720,
  bool maximized = false,
  Size minLogicalSize = kMinWindowSize,
  Size defaultLogicalSize = kDefaultWindowSize,
}) {
  final primary = primaryMonitor(monitors);
  if (primary == null) {
    return WindowRestorePlan(
        bounds: null, maximized: maximized, source: 'no monitors');
  }

  Rect? rect;
  var source = 'default';
  if (saved != null) {
    rect = _followMonitor(saved, monitors);
    source = rect == saved.bounds ? 'saved' : 'saved, followed its monitor';
  } else {
    rect = migrateLegacyBounds(
        x: legacyX,
        y: legacyY,
        width: legacyWidth,
        height: legacyHeight,
        monitors: monitors);
    if (rect != null) source = 'legacy';
  }

  if (rect == null) {
    // No position at all (first run, or a reset): the remembered size if
    // there is one, centred on the primary.
    final s = primary.scale;
    final size = _usableSize(
        Size(legacyWidth * s, legacyHeight * s), primary,
        minLogicalSize: minLogicalSize, defaultLogicalSize: defaultLogicalSize);
    return WindowRestorePlan(
      bounds: _whole(_centredIn(primary.workArea, size)),
      maximized: maximized,
      source: source,
    );
  }

  final home = dominantMonitor(rect, monitors) ?? primary;
  final repairedSize = _usableSize(rect.size, home,
      minLogicalSize: minLogicalSize, defaultLogicalSize: defaultLogicalSize,
      clampToMonitor: false);
  if (repairedSize != rect.size) {
    rect = rect.topLeft & repairedSize;
    source = '$source, size repaired';
  }

  // Hanging partly into space no monitor covers is only accepted from a
  // record this build wrote, on a monitor that has not changed since: then
  // the user put it there. The legacy values cannot claim that - the drift
  // they suffered from is exactly how a window ends up two-fifths off
  // screen - and a monitor that changed resolution moved the edges the
  // window was placed against. Straddling two monitors is not hanging off:
  // every part of it is still on one.
  final distrusted = saved == null || _monitorChanged(saved, monitors);
  if (distrusted && !_onScreen(rect, monitors)) {
    final target = dominantMonitor(rect, monitors);
    if (target != null) {
      rect = _fitInto(rect, target.workArea);
      source = '$source, fitted onto ${target.name}';
    }
  }

  if (titleStripReachable(rect, monitors)) {
    return WindowRestorePlan(
        bounds: _whole(rect), maximized: maximized, source: source);
  }

  final overlapping = dominantMonitor(rect, monitors);
  if (overlapping != null) {
    return WindowRestorePlan(
      bounds: _whole(_fitInto(rect, overlapping.workArea)),
      maximized: maximized,
      source: '$source, moved onto ${overlapping.name}',
    );
  }
  return WindowRestorePlan(
    bounds: _whole(_centredIn(primary.workArea,
        _clampSize(rect.size, primary.workArea.size))),
    maximized: maximized,
    source: '$source, rescued to the primary monitor',
  );
}

/// [saved]'s bounds, carried along if its monitor is still connected under
/// the same name but has moved in the virtual screen or changed scale.
Rect _followMonitor(SavedWindowPlacement saved, List<MonitorInfo> monitors) {
  final name = saved.monitorName;
  final then = saved.monitorBounds;
  if (name == null || name.isEmpty || then == null) return saved.bounds;
  MonitorInfo? now;
  for (final m in monitors) {
    if (m.name == name) now = m;
  }
  if (now == null) return saved.bounds;
  final ratio = (saved.dpi != null && saved.dpi! > 0) ? now.dpi / saved.dpi! : 1.0;
  if (now.bounds.topLeft == then.topLeft && ratio == 1.0) return saved.bounds;
  // Same offset from the monitor's corner, in the monitor's new scale.
  final offset = saved.bounds.topLeft - then.topLeft;
  return Rect.fromLTWH(
    now.bounds.left + offset.dx * ratio,
    now.bounds.top + offset.dy * ratio,
    saved.bounds.width * ratio,
    saved.bounds.height * ratio,
  );
}

/// Whether the saved monitor is gone or has a different size now.
bool _monitorChanged(SavedWindowPlacement saved, List<MonitorInfo> monitors) {
  final name = saved.monitorName;
  final then = saved.monitorBounds;
  if (name == null || name.isEmpty || then == null) return false;
  for (final m in monitors) {
    if (m.name == name) return m.bounds.size != then.size;
  }
  return true;
}

/// Whether every part of [rect] is inside some monitor's work area.
/// Monitors never overlap, so the parts can simply be summed.
bool _onScreen(Rect rect, List<MonitorInfo> monitors) {
  var covered = 0.0;
  for (final m in monitors) {
    covered += _overlap(rect, m.workArea);
  }
  return covered >= _area(rect) - 1.0;
}

/// [size] with a size below the minimum or not finite replaced by the
/// default; with [clampToMonitor], also no larger than [on]'s work area.
Size _usableSize(Size size, MonitorInfo on,
    {required Size minLogicalSize,
    required Size defaultLogicalSize,
    bool clampToMonitor = true}) {
  final s = on.scale;
  var w = size.width;
  var h = size.height;
  var repaired = false;
  if (!w.isFinite || w < minLogicalSize.width * s) {
    w = defaultLogicalSize.width * s;
    repaired = true;
  }
  if (!h.isFinite || h < minLogicalSize.height * s) {
    h = defaultLogicalSize.height * s;
    repaired = true;
  }
  final result = repaired
      ? Size(w.roundToDouble(), h.roundToDouble())
      : Size(w, h);
  // The default itself can exceed a small monitor. A saved size is left
  // alone here: a window may legitimately span two monitors, and the cases
  // where it must not are handled by fitting it.
  return (clampToMonitor || repaired)
      ? _clampSize(result, on.workArea.size)
      : result;
}

/// Whole physical pixels: a window has no fractional position, and a
/// fraction left in would make an unchanged window compare as moved.
Rect _whole(Rect r) => Rect.fromLTWH(r.left.roundToDouble(),
    r.top.roundToDouble(), r.width.roundToDouble(), r.height.roundToDouble());

Size _clampSize(Size size, Size limit) =>
    Size(math.min(size.width, limit.width), math.min(size.height, limit.height));

Rect _centredIn(Rect area, Size size) => Rect.fromLTWH(
      (area.left + (area.width - size.width) / 2).roundToDouble(),
      (area.top + (area.height - size.height) / 2).roundToDouble(),
      size.width,
      size.height,
    );

/// [rect] moved, and shrunk only if it does not fit, so it lies inside [area].
Rect _fitInto(Rect rect, Rect area) {
  final size = _clampSize(rect.size, area.size);
  final left = rect.left.clamp(area.left, area.right - size.width);
  final top = rect.top.clamp(area.top, area.bottom - size.height);
  return Rect.fromLTWH(left.toDouble(), top.toDouble(), size.width, size.height);
}

Rect? _rect(Map raw, String prefix) {
  String key(String name) => prefix.isEmpty
      ? name
      : '$prefix${name[0].toUpperCase()}${name.substring(1)}';
  final l = raw[key('left')], t = raw[key('top')];
  final w = raw[key('width')], h = raw[key('height')];
  if (l is! num || t is! num || w is! num || h is! num) return null;
  return Rect.fromLTWH(
      l.toDouble(), t.toDouble(), w.toDouble(), h.toDouble());
}
