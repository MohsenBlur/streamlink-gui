import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/widgets/shell/route_handle.dart';

/// The update flow's failure path: it must close the progress dialog it
/// opened, not whatever happens to be on top.
void main() {
  late BuildContext home;

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        home = context;
        return const Scaffold(body: Text('home'));
      }),
    ));
  }

  RouteHandle openProgress() {
    final handle = RouteHandle();
    showDialog<void>(
      context: home,
      barrierDismissible: false,
      builder: (context) {
        handle.attach(context);
        return const AlertDialog(content: Text('Updating'));
      },
    );
    return handle;
  }

  testWidgets('closes its own dialog when something covers it', (tester) async {
    await pumpHome(tester);
    final progress = openProgress();
    await tester.pumpAndSettle();
    // The tray's Exit, say, opening its question over the progress dialog.
    showDialog<void>(
      context: home,
      builder: (_) => const AlertDialog(content: Text('Downloads are running')),
    );
    await tester.pumpAndSettle();

    expect(progress.close(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Updating'), findsNothing,
        reason: 'the stuck dialog is the one with no way out');
    expect(find.text('Downloads are running'), findsOneWidget,
        reason: 'Navigator.pop would have closed this one instead');
  });

  testWidgets('pops its dialog normally when it is on top', (tester) async {
    await pumpHome(tester);
    final progress = openProgress();
    await tester.pumpAndSettle();

    expect(progress.isOpen, isTrue);
    expect(progress.close(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Updating'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(progress.isOpen, isFalse);
  });

  testWidgets('does nothing once its dialog is gone', (tester) async {
    await pumpHome(tester);
    final progress = openProgress();
    await tester.pumpAndSettle();
    Navigator.of(home).pop();
    await tester.pumpAndSettle();

    expect(progress.close(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget,
        reason: 'closing a gone dialog must not pop the page under it');
  });

  test('a handle that never attached closes nothing', () {
    expect(RouteHandle().close(), isFalse);
  });
}
