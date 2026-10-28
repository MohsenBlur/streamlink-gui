import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins how main.dart wires the pieces whose rules are tested elsewhere.
///
/// What is left here is what the pumped screen (main_screen_test) cannot
/// see: main()'s startup, which runs before any screen, and wiring whose
/// effect needs a collaborator no fake stands in for. Each rule below is a
/// call the screen makes or no longer makes, so it reads the method it
/// belongs to, and fails if that call goes back to how it was. The rest moved
/// to behaviour: the shell's (app_shell_controller_test) and the screen's.
void main() {
  // Line endings as git stores them, whatever the checkout turned them into.
  final src =
      File('lib/main.dart').readAsStringSync().replaceAll('\r\n', '\n');

  /// From [open] (an opening bracket) to the bracket that closes it.
  String bracketed(int open, String opening, String closing) {
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      final c = src[i];
      if (c == opening) depth++;
      if (c == closing && --depth == 0) return src.substring(open, i + 1);
    }
    fail('unbalanced $opening$closing at $open');
  }

  /// The body of the first declaration starting with [signature]: past its
  /// parameter list (named parameters have braces too), the block after it.
  String bodyOf(String signature) {
    final at = src.indexOf(signature);
    expect(at, isNonNegative, reason: '$signature is gone from main.dart');
    final params = src.indexOf('(', at);
    final end = params + bracketed(params, '(', ')').length;
    return bracketed(src.indexOf('{', end), '{', '}');
  }

  test('the save-failure listener is taken off the global when the screen goes',
      () {
    // storageWriteFailure outlives the screen; the closure added to it was
    // never removed.
    expect(bodyOf('void initState()'),
        contains('storageWriteFailure.addListener(_onSaveFailureChanged)'));
    expect(bodyOf('void dispose()'),
        contains('storageWriteFailure.removeListener(_onSaveFailureChanged)'));
  });

  test('a snackbar after the screen went is dropped, not thrown', () {
    expect(bodyOf('void _showSnackBar('), contains('if (!mounted) return;'));
  });

  test('the recently-watched list is written only through the repository',
      () {
    // Removing a VOD from the history wrote it straight to the storage
    // service, round the gate that holds writes until the list is read.
    expect('_storageService.saveRecentWatchedVods('.allMatches(src),
        hasLength(1),
        reason: "only the repository's own writer");
    expect(bodyOf('Future<void> _removeLibraryEntryFromHistory('),
        contains('_settingsRepo.saveNow(recents: true)'));
  });

  test('a window hidden to the tray is not shown again by the startup check',
      () {
    // The shell marks the window (app_shell_controller_test); the check after
    // the first frame, which runs before any screen exists, has to read it.
    expect(bodyOf('Future<void> _checkWindowAfterFirstFrame('),
        contains('hiddenByUser: AppShellController.windowHiddenByUser'));
  });

  test('a VOD auto-download announces is left out of the New VOD toast', () {
    expect(bodyOf('void _onNewVods('),
        contains('_automation.newVodsToAnnounce('));
  });

  test('a session end freezes the download queue, and letting go thaws it',
      () {
    // The shell calls these at the right moments - a process that outlives
    // the session end included (app_shell_controller_test); they have to be
    // the queue's.
    final at = src.indexOf('AppShellController(');
    expect(at, isNonNegative);
    final call = bracketed(src.indexOf('(', at), '(', ')');
    expect(call, contains('onSessionEnding: _downloads.freeze'));
    expect(call, contains('onSessionContinues: _downloads.unfreeze'));
  });

  test("the surface engine's status says which switch forced Canvas", () {
    expect(src, contains("'--canvas-engine flag'"));
    expect(src, contains("'Simple rendering setting'"));
    expect(src, contains('forceCanvasReason: canvasReason'));
  });
}
