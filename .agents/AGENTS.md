# Rules

- Always commit and push to GitHub after you're done with your work.
- Always build the Windows build and push it to releases on GitHub.
- NEVER remove `.github/workflows/release.yml` or break the automated versioning and build release pipeline on GitHub. (Modifying the workflow to maintain, fix, or improve it is allowed, but completely removing it requires explicit permission).

## Self-Updater & User Settings Preservation Rules (CRITICAL)

1. **Native Win32 Smart Self-Elevating Helper (`updater.exe`)**:
   - `lib/services/update_service.dart` orchestrates update downloads and spawns a standalone native C++ binary `updater.exe` (`windows/runner/win32_updater/main.cpp`).
   - `updater.exe` dynamically probes target directory write permissions (`IsDirWritable`). If writable (portable / user directory), it runs directly without UAC popups. If protected (`C:\Program Files`), it self-elevates via UAC `ShellExecuteExW` with `runas` verb.

2. **Windows Path Normalization & Quote Escape Prevention**:
   - ALL file and directory paths passed into Windows processes (`updater.exe`) MUST be normalized and stripped of trailing backslashes/slashes (`/` or `\`) to prevent Windows `CommandLineToArgvW` quote escape corruption (`\"`).

3. **User Config Preservation & Safe Rollback**:
   - `channels_config.json` and `portable.txt` MUST NEVER be overwritten during directory file replacement (`CopyDirectoryContents`).
   - `updater.exe` creates a full backup in `%TEMP%\streamlink_gui_backup` prior to file replacement and automatically restores from backup if replacement fails.

4. **Detached Process Execution & Mutex Sync**:
   - `updater.exe` is copied to `%TEMP%\streamlink_updater_runner.exe` before execution to prevent binary locking, waits for `Local\TwitchStreamlinkGUIUniqueMutexName`, terminates any remaining target folder processes, replaces files, and gracefully relaunches the updated main app executable.
