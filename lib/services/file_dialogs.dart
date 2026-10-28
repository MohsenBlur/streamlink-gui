import 'package:file_picker/file_picker.dart';
import 'package:windows_file_picker/windows_file_picker.dart';

/// The app's file and folder dialogs, owned by its own window.
///
/// file_picker opens them unowned unless told otherwise (lockParentWindow
/// false): a top-level window of their own, which a click back on the app
/// buried behind it, with nothing on screen to say a dialog was still
/// waiting for an answer. Owned by the app's top-level window, a dialog stays
/// above the app and the app takes no input while it is open, as a Windows
/// dialog should behave. The callers keep their guards for an answer that
/// arrives after they have gone: a route can still close them in the
/// meantime (the tray's Exit, the update offer), and a dialog opens unowned
/// when there is no window handle to give it.
///
/// The owner is named, not left to the plugin: lockParentWindow without a
/// handle makes it use GetForegroundWindow() as the dialog opens, which is
/// another app's window whenever the user has switched away by then.
abstract final class FileDialogs {
  /// The app's top-level window (an HWND), set once window_manager knows it
  /// (`prepareWindow` in app_startup.dart); null until then, and in tests
  /// that do not set it.
  static int? ownerWindow;

  /// The options every dialog opens with: owned by [ownerWindow], or
  /// unowned as before when there is none - never the foreground guess.
  static WindowsOptions windowsOptions() {
    final owner = ownerWindow;
    if (owner == null || owner == 0) return const WindowsOptions();
    return FilePickerWindowsOptions(
      parentWindowHandle: owner,
      lockParentWindow: true,
    );
  }

  /// A folder, or null when the dialog was cancelled.
  static Future<String?> pickFolder() =>
      FilePicker.getDirectoryPath(windowsOptions: windowsOptions());

  /// One file, or null when the dialog was cancelled. pickFile, not
  /// pickFiles: since file_picker 12 pickFiles multi-picks by default.
  static Future<PlatformFile?> pickFile({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) =>
      FilePicker.pickFile(
        type: type,
        allowedExtensions: allowedExtensions,
        windowsOptions: windowsOptions(),
      );
}
