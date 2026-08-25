import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/app_settings.dart';
import '../services/player_service.dart';
import '../services/twitch_api_service.dart';
import '../services/update_service.dart';
import '../utils/color_utils.dart';
import '../theme/neu_material_themes.dart';
import '../theme/material/app_material.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_progress.dart';
import 'shell/engraved_rule.dart';
import 'shell/neu_dialog.dart';
import 'neumorphic/neu_switch.dart';

// Abstract theme notifier interface to break dependencies
abstract class ThemeUpdateListener extends ChangeNotifier {
  Color get primaryColor;

  /// The accent made safe to use as a foreground. See [NeuTheme.accentInk].
  Color get accentInk;
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

  /// Which material world the app is wearing.
  ///
  /// On this interface rather than only on the notifier because the settings
  /// dialog never sees `AppThemeNotifier` - it is handed a
  /// `ThemeUpdateListener`. Without these two members the material picker
  /// cannot be built at all.
  AppMaterial get material;

  void setDarkTheme(bool isDark);
  void setMaterial(AppMaterial material);
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
    required VoidCallback onOpenLogs,
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
    bool tempSeekableVodStreaming = settings.seekableVodStreaming;
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
    final originalMaterial = themeNotifier.material;

    void restoreLiveThemeEdits() {
      themeNotifier.setLightAccent(originalLightAccent);
      themeNotifier.setDarkAccent(originalDarkAccent);
      themeNotifier.setDarkTheme(originalIsDarkTheme);
      // Cancel has to undo the material too. Without this, previewing a
      // material and then cancelling left the app wearing it until the next
      // launch, at which point it silently reverted - which reads as the app
      // forgetting a choice rather than as Cancel working.
      themeNotifier.setMaterial(originalMaterial);
    }

    // Not dismissible: the dialog stages every edit and applies theme changes
    // live, so a click on the scrim would discard typed tokens and paths while
    // leaving the accent it had already previewed.
    return NeuDialog.show<void>(
      context,
      dismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return DefaultTabController(
              length: 5,
              child: NeuDialog(
                title: 'Settings',
                icon: Icons.settings,
                width: 600,
                maxHeight: 680,
                scrollable: false,
                headerBottom: Container(
                  // The recessed track the selector's key slides in - the
                  // same physical vocabulary as NeuSegmentedControl, which
                  // the sidebar's tabs already speak. A flat underline
                  // indicator split the design language inside one window.
                  margin: const EdgeInsets.fromLTRB(
                      NeuSpace.s16, 0, NeuSpace.s16, NeuSpace.s8),
                  padding: const EdgeInsets.all(NeuSpace.s2),
                  decoration: NeuTheme.sunken(themeNotifier.isDarkTheme,
                      radius: NeuRadius.r8, depth: NeuElevation.d1),
                  child: TabBar(
                  labelColor: themeNotifier.accentInk,
                  unselectedLabelColor: NeuTheme.subtext(themeNotifier.isDarkTheme),
                  // The raised sliding key, painted by the engine.
                  indicator: NeuTheme.raised(themeNotifier.isDarkTheme,
                      radius: NeuRadius.r6, depth: NeuElevation.d2),
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelStyle: NeuType.labelMetrics.copyWith(fontWeight: FontWeight.w700),
                  tabs: const [
                    Tab(text: 'Playback'),
                    Tab(text: 'Downloads'),
                    Tab(text: 'Appearance'),
                    Tab(text: 'Twitch'),
                    Tab(text: 'System'),
                  ],
                ),
                ),
                // Expanded rather than a hard 520: TabBarView has no intrinsic
                // height, and a fixed one cannot fit the 380x500 window the app
                // itself permits.
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: TabBarView(
                    children: [
                      // PANEL 1: Playback - streamlink flags and the player itself
                      SingleChildScrollView(
                        // s4 lateral gave a raised control 4px before the
                        // pane's clip - its shadow ended in a hard line at
                        // the pane edge, worst on the material-picker tiles
                        // whose whole job is to demo the lit surface.
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s8, vertical: NeuSpace.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Default Video Quality',
                              style: NeuType.headingSm(themeNotifier.isDarkTheme),
                            ),
                            const SizedBox(height: NeuSpace.s8),
                            DropdownButtonFormField<String>(
                              initialValue: tempQuality,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: NeuSpace.s12),
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
                            const SizedBox(height: NeuSpace.s16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Low Latency Streams', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                                    const SizedBox(height: NeuSpace.s4),
                                    // Streamlink's own help warns this can
                                    // cause buffering, so the trade-off
                                    // belongs on the switch, not in a wiki.
                                    Text(
                                      'Cuts delay on live streams. May buffer more.',
                                      style: NeuType.caption(themeNotifier.isDarkTheme),
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
                            const SizedBox(height: NeuSpace.s16),
                            Text('VOD Watched Threshold', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text('Mark VOD as fully watched at $tempWatchedThreshold% completion.', style: NeuType.caption(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            Row(
                              children: [
                                Text('50%', style: NeuType.caption(themeNotifier.isDarkTheme)),
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
                                Text('100%', style: NeuType.caption(themeNotifier.isDarkTheme)),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s16),
                            Text('Recently Watched VODs Limit', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text('Limit dashboard watch history to $tempMaxRecentlyWatched VODs.', style: NeuType.caption(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            Row(
                              children: [
                                Text('1', style: NeuType.caption(themeNotifier.isDarkTheme)),
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
                                Text('20', style: NeuType.caption(themeNotifier.isDarkTheme)),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s24),
                            EngravedRule(),
                            const SizedBox(height: NeuSpace.s12),
                            Text('Player Type', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            DropdownButtonFormField<String>(
                              initialValue: tempPlayerType,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'default',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('Default System Player'),
                                      const SizedBox(width: NeuSpace.s8),
                                      Text('(Available)', style: NeuType.plate(themeNotifier.isDarkTheme, color: NeuTheme.liveText(themeNotifier.isDarkTheme))),
                                    ],
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'vlc',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text('VLC Media Player'),
                                      const SizedBox(width: NeuSpace.s8),
                                      Text(
                                        detectedPlayers['vlc'] == true ? '(Detected)' : '(Not Found)',
                                        style: NeuType.plate(themeNotifier.isDarkTheme, color: detectedPlayers['vlc'] == true ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme)),
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
                                      const SizedBox(width: NeuSpace.s8),
                                      Text(
                                        detectedPlayers['mpv'] == true ? '(Detected)' : '(Not Found)',
                                        style: NeuType.plate(themeNotifier.isDarkTheme, color: detectedPlayers['mpv'] == true ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme)),
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
                                      const SizedBox(width: NeuSpace.s8),
                                      Text(
                                        detectedPlayers['mpc-hc'] == true ? '(Detected)' : '(Not Found)',
                                        style: NeuType.plate(themeNotifier.isDarkTheme, color: detectedPlayers['mpc-hc'] == true ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme)),
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
                                        const SizedBox(width: NeuSpace.s8),
                                        Text(
                                          customPathValid() ? '(Valid Path)' : '(File Missing)',
                                          style: NeuType.plate(themeNotifier.isDarkTheme, color: customPathValid() ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme)),
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
                              const SizedBox(height: NeuSpace.s16),
                              Text('Custom Player Executable Path', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                              const SizedBox(height: NeuSpace.s6),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: playerPathController,
                                      style: NeuType.bodySm(themeNotifier.isDarkTheme),
                                      onChanged: (_) => setDialogState(() {}),
                                      decoration: const InputDecoration(
                                        hintText: 'e.g. C:\\Program Files\\MPV\\mpv.exe',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: NeuSpace.s8),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: themeNotifier.primaryColor,
                                      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s16),
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
                                    label: Text('Browse',
                                        style: NeuType.labelMetrics.copyWith(
                                            color: NeuTheme.onAccent(
                                                themeNotifier.primaryColor))),
                                  ),
                                ],
                              ),
                              if (playerPathController.text.trim().isNotEmpty) ...[
                                const SizedBox(height: NeuSpace.s6),
                                Row(
                                  children: [
                                    Icon(
                                      customPathValid() ? Icons.check_circle : Icons.error_outline,
                                      size: 13,
                                      color: customPathValid()
                                          ? NeuTheme.liveText(themeNotifier.isDarkTheme)
                                          : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                    ),
                                    const SizedBox(width: NeuSpace.s6),
                                    Text(
                                      customPathValid() ? 'Executable found' : 'File not found at this path',
                                      style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: customPathValid()
                                            ? NeuTheme.liveText(themeNotifier.isDarkTheme)
                                            : NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                            const SizedBox(height: NeuSpace.s16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Seekable VOD streaming', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                                      const SizedBox(height: NeuSpace.s2),
                                      Text(
                                        "Hands the player the VOD's stream address instead of piping the video through Streamlink, so the player's own seek bar works. Turn off if streamed VODs fail to open, or to let Streamlink filter ad segments.",
                                        style: NeuType.caption(themeNotifier.isDarkTheme),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: NeuSpace.s8),
                                NeuSwitch(
                                  value: tempSeekableVodStreaming,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempSeekableVodStreaming = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s16),
                            Text('Custom Player Arguments (Optional)', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s6),
                            TextField(
                              controller: playerArgsController,
                              style: NeuType.body(themeNotifier.isDarkTheme),
                              decoration: const InputDecoration(
                                hintText: 'e.g. --ontop --no-border (for mpv)',
                              ),
                            ),
                          ],
                        ),
                      ),
                      // PANEL 2: Downloads
                      SingleChildScrollView(
                        // s4 lateral gave a raised control 4px before the
                        // pane's clip - its shadow ended in a hard line at
                        // the pane edge, worst on the material-picker tiles
                        // whose whole job is to demo the lit surface.
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s8, vertical: NeuSpace.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('VOD Download Directory', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: downloadFolderController,
                                    style: NeuType.body(themeNotifier.isDarkTheme),
                                    decoration: const InputDecoration(
                                      hintText: 'e.g. C:\\Downloads\\TwitchVODs',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: NeuSpace.s8),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: themeNotifier.primaryColor,
                                    padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s16),
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
                                  label: Text('Browse',
                                        style: NeuType.labelMetrics.copyWith(
                                            color: NeuTheme.onAccent(
                                                themeNotifier.primaryColor))),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s16),
                            Text('Maximum downloads to keep (Threshold)', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text('Delete oldest downloads automatically when limit is reached. Leave empty or set to 0 for unlimited.', style: NeuType.caption(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            TextField(
                              controller: maxDownloadsController,
                              keyboardType: TextInputType.number,
                              style: NeuType.body(themeNotifier.isDarkTheme),
                              onChanged: (val) => setDialogState(
                                  () => maxDownloadsError = validateMaxDownloads(val)),
                              decoration: InputDecoration(
                                hintText: 'e.g. 5, 10, or leave empty',
                                errorText: maxDownloadsError,
                              ),
                            ),
                            const SizedBox(height: NeuSpace.s16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Fast VOD Downloads (Skip heavy post-processing)', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                                      const SizedBox(height: NeuSpace.s2),
                                      Text(
                                        'Bypasses slow thumbnail/metadata container rewrites after download completion (prevents multi-gigabyte VODs from taking forever after 100%).',
                                        style: NeuType.caption(themeNotifier.isDarkTheme),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: NeuSpace.s8),
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
                            const SizedBox(height: NeuSpace.s12),
                            Text('Custom yt-dlp VOD Download Arguments', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text('Pass additional options directly to yt-dlp when downloading VODs.', style: NeuType.caption(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            TextField(
                              controller: customVodArgsController,
                              style: NeuType.body(themeNotifier.isDarkTheme),
                              decoration: const InputDecoration(
                                hintText: 'e.g. --concurrent-fragments 5 --no-mtime',
                              ),
                            ),
                          ],
                        ),
                      ),
                      // PANEL 3: Appearance - theme, accent, styling
                      SingleChildScrollView(
                        // s4 lateral gave a raised control 4px before the
                        // pane's clip - its shadow ended in a hard line at
                        // the pane edge, worst on the material-picker tiles
                        // whose whole job is to demo the lit surface.
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s8, vertical: NeuSpace.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Material', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text(
                              'What the app is made of. Changes the surfaces, '
                              'the light and the ornament - never the layout.',
                              style: NeuType.caption(themeNotifier.isDarkTheme,
                                  color: themeNotifier.subtextColor),
                            ),
                            const SizedBox(height: NeuSpace.s12),
                            _MaterialPicker(
                              themeNotifier: themeNotifier,
                              onChanged: () => setDialogState(() {}),
                            ),
                            const SizedBox(height: NeuSpace.s24),
                            Text('Application Theme Mode', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text('Choose between Soft Light and Deep Dark Neumorphic themes.', style: NeuType.caption(themeNotifier.isDarkTheme, color: themeNotifier.subtextColor)),
                            const SizedBox(height: NeuSpace.s12),
                            Row(
                              children: [
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      themeNotifier.setDarkTheme(false);
                                      setDialogState(() {});
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(NeuSpace.s12),
                                      decoration: NeuTheme.raisedDecoration(
                                        false,
                                        radius: NeuRadius.r12,
                                        border: Border.all(
                                          color: !themeNotifier.isDarkTheme ? themeNotifier.primaryColor : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                      // Intentional: the preview card renders the LIGHT theme's own
                                      // colors regardless of the active theme.
                                      child: Column(
                                        // Not const: these two tiles preview the
                                        // OTHER theme, so their ink is fixed
                                        // while the style call is not.
                                        children: [
                                          const Icon(Icons.light_mode, color: NeuTheme.defaultLightAccent, size: 24),
                                          const SizedBox(height: NeuSpace.s6),
                                          Text('Soft Light', style: NeuType.label(themeNotifier.isDarkTheme, color: NeuTheme.lightText)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: NeuSpace.s12),
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () {
                                      themeNotifier.setDarkTheme(true);
                                      setDialogState(() {});
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.all(NeuSpace.s12),
                                      decoration: NeuTheme.raisedDecoration(
                                        true,
                                        radius: NeuRadius.r12,
                                        border: Border.all(
                                          color: themeNotifier.isDarkTheme ? themeNotifier.primaryColor : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                      // Intentional: the preview card renders the DARK theme's own
                                      // colors regardless of the active theme.
                                      child: Column(
                                        // Not const: these two tiles preview the
                                        // OTHER theme, so their ink is fixed
                                        // while the style call is not.
                                        children: [
                                          const Icon(Icons.dark_mode, color: NeuTheme.defaultDarkAccent, size: 24),
                                          const SizedBox(height: NeuSpace.s6),
                                          Text('Deep Dark', style: NeuType.label(themeNotifier.isDarkTheme, color: NeuTheme.darkText)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s24),
                            Text('Light Theme Accent Color', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text('Accent color used when Soft Light theme is active.', style: NeuType.caption(themeNotifier.isDarkTheme, color: themeNotifier.subtextColor)),
                            const SizedBox(height: NeuSpace.s8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              // Intentional: these hexes ARE the selectable accent swatches.
                              children: [
                                NeuTheme.defaultLightAccent, // Soft Pink
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
                            const SizedBox(height: NeuSpace.s24),
                            Text('Dark Theme Accent Color', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text('Accent color used when Deep Dark theme is active.', style: NeuType.caption(themeNotifier.isDarkTheme, color: themeNotifier.subtextColor)),
                            const SizedBox(height: NeuSpace.s8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              // Intentional: these hexes ARE the selectable accent swatches.
                              children: [
                                NeuTheme.defaultDarkAccent, // Vibrant Red
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
                      // PANEL 4: Twitch - account and authentication
                      SingleChildScrollView(
                        // s4 lateral gave a raised control 4px before the
                        // pane's clip - its shadow ended in a hard line at
                        // the pane edge, worst on the material-picker tiles
                        // whose whole job is to demo the lit surface.
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s8, vertical: NeuSpace.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Twitch API Authentication', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            Container(
                              padding: const EdgeInsets.all(NeuSpace.s12),
                              decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r8),
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
                                            color: settings.twitchOauthToken.trim().isNotEmpty ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.warningText(themeNotifier.isDarkTheme),
                                            size: 16,
                                          ),
                                          const SizedBox(width: NeuSpace.s8),
                                          Text(
                                            settings.twitchOauthToken.trim().isNotEmpty
                                                ? (authenticatedUserLogin != null ? 'Connected: $authenticatedUserLogin' : 'Connected')
                                                : 'Not connected',
                                            style: NeuType.label(themeNotifier.isDarkTheme, color: settings.twitchOauthToken.trim().isNotEmpty ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.warningText(themeNotifier.isDarkTheme)),
                                          ),
                                        ],
                                      ),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: themeNotifier.primaryColor,
                                          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () {
                                          onConnectAccount();
                                          // Restore before popping: this exits
                                          // the dialog without saving, so the
                                          // live theme edits from the
                                          // Appearance tab have to come back
                                          // the way Cancel brings them back.
                                          // Without it the session runs on a
                                          // material the config does not
                                          // record and the next launch
                                          // silently reverts - the exact
                                          // symptom the restore exists to
                                          // prevent. Escape and the scrim are
                                          // both disabled, so this was the
                                          // only unguarded exit.
                                          restoreLiveThemeEdits();
                                          Navigator.pop(context);
                                        },
                                        icon: Icon(Icons.login, size: 12, color: NeuTheme.onAccent(themeNotifier.primaryColor)),
                                        label: Text('Connect Account', style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.onAccent(themeNotifier.primaryColor))),
                                      ),
                                    ],
                                  ),
                                  if (settings.twitchOauthToken.trim().isNotEmpty) ...[
                                    const SizedBox(height: NeuSpace.s8),
                                    Text(
                                      'Connecting allows you to automatically load your followed channels, view channel VOD lists, stream subscriber-only feeds, and remove ads.',
                                      style: NeuType.caption(themeNotifier.isDarkTheme),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: NeuSpace.s12),
                            Text('Twitch Client ID', style: NeuType.label(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            TextField(
                              controller: clientIdController,
                              style: NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                              decoration: const InputDecoration(
                                hintText: 'Twitch Client ID',
                                contentPadding: EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
                              ),
                            ),
                            const SizedBox(height: NeuSpace.s12),
                            Text('OAuth Callback Port', style: NeuType.label(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text(
                              'Local port the Connect Account flow listens on. Must match the redirect URL registered with the Client ID above.',
                              style: NeuType.caption(themeNotifier.isDarkTheme),
                            ),
                            const SizedBox(height: NeuSpace.s4),
                            TextField(
                              controller: portController,
                              keyboardType: TextInputType.number,
                              style: NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                              onChanged: (val) => setDialogState(() => portError = validatePort(val)),
                              decoration: InputDecoration(
                                hintText: 'e.g. 65432',
                                contentPadding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
                                errorText: portError,
                              ),
                            ),
                            const SizedBox(height: NeuSpace.s12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Twitch OAuth Token (Optional)', style: NeuType.label(themeNotifier.isDarkTheme)),
                                TextButton(
                                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                  onPressed: () => openExternalLink('https://twitchapps.com/tmi/'),
                                  child: const Text('Get Token Manually', style: NeuType.captionMetrics),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            TextField(
                              controller: tokenController,
                              obscureText: obscureToken,
                              style: NeuType.bodySm(themeNotifier.isDarkTheme),
                              decoration: InputDecoration(
                                hintText: 'oauth:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                                contentPadding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
                                suffixIcon: IconButton(
                                  icon: Icon(obscureToken ? Icons.visibility : Icons.visibility_off, size: 16),
                                  onPressed: () => setDialogState(() => obscureToken = !obscureToken),
                                  constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                            const SizedBox(height: NeuSpace.s12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Twitch Browser Token (Optional, for VOD Sync)', style: NeuType.label(themeNotifier.isDarkTheme)),
                                IconButton(
                                  icon: const Icon(Icons.help_outline, size: 16),
                                  color: themeNotifier.accentInk,
                                  padding: EdgeInsets.zero,
                                  // Same 32px target as the eye buttons two
                                  // lines away; a 16px glyph-sized target
                                  // beside 32px ones is a misclick machine.
                                  constraints: const BoxConstraints.tightFor(
                                      width: 32, height: 32),
                                  onPressed: () => _showBrowserTokenHelp(context, themeNotifier),
                                  tooltip: 'How to get Browser Token',
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: webTokenController,
                                    obscureText: obscureWebToken,
                                    style: NeuType.bodySm(themeNotifier.isDarkTheme),
                                    decoration: InputDecoration(
                                      hintText: 'e.g. 5vnv4iix6wz8y31ok3p7xlccuyb72s',
                                      contentPadding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
                                      suffixIcon: IconButton(
                                        icon: Icon(obscureWebToken ? Icons.visibility : Icons.visibility_off, size: 16),
                                        onPressed: () => setDialogState(() => obscureWebToken = !obscureWebToken),
                                        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                                        padding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: NeuSpace.s8),
                                SizedBox(
                                  height: 36,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isTestingToken ? NeuTheme.surface(themeNotifier.isDarkTheme) : themeNotifier.primaryColor,
                                      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r6)),
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
                                            child: NeuProgressRing(
                                                size: NeuProgressRingSize.xs,
                                                color: NeuTheme.onAccent(
                                                    themeNotifier.primaryColor),
                                                semanticLabel:
                                                    'Testing token'),
                                          )
                                        : Text('Test', style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.onAccent(themeNotifier.primaryColor))),
                                  ),
                                ),
                              ],
                            ),
                            if (tokenTestResult != null) ...[
                              const SizedBox(height: NeuSpace.s6),
                              Row(
                                children: [
                                  Icon(
                                    isTokenValid ? Icons.check_circle : Icons.error,
                                    size: 14,
                                    color: isTokenValid ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                  ),
                                  const SizedBox(width: NeuSpace.s6),
                                  Expanded(
                                    child: Text(
                                      tokenTestResult!,
                                      style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: isTokenValid ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),

                      // PANEL 5: System - window, tray, notifications, history, diagnostics
                      SingleChildScrollView(
                        // s4 lateral gave a raised control 4px before the
                        // pane's clip - its shadow ended in a hard line at
                        // the pane edge, worst on the material-picker tiles
                        // whose whole job is to demo the lit surface.
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s8, vertical: NeuSpace.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Window & Tray', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Close button', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                DropdownButton<String>(
                                  value: tempCloseAction,
                                  underline: const SizedBox.shrink(),
                                  style: NeuType.bodySm(themeNotifier.isDarkTheme),
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
                                Text('Minimize button', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                DropdownButton<String>(
                                  value: tempMinimizeAction,
                                  underline: const SizedBox.shrink(),
                                  style: NeuType.bodySm(themeNotifier.isDarkTheme),
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
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Launch at Windows startup', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                      Text('Starts minimized to the tray.', style: NeuType.caption(themeNotifier.isDarkTheme)),
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
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Start minimized to tray', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                NeuSwitch(
                                  value: tempStartMinimized,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempStartMinimized = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Live favorites in tray menu', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                      Text('Right-click the tray icon to launch a live favorite directly.', style: NeuType.caption(themeNotifier.isDarkTheme)),
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
                            const SizedBox(height: NeuSpace.s24),
                            EngravedRule(),
                            const SizedBox(height: NeuSpace.s12),
                            Text('Notifications', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Favorite channel goes live', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                NeuSwitch(
                                  value: tempNotifyWentLive,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyWentLive = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Auto-play starts a stream', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                NeuSwitch(
                                  value: tempNotifyAutoPlay,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyAutoPlay = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Auto-download starts', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                NeuSwitch(
                                  value: tempNotifyAutoDownloadStart,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyAutoDownloadStart = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // Not "Download completes": it governs the
                                // failure notification too, and none of these
                                // rows can wrap, so the label has to be both
                                // true and no longer than its siblings.
                                Text('Download completes or fails', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                NeuSwitch(
                                  value: tempNotifyDownloadComplete,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyDownloadComplete = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s24),
                            EngravedRule(),
                            const SizedBox(height: NeuSpace.s12),
                            Text('Watch History', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                side: BorderSide(color: NeuTheme.dangerText(themeNotifier.isDarkTheme), width: 1),
                                padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r6)),
                              ),
                              onPressed: () {
                                NeuDialog.show<void>(
                                  context,
                                  dismissible: true,
                                  builder: (context) => NeuDialog(
                                    title: 'Clear watch history?',
                                    icon: Icons.delete_forever,
                                    tone: DialogTone.destructive,
                                    content: Text(
                                      'Every VOD goes back to unwatched and loses its resume position. Downloaded files are untouched.',
                                      style: NeuType.body(themeNotifier.isDarkTheme),
                                    ),
                                    actions: [
                                      NeuDialogAction.secondary('Keep it', () => Navigator.pop(context)),
                                      NeuDialogAction.primary('Clear history', () {
                                        Navigator.pop(context);
                                        onClearWatchHistory();
                                      }),
                                    ],
                                  ),
                                );
                              },
                              icon: const Icon(Icons.delete_forever, size: 18),
                              label: const Text('Clear Local Watch History', style: NeuType.labelMetrics),
                            ),
                            const SizedBox(height: NeuSpace.s24),
                            EngravedRule(),
                            const SizedBox(height: NeuSpace.s12),
                            Text('Diagnostics', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s4),
                            Text(
                              'Output from downloads, streams and players. Useful when something fails.',
                              style: NeuType.caption(themeNotifier.isDarkTheme),
                            ),
                            const SizedBox(height: NeuSpace.s8),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: NeuTheme.text(themeNotifier.isDarkTheme),
                                side: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme), width: 1),
                                padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r6)),
                              ),
                              onPressed: onOpenLogs,
                              icon: const Icon(Icons.terminal, size: 18),
                              label: const Text('View Logs', style: NeuType.labelMetrics),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                    ),
                  ],
                ),
                // The version chip, repo link and update check act on the
                // app rather than on this dialog, so they sit at the far
                // left of the footer rather than beside Save.
                // Three separate Wrap children, not one Row wrapped in a
                // Flexible. The footer's leading group is a Wrap so it can
                // break onto a second line at the 380px minimum window, and a
                // Flexible in a Wrap is a ParentDataWidget with no Flex parent
                // - debug logs that and renders on, release throws and the
                // whole dialog body becomes a grey error box. See
                // NeuDialog.leadingActions.
                leadingActions: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4),
                    decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r6),
                    child: Text(
                      'v${UpdateService.currentVersion}',
                      style: NeuType.captionStrong(themeNotifier.isDarkTheme),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(NeuRadius.r6),
                    onTap: () => openExternalLink(UpdateService.githubRepoUrl),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.code, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                          const SizedBox(width: NeuSpace.s4),
                          Text(
                            'GitHub Repo',
                            style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                          ),
                        ],
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4)),
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
                        ? NeuProgressRing(
                            size: NeuProgressRingSize.xs,
                            color: NeuTheme.subtext(themeNotifier.isDarkTheme),
                            semanticLabel: 'Checking for updates',
                          )
                        : Icon(Icons.refresh, size: 13, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                    label: Text('Check for Updates', style: NeuType.caption(themeNotifier.isDarkTheme)),
                  ),
                  // Bounded rather than Flexible, for the reason above. 240 is
                  // wide enough for the longest message this can produce
                  // ("vX.Y.Z available - close Settings to install") on two
                  // lines, and narrow enough to leave the buttons a line of
                  // their own at 380.
                  if (updateCheckResult != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Text(
                        updateCheckResult!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NeuType.plate(themeNotifier.isDarkTheme, color: updateCheckIsError
                              ? NeuTheme.dangerText(themeNotifier.isDarkTheme)
                              : NeuTheme.liveText(themeNotifier.isDarkTheme)),
                      ),
                    ),
                ],
                actions: [
                  NeuDialogAction.secondary('Cancel', () {
                    restoreLiveThemeEdits();
                    Navigator.pop(context);
                  }),
                  // Null while a field is invalid: NeuDialogAction renders
                  // that disabled, which is what the old ternary did by
                  // hand on ElevatedButton.onPressed.
                  NeuDialogAction.primary(
                    'Save changes',
                    (portError != null || maxDownloadsError != null)
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
                                seekableVodStreaming: tempSeekableVodStreaming,
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
                                // Only written when the user actually changed
                                // it. `themeNotifier.material` is the RESOLVED
                                // value, and main.dart deliberately leaves it
                                // at the fallback for a key this build does not
                                // implement - so writing it unconditionally
                                // turns "open Settings, press Save" into
                                // "silently destroy the material a newer build
                                // chose". Every autosave path already got this
                                // right; this was the one that did not.
                                material: themeNotifier.material == originalMaterial
                                    ? settings.material
                                    : themeNotifier.material.key,
                              );

                              onSave(updated);
                              Navigator.pop(context);
                            },
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
    NeuDialog.show<void>(
      context,
      dismissible: true,
      builder: (context) {
        return NeuDialog(
          title: 'Getting your browser token',
          subtitle: 'Four steps, in your browser',
          icon: Icons.help_outline,
          width: 520,
          content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'To enable background watch progress syncing and VOD progress bars, you must copy your first-party browser login token from Twitch:',
                    style: NeuType.body(themeNotifier.isDarkTheme),
                  ),
                  const SizedBox(height: NeuSpace.s16),
                  _buildStep('1', 'Open your web browser, go to twitch.tv, and make sure you are logged in to your account.', themeNotifier),
                  const SizedBox(height: NeuSpace.s12),
                  _buildStep('2', 'Press F12 (or right-click anywhere on the page and select Inspect) to open the Developer Tools panel.', themeNotifier),
                  const SizedBox(height: NeuSpace.s12),
                  _buildStep('3', 'Locate your cookies:\n• Chrome/Edge: Go to the Application tab -> expand Cookies on the left -> select https://www.twitch.tv\n• Firefox: Go to the Storage tab -> expand Cookies -> select https://www.twitch.tv', themeNotifier),
                  const SizedBox(height: NeuSpace.s12),
                  _buildStep('4', 'In the cookies list, find the one named auth-token. Double-click its value, copy it, and paste it into the settings field.', themeNotifier),
                  const SizedBox(height: NeuSpace.s16),
                  EngravedRule(),
                  const SizedBox(height: NeuSpace.s8),
                  Row(
                    children: [
                      Icon(Icons.info, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                      const SizedBox(width: NeuSpace.s8),
                      Expanded(
                        child: Text(
                          'Note: Do NOT click "Log Out" on the Twitch website after copying this token. Clicking log out will immediately revoke the token on Twitch\'s servers.',
                          style: NeuType.caption(themeNotifier.isDarkTheme),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
          actions: [
            NeuDialogAction.primary('Got it', () => Navigator.pop(context)),
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
          decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r12),
          child: Text(
            number,
            style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.warningText(themeNotifier.isDarkTheme)),
          ),
        ),
        const SizedBox(width: NeuSpace.s12),
        Expanded(
          child: Text(
            text,
            style: NeuType.body(themeNotifier.isDarkTheme).copyWith(height: 1.35),
          ),
        ),
      ],
    );
  }
}

/// The material picker: one tile per implemented material, each rendered by
/// the shipping painter.
///
/// The preview is the real thing, not a swatch. Every tile paints with
/// `SkeuoDecoration` at that material's own palette, so a tile cannot show a
/// surface the app would not actually draw — which is the failure mode of a
/// hand-drawn preview, and the one that survives longest because it looks
/// fine right up until the material changes.
///
/// The previewed palette is taken at the **active brightness**, matching the
/// convention the theme-mode tiles below already use in reverse: those show
/// the other theme's own colours on purpose, and these show the current one,
/// because brightness is a separate axis the user is not choosing here.
///
/// Selection applies immediately rather than on Save. That is deliberate and
/// it is why Cancel restores the entry material: a material is a whole-app
/// change and judging it from a 120px tile is not possible. What is **not**
/// done is preview-on-hover by assigning `themeNotifier.material` and
/// restoring it — that fires `notifyListeners()` and rebuilds the entire app
/// on every pointer move across the row.
class _MaterialPicker extends StatelessWidget {
  const _MaterialPicker({
    required this.themeNotifier,
    required this.onChanged,
  });

  final ThemeUpdateListener themeNotifier;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    return Wrap(
      spacing: NeuSpace.s12,
      runSpacing: NeuSpace.s12,
      children: [
        for (final spec in MaterialSpec.available)
          _MaterialTile(
            spec: spec,
            isDark: isDark,
            selected: themeNotifier.material == spec.id,
            accent: themeNotifier.accentInk,
            onTap: () {
              themeNotifier.setMaterial(spec.id);
              onChanged();
            },
          ),
      ],
    );
  }
}

class _MaterialTile extends StatelessWidget {
  const _MaterialTile({
    required this.spec,
    required this.isDark,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final MaterialSpec spec;
  final bool isDark;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${spec.name}. ${spec.blurb}',
      child: Tooltip(
        message: spec.blurb,
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 168,
            child: Container(
              padding: const EdgeInsets.all(NeuSpace.s12),
              // The tile IS the material — `panel` with that material's own
              // palette, passed explicitly rather than read from the active
              // one. Reading the active material here is the bug that makes
              // every tile look identical and nobody notices until a second
              // material ships.
              decoration: NeuTheme.panel(
                isDark,
                radius: NeuRadius.r12,
                material: spec.id,
                border: selected
                    ? Border.all(color: accent, width: 2)
                    : Border.all(color: NeuTheme.border(isDark, material: spec.id)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A raised chip and a recessed well side by side: the two
                  // surfaces that carry almost every control in the app, and
                  // the pair that actually distinguishes one material from
                  // another. A flat swatch would show only the ground.
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 26,
                          decoration: NeuTheme.raised(isDark,
                              radius: NeuRadius.r8, material: spec.id),
                        ),
                      ),
                      const SizedBox(width: NeuSpace.s8),
                      Expanded(
                        child: Container(
                          height: 26,
                          decoration: NeuTheme.sunken(isDark,
                              radius: NeuRadius.r8, material: spec.id),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: NeuSpace.s8),
                  Text(
                    spec.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NeuType.label(
                      isDark,
                      color: NeuTheme.text(isDark, material: spec.id),
                    ),
                  ),
                  const SizedBox(height: NeuSpace.s2),
                  Text(
                    spec.blurb,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: NeuType.caption(
                      isDark,
                      color: NeuTheme.subtext(isDark, material: spec.id),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
