import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/file_dialogs.dart';
import 'package:windows_file_picker/windows_file_picker.dart';

/// A file picker whose dialogs stay open until the test answers for the user.
///
/// Since file_picker 13 the real dialogs run off the UI isolate and no longer
/// block the app, so whatever opened one stays live behind it: it can be
/// closed, or pressed again, while the dialog is up. Each call lands in
/// [folders] or [files] as a completer the test resolves when it chooses.
///
/// [install] puts the real platform back when the test ends.
class HeldFilePicker extends FilePickerPlatform {
  final List<Completer<String?>> folders = [];
  final List<Completer<PlatformFile?>> files = [];

  /// The Windows options each dialog was opened with, folder and file alike,
  /// in call order: whether it was given an owner window, and which.
  final List<WindowsOptions> windowsOptions = [];

  /// Installs a fresh picker for the current test, from its body or setUp.
  /// The completers are made by the calls themselves, inside the test's
  /// zone, so pump() flushes their answers.
  static HeldFilePicker install() {
    final original = FilePickerPlatform.instance;
    final picker = HeldFilePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    return picker;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    this.windowsOptions.add(windowsOptions);
    final answer = Completer<String?>();
    folders.add(answer);
    return answer.future;
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) {
    this.windowsOptions.add(windowsOptions);
    final answer = Completer<PlatformFile?>();
    files.add(answer);
    return answer.future;
  }
}

/// Gives the dialogs [owner] as the app's window for the current test, as
/// startup does with the real one.
void ownDialogsBy(int owner) {
  FileDialogs.ownerWindow = owner;
  addTearDown(() => FileDialogs.ownerWindow = null);
}

/// Options that make the dialog owned by window [owner].
Matcher ownedBy(int owner) => isA<FilePickerWindowsOptions>()
    .having((o) => o.parentWindowHandle, 'parentWindowHandle', owner)
    .having((o) => o.lockParentWindow, 'lockParentWindow', isTrue);

/// A picked file that exists only as a path.
final class PickedPath extends PlatformFile {
  PickedPath(this.filePath);

  final String filePath;

  @override
  Uri get uri => Uri.file(filePath);

  @override
  String get name => uri.pathSegments.last;

  // Typed by inference: naming XFile would mean importing cross_file,
  // which this package does not depend on directly.
  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => null;

  @override
  Future<int?> length() async => null;

  @override
  Future<Uint8List> readAsBytes() => throw UnimplementedError();

  @override
  Stream<Uint8List> readAsByteStream() => throw UnimplementedError();
}
