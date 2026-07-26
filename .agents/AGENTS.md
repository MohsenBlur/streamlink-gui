# Rules

- Always commit and push to GitHub after you're done with your work.
- Always build the Windows build and push it to releases on GitHub.

## Self-Updater & User Settings Preservation Rules (CRITICAL)

1. **Single-Script Smart Self-Elevating Updater**:
   - `lib/services/update_service.dart` generates a single, standalone `updater.ps1` script that dynamically checks target directory write permissions (`.perm_test`).
   - If the directory is writable (user/portable installations), `updater.ps1` runs directly without triggering UAC elevation. If protected (`C:\Program Files`), it self-elevates using `-Verb RunAs`.

2. **PowerShell Path Normalization & Windows Backslashes**:
   - ALL file and directory paths passed into PowerShell scripts MUST be normalized with forward-slashes (`/`) to avoid double-quote escape corruption (`\"`).
   - Native Windows tools (`robocopy` and process execution) receive backslashed paths (`$WinExePath = $ExePath.Replace('/', '\')`).

3. **User Config Preservation**:
   - `AppData/Roaming/TwitchStreamlinkGUI/channels_config.json` is the IMMUTABLE source of truth for user configuration.
   - `StorageService` MUST NEVER overwrite existing `AppData` configuration files.
   - `robocopy` in `updater.ps1` MUST ALWAYS specify `/XF "channels_config.json" "portable.txt"`.

4. **Background Hidden Execution**:
   - `updater.ps1` executes with `-WindowStyle Hidden` so update extraction and file replacement happen seamlessly in the background without terminal popup windows.
