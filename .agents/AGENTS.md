# Rules

- Always commit and push to GitHub after you're done with your work.
- Always build the Windows build and push it to releases on GitHub.

## Self-Updater & User Settings Preservation Rules (CRITICAL)

1. **PowerShell Path Normalization**:
   - ALL file and directory paths passed into PowerShell scripts in `lib/services/update_service.dart` MUST be normalized with forward-slashes (`/`) (e.g. `C:/Program Files/Streamlink GUI`).
   - NEVER interpolate raw Windows backslashes `\` inside PowerShell string literals, as trailing backslashes escape double quotes `\"` and break script parsing.

2. **User Config Preservation**:
   - `AppData/Roaming/TwitchStreamlinkGUI/channels_config.json` is the IMMUTABLE source of truth for user configuration (saved channels, window positions/dimensions, theme settings, download paths).
   - `StorageService` MUST NEVER overwrite existing `AppData` configuration files with files from the application installation directory (`exeDir`).
   - `robocopy` in `updater.ps1` MUST ALWAYS specify `/XF "channels_config.json" "portable.txt"` to ensure user config files are NEVER replaced during self-updates.

3. **De-Elevated Relaunch**:
   - `updater.ps1` MUST relaunch the updated executable via `Start-Process "explorer.exe" -ArgumentList '"$ExePath"'` so the application runs under the standard desktop user token (non-elevated).

4. **Hidden Window Execution**:
   - Both `launch_updater.ps1` and `updater.ps1` MUST execute with `-WindowStyle Hidden` so no console or terminal windows pop up or remain open on screen.
