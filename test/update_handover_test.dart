import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A window close that lands while the app hands over to the updater.
///
/// The updater signals that it is ready, and may close the window, up to a
/// poll (50ms) before the app sees the signal and starts exiting. A close in
/// between was answered as a normal one: hidden to the tray with the "still
/// running" toast, or an Exit refused because an update is running.
///
/// No test pumps MainScreen (window_manager, the tray and storage would all
/// need standing in for), so this reads the source, as the other main.dart
/// checks do.
void main() {
  final source = File('lib/main.dart').readAsStringSync();

  /// The method starting at [signature], up to its closing brace.
  String methodBody(String signature) {
    final start = source.indexOf(signature);
    expect(start, greaterThan(0), reason: '$signature not found');
    final end = source.indexOf(RegExp(r'\r?\n  }\r?\n'), start);
    return source.substring(start, end);
  }

  test('the handover is marked before the updater is started', () {
    final update = methodBody('void _performAppUpdate(');
    final marked = update.indexOf('_handingOverToUpdater = true');
    final started = update.indexOf('startUpdater(');
    expect(marked, greaterThan(0));
    expect(marked, lessThan(started),
        reason: 'the updater can signal and close before startUpdater returns');

    // A handover that fails leaves the app running, closable as usual.
    final failure = update.substring(update.indexOf('} catch (e) {', started));
    expect(failure, contains('_handingOverToUpdater = false'));
  });

  test('a close during the handover is not answered as a normal close', () {
    final close = methodBody('void onWindowClose()');
    final guard = close.indexOf('_handingOverToUpdater');
    expect(guard, greaterThan(0));
    expect(guard, lessThan(close.indexOf('_handleAppExitRequest')));
    expect(guard, lessThan(close.indexOf('_hideWindow')));
  });
}
