import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/onboarding_wizard.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

/// A folder picker that stays open until the test answers for the user.
class _HeldPicker extends FilePickerPlatform {
  final List<Completer<String?>> opened = [];

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    final answer = Completer<String?>();
    opened.add(answer);
    return answer.future;
  }
}

void main() {
  late FilePickerPlatform original;
  late _HeldPicker picker;

  setUp(() {
    original = FilePickerPlatform.instance;
    picker = _HeldPicker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() => FilePickerPlatform.instance = original);

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
    expect(picker.opened, hasLength(1));
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

    picker.opened.single.complete(r'D:\VODs');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a folder picked while the wizard is open is shown',
      (tester) async {
    await openFolderStep(tester);
    picker.opened.single.complete(r'D:\VODs');
    await tester.pumpAndSettle();
    expect(find.text(r'D:\VODs'), findsOneWidget);
  });
}
