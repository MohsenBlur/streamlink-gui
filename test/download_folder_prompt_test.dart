import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/widgets/download_folder_prompt.dart';

import 'support/held_file_picker.dart';

/// The prompt a download raises when no download folder is set.
///
/// Its folder dialog stopped blocking the app with file_picker 13, so the
/// prompt is live the whole time that dialog is open. What it answers when
/// it is dismissed underneath an open dialog is what main.dart saves - and
/// a folder saved for a download that had already been cancelled was the bug.
void main() {
  late HeldFilePicker picker;
  late List<String?> answers;

  setUp(() => answers = <String?>[]);

  Future<void> openPrompt(WidgetTester tester) async {
    picker = HeldFilePicker.install();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answers.add(await DownloadFolderPrompt.show(context)),
            child: const Text('download'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('download'));
    await tester.pumpAndSettle();
    expect(find.text('Where should VODs be saved?'), findsOneWidget);
  }

  testWidgets('a picked folder is the answer', (tester) async {
    await openPrompt(tester);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();
    picker.folders.single.complete(r'D:\VODs');
    await tester.pumpAndSettle();

    expect(answers, [r'D:\VODs']);
    expect(find.text('Where should VODs be saved?'), findsNothing);
  });

  testWidgets('a cancelled folder dialog leaves the prompt up', (tester) async {
    await openPrompt(tester);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();
    picker.folders.single.complete(null);
    await tester.pumpAndSettle();

    expect(answers, isEmpty);
    expect(find.text('Where should VODs be saved?'), findsOneWidget);
  });

  testWidgets('a folder picked after the prompt was dismissed is dropped',
      (tester) async {
    await openPrompt(tester);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();

    // Esc reaches the prompt: the folder dialog no longer holds the app.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(answers, [null], reason: 'dismissed is cancelled');

    picker.folders.single.complete(r'D:\VODs');
    await tester.pumpAndSettle();
    expect(answers, [null], reason: 'nothing is saved for the late answer');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a folder landing while the prompt animates out pops nothing',
      (tester) async {
    // The prompt is still mounted for its whole exit transition. Popping
    // "the prompt" with the late answer there popped whatever route was on
    // top by then - the page under it.
    await openPrompt(tester);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Where should VODs be saved?'), findsOneWidget,
        reason: 'precondition: still inside the exit transition');

    picker.folders.single.complete(r'D:\VODs');
    await tester.pumpAndSettle();
    expect(answers, [null]);
    expect(find.text('download'), findsOneWidget,
        reason: 'the page under the prompt is still there');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Choose folder opens one folder dialog at a time',
      (tester) async {
    await openPrompt(tester);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();
    expect(find.text('Pick a folder in the window that opened.'),
        findsOneWidget);
    await tester.tap(find.text('Choose folder'));
    await tester.pump();
    expect(picker.folders, hasLength(1));

    // Closed without a pick: the button works again.
    picker.folders.single.complete(null);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pump();
    expect(picker.folders, hasLength(2));
  });
}
