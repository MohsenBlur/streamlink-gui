import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/file_dialogs.dart';
import 'package:windows_file_picker/windows_file_picker.dart';

import 'support/held_file_picker.dart';

/// The owner window every file and folder dialog is opened with.
///
/// Unowned (file_picker's default), a dialog was a top-level window of its
/// own and fell behind the app at the first click back on it. The four
/// pickers each have a test of their own beside their screen's; this pins the
/// rule they share.
void main() {
  test("with the app's window known, a dialog is owned by it", () {
    ownDialogsBy(0x2A0B4);
    expect(FileDialogs.windowsOptions(), ownedBy(0x2A0B4));
  });

  test('with no window to give it, a dialog opens unowned', () {
    // Never lockParentWindow without a handle: the plugin then takes
    // GetForegroundWindow(), which can be another app's window.
    for (final owner in [null, 0]) {
      FileDialogs.ownerWindow = owner;
      addTearDown(() => FileDialogs.ownerWindow = null);
      final options = FileDialogs.windowsOptions();
      expect(options, isNot(isA<FilePickerWindowsOptions>()), reason: '$owner');
      expect(options.lockParentWindow, isFalse, reason: '$owner');
    }
  });

  test('no dialog in the app is opened round FileDialogs', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (file.path.replaceAll('\\', '/').endsWith('services/file_dialogs.dart')) continue;
      if (file.readAsStringSync().contains('FilePicker.')) offenders.add(file.path);
    }
    expect(offenders, isEmpty,
        reason: 'FilePicker called directly opens an unowned dialog');
  });

  test('startup hands FileDialogs the window window_manager reports', () {
    final src = File('lib/app_startup.dart').readAsStringSync();
    expect(src, contains('FileDialogs.ownerWindow = await windowManager.getId()'));
  });

  test('a file dialog is one file, not a multi-pick', () async {
    final picker = HeldFilePicker.install();
    ownDialogsBy(7);
    final picked = FileDialogs.pickFile(
        type: FileType.custom, allowedExtensions: const ['exe']);
    expect(picker.files, hasLength(1));
    expect(picker.windowsOptions.single, ownedBy(7));
    picker.files.single.complete(null);
    expect(await picked, isNull);
  });
}
