import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/log_store.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/log_viewer_dialog.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

/// Five sessions, each with a line of its own.
LogNotifier logsWithSessions() {
  final logs = LogNotifier();
  for (var i = 0; i < 5; i++) {
    logs.beginSession('dl-$i', 'Download: A recorded stream $i');
    logs.appendLog('dl-$i', '[Download] line from session $i');
    if (i.isOdd) logs.endSession('dl-$i', 1);
  }
  return logs;
}

void main() {
  /// Opens the real dialog through its real entry point at [size], failing
  /// on any overflow.
  Future<void> open(WidgetTester tester, Size size, LogNotifier logs,
      {String? initialKey}) async {
    final overflows = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exception.toString();
      if (text.contains('overflowed')) {
        overflows.add(text.split('\n').first);
      } else {
        previous?.call(details);
      }
    };
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          primaryColor: NeuTheme.defaultDarkAccent,
        ),
        home: AppLayout(
          data: AppLayoutData.fromSize(size),
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => LogViewerDialog.show(context,
                    logs: logs, initialKey: initialKey),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previous;
    }
    expect(overflows, isEmpty,
        reason: 'at ${size.width.toInt()}x${size.height.toInt()}:\n'
            '${overflows.join('\n')}');
  }

  /// The log text pane: the only SelectionArea in the dialog.
  Rect logPane(WidgetTester tester) =>
      tester.getRect(find.byType(SelectionArea));

  /// The dialog's sheet - the Material inside [Dialog], whose own box spans
  /// the whole window.
  Rect dialog(WidgetTester tester) => tester.getRect(find
      .descendant(of: find.byType(Dialog), matching: find.byType(Material))
      .first);

  testWidgets('at the 380px minimum the log gets the dialog\'s full width',
      (tester) async {
    // Regression: the fixed 210px session column left the log ~70px wide,
    // a few characters per line.
    final logs = logsWithSessions();
    addTearDown(logs.dispose);
    await open(tester, const Size(380, 500), logs);

    final pane = logPane(tester);
    final sheet = dialog(tester);
    expect(pane.width, greaterThan(sheet.width * 0.75),
        reason: 'log pane ${pane.width} in a ${sheet.width} dialog');

    // The sessions moved above it, and are still all there to pick from.
    final firstTile =
        tester.getRect(find.text(logs.sessions.first.label));
    expect(firstTile.bottom, lessThanOrEqualTo(pane.top));
  });

  testWidgets('picking a session in the strip shows its log', (tester) async {
    final logs = logsWithSessions();
    addTearDown(logs.dispose);
    await open(tester, const Size(380, 500), logs);

    // The strip shows one tile and a part of the next, so tap the part of
    // the second tile that is on screen - which is also where a user would.
    final second = logs.sessions[1];
    await tester.tapAt(
        tester.getTopLeft(find.text(second.label)) + const Offset(8, 4));
    await tester.pump();

    final index = second.key.substring(3);
    expect(find.text('[Download] line from session $index'), findsOneWidget);
  });

  testWidgets('the strip opens on the session that was asked for',
      (tester) async {
    // "View log" on a failure can name an older session; the strip is
    // newest first, so without this it would open off to the right.
    final logs = logsWithSessions();
    addTearDown(logs.dispose);
    final last = logs.sessions.last;
    await open(tester, const Size(380, 500), logs, initialKey: last.key);

    final tile = tester.getRect(find.text(last.label));
    final sheet = dialog(tester);
    expect(tile.left, greaterThanOrEqualTo(sheet.left));
    expect(tile.right, lessThanOrEqualTo(sheet.right));
  });

  testWidgets('a wide window keeps the side-by-side layout', (tester) async {
    final logs = logsWithSessions();
    addTearDown(logs.dispose);
    await open(tester, const Size(1280, 800), logs);

    final pane = logPane(tester);
    final tile = tester.getRect(find.text(logs.sessions.first.label));
    expect(tile.right, lessThan(pane.left),
        reason: 'sessions in a column to the left of the log');
    expect(tile.top, lessThan(pane.bottom));
    expect(pane.width, greaterThan(500));
  });
}
