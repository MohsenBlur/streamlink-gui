import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/onboarding_wizard.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

import 'support/held_file_picker.dart';

void main() {
  late HeldFilePicker picker;

  setUp(() => picker = HeldFilePicker.install());

  Future<void> openFolderStep(WidgetTester tester) async {
    const size = Size(1280, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
              onPressed: () =>
                  OnboardingWizard.show(context, settings: AppSettings()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Welcome, then the player, then the download folder.
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Browse'));
    await tester.pump();
    expect(picker.folders, hasLength(1));
  }

  testWidgets('a folder picked after the wizard was skipped is ignored',
      (tester) async {
    // Since file_picker 13 the folder dialog runs off the UI isolate, so the
    // wizard stays live behind it: Skip setup (or Esc) can close it while
    // the dialog is still open. The answer then arrives for a disposed
    // step, and setState on it threw.
    await openFolderStep(tester);

    await tester.tap(find.text('Skip setup'));
    await tester.pumpAndSettle();
    expect(find.text('Browse'), findsNothing, reason: 'the wizard is gone');

    picker.folders.single.complete(r'D:\VODs');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a folder picked while the wizard is open is shown',
      (tester) async {
    await openFolderStep(tester);
    picker.folders.single.complete(r'D:\VODs');
    await tester.pumpAndSettle();
    expect(find.text(r'D:\VODs'), findsOneWidget);
  });

  testWidgets('Browse opens one folder dialog at a time', (tester) async {
    // The dialog no longer holds the app, so a second click on Browse
    // opened a second dialog, and whichever answered last won.
    await openFolderStep(tester);
    await tester.tap(find.text('Browse'));
    await tester.pump();
    expect(picker.folders, hasLength(1));

    picker.folders.single.complete(null);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browse'));
    await tester.pump();
    expect(picker.folders, hasLength(2), reason: 'closed, it works again');
  });
}
