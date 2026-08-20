import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/app_settings.dart';
import '../services/player_service.dart';
import '../services/twitch_api_service.dart';
import '../services/update_service.dart';
import '../utils/color_utils.dart';
import '../theme/neu_material_themes.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_switch.dart';

// Abstract theme notifier interface to break dependencies
abstract class ThemeUpdateListener extends ChangeNotifier {
  Color get primaryColor;
  Color get backgroundColor;
  Color get surfaceColor;
  Color get lightShadowColor;
  Color get darkShadowColor;
  Color get textColor;
  Color get subtextColor;
  Color get activeProgressColor;
  Color get watchedProgressColor;
  Color get lightAccentColor;
  Color get darkAccentColor;
  bool get isDarkTheme;

  void setDarkTheme(bool isDark);
  void setLightAccent(Color color);
  void setDarkAccent(Color color);

  void updateTheme({
    Color? activeProgress,
    Color? watchedProgress,
  });
}

class SettingsDialog {
  static Future<void> show(
    BuildContext context, {
    required AppSettings settings,
    required ThemeUpdateListener themeNotifier,
    required String? authenticatedUserLogin,
    required VoidCallback onConnectAccount,
    required void Function(AppSettings) onSave,
    required void Function(String) openExternalLink,
    required VoidCallback onClearWatchHistory,
    /// Invoked when the in-dialog update check finds a newer release, so the
    /// app can offer to install it. Without this the dialog told the user to
    /// "check the main window prompt", which only ever appears at startup.
    void Function(UpdateInfo)? onUpdateAvailable,
  }) {
    String tempQuality = settings.defaultQuality;
    bool tempLowLatency = settings.twitchLowLatency;
    String tempPlayerType = settings.playerType;
    int tempWatchedThreshold = settings.watchedThreshold;
    int tempMaxRecentlyWatched = settings.maxRecentlyWatched;
    String tempCloseAction = settings.closeAction;
    String tempMinimizeAction = settings.minimizeAction;
    bool tempLaunchAtStartup = settings.launchAtStartup;
    bool tempStartMinimized = settings.startMinimized;
    bool tempTrayLiveMenu = settings.trayLiveMenuEnabled;
    final tokenController = TextEditingController(text: settings.twitchOauthToken);
    final webTokenController = TextEditingController(text: settings.twitchWebOauthToken);
    final playerPathController = TextEditingController(text: settings.customPlayerPath);
    final playerArgsController = TextEditingController(text: settings.customPlayerArgs);
    final clientIdController = TextEditingController(text: settings.twitchClientId);
    final portController = TextEditingController(text: settings.localServerPort.toString());
    final downloadFolderController = TextEditingController(text: settings.vodDownloadFolder);
    final maxDownloadsController = TextEditingController(
      text: settings.maxDownloadsToKeep == 0 ? '' : settings.maxDownloadsToKeep.toString()
    );
    bool tempDisableVodPostProcessing = settings.disableVodPostProcessing;
    final customVodArgsController = TextEditingController(text: settings.customVodArgs);
    bool tempNotifyWentLive = settings.notifyWentLive;
    bool tempNotifyAutoPlay = settings.notifyAutoPlay;
    bool tempNotifyAutoDownloadStart = settings.notifyAutoDownloadStart;
    bool tempNotifyDownloadComplete = settings.notifyDownloadComplete;

    // One probe per dialog open. This used to run 8x on EVERY rebuild (each
    // probe shells out / stats the filesystem for four players).
    final detectedPlayers = PlayerService().detectInstalledPlayers(settings);
    // The custom-path entry is the exception: it must react to what the user
    // is typing, not to the last saved settings.
    bool customPathValid() {
      final path = playerPathController.text.trim();
      if (path.isEmpty) return false;
      try {
        return File(path).existsSync();
      } catch (_) {
        return false;
      }
    }

    String? portError;
    String? maxDownloadsError;
    String? validatePort(String value) {
      final t = value.trim();
      if (t.isEmpty) return 'Required (1-65535)';
      final n = int.tryParse(t);
      if (n == null || n < 1 || n > 65535) return 'Must be 1-65535';
      return null;
    }

    String? validateMaxDownloads(String value) {
      final t = value.trim();
      if (t.isEmpty) return null;
      final n = int.tryParse(t);
      if (n == null || n < 0) return 'Whole number, or empty for unlimited';
      return null;
    }

    // In-dialog update-check feedback; a SnackBar renders BEHIND the modal
    // barrier and was easy to miss entirely.
    String? updateCheckResult;
    bool updateCheckIsError = false;
    bool isCheckingUpdates = false;
    bool obscureToken = true;
    bool obscureWebToken = true;
    bool isTestingToken = false;
    String? tokenTestResult;
    bool isTokenValid = false;

    // The Styling tab edits the theme notifier live so the user sees the change
    // immediately. Remember the entry state so Cancel can put it back, instead
    // of leaving the UI on a theme that was never saved.
    final originalIsDarkTheme = themeNotifier.isDarkTheme;
    final originalLightAccent = themeNotifier.lightAccentColor;
    final originalDarkAccent = themeNotifier.darkAccentColor;

    void restoreLiveThemeEdits() {
      themeNotifier.setLightAccent(originalLightAccent);
      themeNotifier.setDarkAccent(originalDarkAccent);
      themeNotifier.setDarkTheme(originalIsDarkTheme);
    }

    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return DefaultTabController(
              length: 5,
              child: AlertDialog(
                titlePadding: EdgeInsets.zero,
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                      child: Row(
                        children: [
                          Icon(Icons.settings, color: themeNotifier.primaryColor),
                          const SizedBox(width: 10),
                          Text('Streamlink Settings', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
                        ],
                      ),
                    ),
                    TabBar(
                      labelColor: themeNotifier.primaryColor,
                      unselectedLabelColor: NeuTheme.subtext(themeNotifier.isDarkTheme),
                      indicatorColor: themeNotifier.primaryColor,
                      indicatorSize: TabBarIndicatorSize.tab,
                      isScrollable: true,
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      tabs: const [
                        Tab(text: 'General'),
                        Tab(text: 'Player'),
                        Tab(text: 'Twitch Auth'),
                        Tab(text: 'Styling'),
                        Tab(text: 'Downloads'),
                      ],
                    ),
                  ],
                ),
                backgroundColor: themeNotifier.surfaceColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: themeNotifier.primaryColor.withValues(alpha: 0.3), width: 1.5),
                ),
                content: SizedBox(
                  width: 520,
                  height: 520,
                  child: TabBarView(
                    children: [
                      // TAB 1: GENERAL SETTINGS
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Default Video Quality',
                              style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: tempQuality,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: 12),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'best', child: Text('Best Available')),
                                DropdownMenuItem(value: '1080p60', child: Text('1080p60 (Source)')),
                                DropdownMenuItem(value: '1080p', child: Text('1080p')),
                                DropdownMenuItem(value: '720p60', child: Text('720p60')),
                                DropdownMenuItem(value: '720p', child: Text('720p')),
                                DropdownMenuItem(value: '480p', child: Text('480p')),
                                DropdownMenuItem(value: '360p', child: Text('360p')),
                                DropdownMenuItem(value: 'worst', child: Text('Worst Available')),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() {
                                    tempQuality = val;
                                  });
                                }
                              },
                            ),
                            const SizedBox(height: 18),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Low Latency Streams', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Reduces delay on Twitch streams',
                                      style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                                    ),
                                  ],
                                ),
                                NeuSwitch(
                                  value: tempLowLatency,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) {
                                    setDialogState(() {
                                      tempLowLatency = val;
                                    });
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Text('VOD Watched Threshold', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Mark VOD as fully watched at $tempWatchedThreshold% completion.', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text('50%', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                                Expanded(
                                  child: SliderTheme(
                                    data: neuSliderTheme(context, accent: themeNotifier.primaryColor),
                                    child: Slider(
                                      value: tempWatchedThreshold.toDouble(),
                                      min: 50,
                                      max: 100,
                                      onChanged: (val) {
                                        setDialogState(() {
                                          tempWatchedThreshold = val.round();
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                Text('100%', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Text('Recently Watched VODs Limit', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Limit dashboard watch history to $tempMaxRecentlyWatched VODs.', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text('1', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                                Expanded(
                                  child: SliderTheme(
                                    data: neuSliderTheme(context, accent: themeNotifier.primaryColor),
                                    child: Slider(
                                      value: tempMaxRecentlyWatched.toDouble(),
                                      min: 1,
                                      max: 20,
                                      onChanged: (val) {
                                        setDialogState(() {
                                          tempMaxRecentlyWatched = val.round();
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                Text('20', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                              ],
                            ),
                            const SizedBox(height: 24),
                            Divider(color: NeuTheme.border(themeNotifier.isDarkTheme)),
                            const SizedBox(height: 12),
                            Text('Window & Tray', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Close button', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                DropdownButton<String>(
                                  value: tempCloseAction,
                                  underline: const SizedBox.shrink(),
                                  style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                  dropdownColor: themeNotifier.surfaceColor,
                                  items: const [
                                    DropdownMenuItem(value: 'tray', child: Text('Minimize to tray')),
                                    DropdownMenuItem(value: 'exit', child: Text('Exit the app')),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) setDialogState(() => tempCloseAction = val);
                                  },
                                ),
                              ],
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Minimize button', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                DropdownButton<String>(
                                  value: tempMinimizeAction,
                                  underline: const SizedBox.shrink(),
                                  style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                  dropdownColor: themeNotifier.surfaceColor,
                                  items: const [
                                    DropdownMenuItem(value: 'taskbar', child: Text('Minimize to taskbar')),
                                    DropdownMenuItem(value: 'tray', child: Text('Minimize to tray')),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) setDialogState(() => tempMinimizeAction = val);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Launch at Windows startup', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                      Text('Starts minimized to the tray.', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 10)),
                                    ],
                                  ),
                                ),
                                NeuSwitch(
                                  value: tempLaunchAtStartup,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempLaunchAtStartup = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Start minimized to tray', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                NeuSwitch(
                                  value: tempStartMinimized,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempStartMinimized = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Live favorites in tray menu', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                      Text('Right-click the tray icon to launch a live favorite directly.', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 10)),
                                    ],
                                  ),
                                ),
                                NeuSwitch(
                                  value: tempTrayLiveMenu,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempTrayLiveMenu = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            Divider(color: NeuTheme.border(themeNotifier.isDarkTheme)),
                            const SizedBox(height: 12),
                            Text('Notifications', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Favorite channel goes live', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                NeuSwitch(
                                  value: tempNotifyWentLive,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyWentLive = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Auto-play starts a stream', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                NeuSwitch(
                                  value: tempNotifyAutoPlay,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyAutoPlay = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Auto-download starts', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                NeuSwitch(
                                  value: tempNotifyAutoDownloadStart,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyAutoDownloadStart = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Download completes', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                NeuSwitch(
                                  value: tempNotifyDownloadComplete,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyDownloadComplete = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            Divider(color: NeuTheme.border(themeNotifier.isDarkTheme)),
                            const SizedBox(height: 12),
                            Text('Watch History', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                side: BorderSide(color: NeuTheme.dangerText(themeNotifier.isDarkTheme), width: 1),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text('Clear Watch History?', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
                                    backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    content: Text('Are you sure you want to clear your local watch progress history for all VODs? This action cannot be undone.', style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: Text('Cancel', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
                                      ),
                                      TextButton(
                                        style: TextButton.styleFrom(foregroundColor: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                                        onPressed: () {
                                          Navigator.pop(context);
                                          onClearWatchHistory();
                                        },
                                        child: const Text('Clear History'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              icon: const Icon(Icons.delete_forever, size: 18),
                              label: const Text('Clear Local Watch History', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),

                      // TAB 2: PLAYER SETTINGS
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Player Type', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              initialValue: tempPlayerType,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: 12),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'default',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Default System Player'),
                                      const SizedBox(width: 8),
                                      Text('(Available)', style: TextStyle(fontSize: 10, color: NeuTheme.liveText(themeNotifier.isDarkTheme), fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'vlc',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('VLC Media Player'),
                                      const SizedBox(width: 8),
                                      Text(
                                        detectedPlayers['vlc'] == true ? '(Detected)' : '(Not Found)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: detectedPlayers['vlc'] == true ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'mpv',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('MPV Player'),
                                      const SizedBox(width: 8),
                                      Text(
                                        detectedPlayers['mpv'] == true ? '(Detected)' : '(Not Found)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: detectedPlayers['mpv'] == true ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'mpc-hc',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('MPC-HC Player'),
                                      const SizedBox(width: 8),
                                      Text(
                                        detectedPlayers['mpc-hc'] == true ? '(Detected)' : '(Not Found)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: detectedPlayers['mpc-hc'] == true ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'custom',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Custom Executable Path'),
                                      if (playerPathController.text.trim().isNotEmpty) ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          customPathValid() ? '(Valid Path)' : '(File Missing)',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: customPathValid() ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() {
                                    tempPlayerType = val;
                                  });
                                }
                              },
                            ),
                            if (tempPlayerType == 'custom') ...[
                              const SizedBox(height: 18),
                              Text('Custom Player Executable Path', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: playerPathController,
                                      style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                      onChanged: (_) => setDialogState(() {}),
                                      decoration: const InputDecoration(
                                        hintText: 'e.g. C:\\Program Files\\MPV\\mpv.exe',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: themeNotifier.primaryColor,
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                                    ),
                                    onPressed: () async {
                                      final FilePickerResult? result = await FilePicker.platform.pickFiles(
                                        type: FileType.custom,
                                        allowedExtensions: ['exe', 'app', 'sh', 'bat', 'cmd'],
                                      );
                                      if (result != null && result.files.single.path != null) {
                                        setDialogState(() {
                                          playerPathController.text = result.files.single.path!;
                                        });
                                      }
                                    },
                                    icon: Icon(Icons.file_open, color: NeuTheme.onAccent(themeNotifier.primaryColor), size: 16),
                                    label: Text('Browse', style: TextStyle(color: NeuTheme.onAccent(themeNotifier.primaryColor), fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                              if (playerPathController.text.trim().isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Icon(
                                      customPathValid() ? Icons.check_circle : Icons.error_outline,
                                      size: 13,
                                      color: customPathValid()
                                          ? NeuTheme.liveText(themeNotifier.isDarkTheme)
                                          : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      customPathValid() ? 'Executable found' : 'File not found at this path',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: customPathValid()
                                            ? NeuTheme.liveText(themeNotifier.isDarkTheme)
                                            : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                            const SizedBox(height: 18),
                            Text('Custom Player Arguments (Optional)', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: playerArgsController,
                              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
                              decoration: const InputDecoration(
                                hintText: 'e.g. --ontop --no-border (for mpv)',
                              ),
                            ),
                          ],
                        ),
                      ),

                      // TAB 3: TWITCH AUTH
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Twitch API Authentication', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 14)),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            settings.twitchOauthToken.trim().isNotEmpty ? Icons.check_circle : Icons.error_outline,
                                            color: settings.twitchOauthToken.trim().isNotEmpty ? NeuTheme.liveText(themeNotifier.isDarkTheme) : (themeNotifier.isDarkTheme ? Colors.orangeAccent : Colors.orange.shade800),
                                            size: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            settings.twitchOauthToken.trim().isNotEmpty
                                                ? (authenticatedUserLogin != null ? 'Connected: $authenticatedUserLogin' : 'Connected')
                                                : 'Not connected',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: settings.twitchOauthToken.trim().isNotEmpty ? NeuTheme.liveText(themeNotifier.isDarkTheme) : (themeNotifier.isDarkTheme ? Colors.orangeAccent : Colors.orange.shade800),
                                            ),
                                          ),
                                        ],
                                      ),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: themeNotifier.primaryColor,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () {
                                          onConnectAccount();
                                          Navigator.pop(context);
                                        },
                                        icon: Icon(Icons.login, size: 12, color: NeuTheme.onAccent(themeNotifier.primaryColor)),
                                        label: Text('Connect Account', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: NeuTheme.onAccent(themeNotifier.primaryColor))),
                                      ),
                                    ],
                                  ),
                                  if (settings.twitchOauthToken.trim().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      'Connecting allows you to automatically load your followed channels, view channel VOD lists, stream subscriber-only feeds, and remove ads.',
                                      style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 10),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text('Twitch Client ID', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                            const SizedBox(height: 4),
                            TextField(
                              controller: clientIdController,
                              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 11),
                              decoration: const InputDecoration(
                                hintText: 'Twitch Client ID',
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text('OAuth Callback Port', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                            const SizedBox(height: 4),
                            Text(
                              'Local port the Connect Account flow listens on. Must match the redirect URL registered with the Client ID above.',
                              style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 10),
                            ),
                            const SizedBox(height: 4),
                            TextField(
                              controller: portController,
                              keyboardType: TextInputType.number,
                              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 11),
                              onChanged: (val) => setDialogState(() => portError = validatePort(val)),
                              decoration: InputDecoration(
                                hintText: 'e.g. 65432',
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                errorText: portError,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Twitch OAuth Token (Optional)', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                TextButton(
                                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                  onPressed: () => openExternalLink('https://twitchapps.com/tmi/'),
                                  child: const Text('Get Token Manually', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: tokenController,
                              obscureText: obscureToken,
                              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                              decoration: InputDecoration(
                                hintText: 'oauth:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                suffixIcon: IconButton(
                                  icon: Icon(obscureToken ? Icons.visibility : Icons.visibility_off, size: 16),
                                  onPressed: () => setDialogState(() => obscureToken = !obscureToken),
                                  constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Twitch Browser Token (Optional, for VOD Sync)', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 12)),
                                IconButton(
                                  icon: const Icon(Icons.help_outline, size: 16),
                                  color: themeNotifier.primaryColor,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _showBrowserTokenHelp(context, themeNotifier),
                                  tooltip: 'How to get Browser Token',
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: webTokenController,
                                    obscureText: obscureWebToken,
                                    style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                    decoration: InputDecoration(
                                      hintText: 'e.g. 5vnv4iix6wz8y31ok3p7xlccuyb72s',
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      suffixIcon: IconButton(
                                        icon: Icon(obscureWebToken ? Icons.visibility : Icons.visibility_off, size: 16),
                                        onPressed: () => setDialogState(() => obscureWebToken = !obscureWebToken),
                                        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  height: 36,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isTestingToken ? NeuTheme.surface(themeNotifier.isDarkTheme) : themeNotifier.primaryColor,
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                    ),
                                    onPressed: isTestingToken
                                        ? null
                                        : () async {
                                            setDialogState(() {
                                              isTestingToken = true;
                                              tokenTestResult = null;
                                            });
                                            final result = await TwitchApiService()
                                                .validateOAuthToken(webTokenController.text);
                                            setDialogState(() {
                                              isTestingToken = false;
                                              isTokenValid = result.isValid;
                                              tokenTestResult = result.message;
                                            });
                                          },
                                    child: isTestingToken
                                        ? SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: NeuTheme.onAccent(themeNotifier.primaryColor)),
                                          )
                                        : Text('Test', style: TextStyle(color: NeuTheme.onAccent(themeNotifier.primaryColor), fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                              ],
                            ),
                            if (tokenTestResult != null) ...[
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Icon(
                                    isTokenValid ? Icons.check_circle : Icons.error,
                                    size: 14,
                                    color: isTokenValid ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      tokenTestResult!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isTokenValid ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),

                      // TAB 4: STYLING & COLORS
                      // TAB 4: THEME & STYLING SETTINGS
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Application Theme Mode', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 14)),
                            const SizedBox(height: 4),
                            Text('Choose between Soft Light and Deep Dark Neumorphic themes.', style: TextStyle(fontSize: 11, color: themeNotifier.subtextColor)),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      themeNotifier.setDarkTheme(false);
                                      setDialogState(() {});
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: NeuTheme.raisedDecoration(
                                        false,
                                        radius: 12,
                                        border: Border.all(
                                          color: !themeNotifier.isDarkTheme ? themeNotifier.primaryColor : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                      // Intentional: the preview card renders the LIGHT theme's own
                                      // colors regardless of the active theme.
                                      child: Column(
                                        children: const [
                                          Icon(Icons.light_mode, color: Color(0xFFFF6584), size: 24),
                                          SizedBox(height: 6),
                                          Text('Soft Light', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2D3748))),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      themeNotifier.setDarkTheme(true);
                                      setDialogState(() {});
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: NeuTheme.raisedDecoration(
                                        true,
                                        radius: 12,
                                        border: Border.all(
                                          color: themeNotifier.isDarkTheme ? themeNotifier.primaryColor : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                      // Intentional: the preview card renders the DARK theme's own
                                      // colors regardless of the active theme.
                                      child: Column(
                                        children: const [
                                          Icon(Icons.dark_mode, color: Color(0xFFFF3B30), size: 24),
                                          SizedBox(height: 6),
                                          Text('Deep Dark', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFE2E8F0))),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            Text('Light Theme Accent Color', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Accent color used when Soft Light theme is active.', style: TextStyle(fontSize: 11, color: themeNotifier.subtextColor)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              // Intentional: these hexes ARE the selectable accent swatches.
                              children: [
                                const Color(0xFFFF6584), // Soft Pink
                                const Color(0xFF7C3AED), // Twitch Purple
                                const Color(0xFF00F2FE), // Cyan
                                const Color(0xFF10B981), // Emerald
                                const Color(0xFFFF7A00), // Orange
                                const Color(0xFFF43F5E), // Rose
                              ].map((color) {
                                final isSelected = themeNotifier.lightAccentColor.toARGB32() == color.toARGB32();
                                return GestureDetector(
                                  onTap: () {
                                    themeNotifier.setLightAccent(color);
                                    setDialogState(() {});
                                  },
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected ? NeuTheme.text(themeNotifier.isDarkTheme) : NeuTheme.border(themeNotifier.isDarkTheme),
                                        width: isSelected ? 3.0 : 1.0,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 24),
                            Text('Dark Theme Accent Color', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Accent color used when Deep Dark theme is active.', style: TextStyle(fontSize: 11, color: themeNotifier.subtextColor)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              // Intentional: these hexes ARE the selectable accent swatches.
                              children: [
                                const Color(0xFFFF3B30), // Vibrant Red
                                const Color(0xFF8B5CF6), // Electric Purple
                                const Color(0xFF38BDF8), // Sky Blue
                                const Color(0xFFFF2A85), // Magenta
                                const Color(0xFFF59E0B), // Gold
                                const Color(0xFF10B981), // Emerald
                              ].map((color) {
                                final isSelected = themeNotifier.darkAccentColor.toARGB32() == color.toARGB32();
                                return GestureDetector(
                                  onTap: () {
                                    themeNotifier.setDarkAccent(color);
                                    setDialogState(() {});
                                  },
                                  child: Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: isSelected ? NeuTheme.text(themeNotifier.isDarkTheme) : NeuTheme.border(themeNotifier.isDarkTheme),
                                        width: isSelected ? 3.0 : 1.0,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                      
                      // TAB 5: DOWNLOAD SETTINGS
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('VOD Download Directory', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: downloadFolderController,
                                    style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
                                    decoration: const InputDecoration(
                                      hintText: 'e.g. C:\\Downloads\\TwitchVODs',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: themeNotifier.primaryColor,
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                                  ),
                                  onPressed: () async {
                                    final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                                    if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
                                      setDialogState(() {
                                        downloadFolderController.text = selectedDirectory;
                                      });
                                    }
                                  },
                                  icon: Icon(Icons.folder_open, color: NeuTheme.onAccent(themeNotifier.primaryColor), size: 16),
                                  label: Text('Browse', style: TextStyle(color: NeuTheme.onAccent(themeNotifier.primaryColor), fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Text('Maximum downloads to keep (Threshold)', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Delete oldest downloads automatically when limit is reached. Leave empty or set to 0 for unlimited.', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: maxDownloadsController,
                              keyboardType: TextInputType.number,
                              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
                              onChanged: (val) => setDialogState(
                                  () => maxDownloadsError = validateMaxDownloads(val)),
                              decoration: InputDecoration(
                                hintText: 'e.g. 5, 10, or leave empty',
                                errorText: maxDownloadsError,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Fast VOD Downloads (Skip heavy post-processing)', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Bypasses slow thumbnail/metadata container rewrites after download completion (prevents multi-gigabyte VODs from taking forever after 100%).',
                                        style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                NeuSwitch(
                              activeColor: themeNotifier.primaryColor,
                              value: tempDisableVodPostProcessing,
                              onChanged: (val) {
                                setDialogState(() {
                                  tempDisableVodPostProcessing = val;
                                });
                              },
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text('Custom yt-dlp VOD Download Arguments', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Pass additional options directly to yt-dlp when downloading VODs.', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: customVodArgsController,
                              style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
                              decoration: const InputDecoration(
                                hintText: 'e.g. --concurrent-fragments 5 --no-mtime',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 6),
                            child: Text(
                              'v${UpdateService.currentVersion}',
                              style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => openExternalLink(UpdateService.githubRepoUrl),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.code, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                  const SizedBox(width: 4),
                                  Text(
                                    'GitHub Repo',
                                    style: TextStyle(fontSize: 11, color: themeNotifier.primaryColor, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                            onPressed: isCheckingUpdates
                                ? null
                                : () async {
                                    setDialogState(() {
                                      isCheckingUpdates = true;
                                      updateCheckResult = null;
                                    });
                                    final updateInfo = await UpdateService().checkForUpdates();
                                    if (!context.mounted) return;

                                    // checkForUpdates returns a non-null UpdateInfo
                                    // for any successful query and reports
                                    // availability via isUpdateAvailable.
                                    setDialogState(() {
                                      isCheckingUpdates = false;
                                      if (updateInfo == null) {
                                        updateCheckResult = 'Check failed - no connection?';
                                        updateCheckIsError = true;
                                      } else if (updateInfo.isUpdateAvailable) {
                                        updateCheckResult =
                                            'v${updateInfo.version} available - close Settings to install';
                                        updateCheckIsError = false;
                                      } else {
                                        updateCheckResult = 'Up to date (v${UpdateService.currentVersion})';
                                        updateCheckIsError = false;
                                      }
                                    });

                                    if (updateInfo != null && updateInfo.isUpdateAvailable) {
                                      onUpdateAvailable?.call(updateInfo);
                                    }
                                  },
                            icon: isCheckingUpdates
                                ? SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 1.5,
                                        color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                  )
                                : Icon(Icons.refresh, size: 13, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                            label: Text('Check for Updates', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                          ),
                          if (updateCheckResult != null) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                updateCheckResult!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: updateCheckIsError
                                      ? NeuTheme.dangerText(themeNotifier.isDarkTheme)
                                      : NeuTheme.liveText(themeNotifier.isDarkTheme),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () {
                              restoreLiveThemeEdits();
                              Navigator.pop(context);
                            },
                            child: Text('Cancel', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.primaryColor),
                            onPressed: (portError != null || maxDownloadsError != null)
                                ? null
                                : () {
                              // copyWith, not a fresh AppSettings: constructing a new
                              // instance from only the fields this dialog knows about
                              // silently reset every other persisted field to its
                              // default, so saving wiped the theme mode, window
                              // geometry, the VOD watch exclusion threshold and the
                              // auto-play preemption toggle.
                              final updated = settings.copyWith(
                                defaultQuality: tempQuality,
                                twitchLowLatency: tempLowLatency,
                                playerType: tempPlayerType,
                                watchedThreshold: tempWatchedThreshold,
                                twitchOauthToken: tokenController.text.trim(),
                                twitchWebOauthToken: webTokenController.text.trim(),
                                customPlayerPath: playerPathController.text.trim(),
                                customPlayerArgs: playerArgsController.text.trim(),
                                twitchClientId: clientIdController.text.trim(),
                                localServerPort: int.tryParse(portController.text.trim()) ?? settings.localServerPort,
                                vodDownloadFolder: downloadFolderController.text.trim(),
                                maxDownloadsToKeep: int.tryParse(maxDownloadsController.text.trim()) ?? 0,
                                maxRecentlyWatched: tempMaxRecentlyWatched,
                                closeAction: tempCloseAction,
                                minimizeAction: tempMinimizeAction,
                                launchAtStartup: tempLaunchAtStartup,
                                startMinimized: tempStartMinimized,
                                trayLiveMenuEnabled: tempTrayLiveMenu,
                                notifyWentLive: tempNotifyWentLive,
                                notifyAutoPlay: tempNotifyAutoPlay,
                                notifyAutoDownloadStart: tempNotifyAutoDownloadStart,
                                notifyDownloadComplete: tempNotifyDownloadComplete,
                                disableVodPostProcessing: tempDisableVodPostProcessing,
                                customVodArgs: customVodArgsController.text.trim(),
                                // The Styling tab edits these on the notifier directly;
                                // persist what it currently holds so the choice survives
                                // a restart instead of reverting to Dark + default accent.
                                isDarkTheme: themeNotifier.isDarkTheme,
                                lightAccentColorHex: colorToHex(themeNotifier.lightAccentColor),
                                darkAccentColorHex: colorToHex(themeNotifier.darkAccentColor),
                              );

                              onSave(updated);
                              Navigator.pop(context);
                            },
                            child: Text('Save Changes', style: TextStyle(color: NeuTheme.onAccent(themeNotifier.primaryColor), fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      // The dialog is gone; nothing can be typing into these anymore.
      tokenController.dispose();
      webTokenController.dispose();
      playerPathController.dispose();
      playerArgsController.dispose();
      clientIdController.dispose();
      portController.dispose();
      downloadFolderController.dispose();
      maxDownloadsController.dispose();
      customVodArgsController.dispose();
    });
  }

  static void _showBrowserTokenHelp(BuildContext context, ThemeUpdateListener themeNotifier) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.help_outline, color: themeNotifier.primaryColor),
              const SizedBox(width: 10),
              Text('How to get Browser Token', style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 16)),
            ],
          ),
          backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'To enable background watch progress syncing and VOD progress bars, you must copy your first-party browser login token from Twitch:',
                    style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  _buildStep('1', 'Open your web browser, go to twitch.tv, and make sure you are logged in to your account.', themeNotifier),
                  const SizedBox(height: 12),
                  _buildStep('2', 'Press F12 (or right-click anywhere on the page and select Inspect) to open the Developer Tools panel.', themeNotifier),
                  const SizedBox(height: 12),
                  _buildStep('3', 'Locate your cookies:\n• Chrome/Edge: Go to the Application tab -> expand Cookies on the left -> select https://www.twitch.tv\n• Firefox: Go to the Storage tab -> expand Cookies -> select https://www.twitch.tv', themeNotifier),
                  const SizedBox(height: 12),
                  _buildStep('4', 'In the cookies list, find the one named auth-token. Double-click its value, copy it, and paste it into the settings field.', themeNotifier),
                  const SizedBox(height: 16),
                  Divider(color: NeuTheme.border(themeNotifier.isDarkTheme)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.info, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Note: Do NOT click "Log Out" on the Twitch website after copying this token. Clicking log out will immediately revoke the token on Twitch\'s servers.',
                          style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.primaryColor),
              onPressed: () => Navigator.pop(context),
              child: Text('Got it!', style: TextStyle(color: NeuTheme.onAccent(themeNotifier.primaryColor), fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  static Widget _buildStep(String number, String text, ThemeUpdateListener themeNotifier) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 10),
          child: Text(
            number,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: themeNotifier.isDarkTheme ? Colors.orangeAccent : Colors.orange.shade800),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 13).copyWith(height: 1.35),
          ),
        ),
      ],
    );
  }
}
