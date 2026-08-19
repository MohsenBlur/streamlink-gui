import 'dart:io';

/// Manages the HKCU Run registry value that launches the app at Windows
/// startup.
///
/// Implemented with short-lived `reg.exe` children instead of a win32 FFI
/// dependency: they exit in milliseconds, so living briefly inside the app's
/// kill-on-close job object is harmless, and the win32 package is not a
/// direct dependency of this project.
class StartupService {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'TwitchStreamlinkGUI';

  /// Writes or removes the Run value. When enabling, the value is always
  /// rewritten with the CURRENT executable path plus `--start-minimized`, so
  /// calling this at every startup silently heals a moved install.
  Future<void> sync(bool enabled) async {
    if (!Platform.isWindows) return;
    try {
      if (enabled) {
        final exe = Platform.resolvedExecutable;
        await Process.run('reg', [
          'add',
          _runKey,
          '/v',
          _valueName,
          '/t',
          'REG_SZ',
          '/d',
          '"$exe" --start-minimized',
          '/f',
        ]);
      } else {
        // Deleting a value that does not exist returns nonzero; that is fine.
        await Process.run('reg', ['delete', _runKey, '/v', _valueName, '/f']);
      }
    } catch (_) {
      // Registry access failing must never break app startup.
    }
  }
}
