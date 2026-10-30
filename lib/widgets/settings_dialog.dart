import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models/app_settings.dart';
import '../services/file_dialogs.dart';
import '../services/player_service.dart';
import '../services/twitch_api_service.dart';
import '../services/update_service.dart';
import '../utils/color_utils.dart';
import '../theme/neu_material_themes.dart';
import '../state/twitch_auth_notifier.dart';
import '../theme/neu_theme.dart';
import '../utils/twitch_auth_status.dart';
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

  void setDarkTheme(bool isDark);
  void setLightAccent(Color color);
  void setDarkAccent(Color color);

  void updateTheme({
    Color? activeProgress,
    Color? watchedProgress,
  });
}

/// Whether an account-token Test probed the credentials the app is using.
///
/// The Test button validates whatever is TYPED, but `twitchAuth.helix`
/// describes the SAVED token and Client ID - the pair every Helix call sends.
/// Publishing a probe of anything else rewrote the app-wide verdict about a
/// token nothing was using. Testing a typo and pressing Cancel raised the
/// "rejected" banner over a working account. Testing a good token over a dead
/// saved one cleared the banner and fired the recovery refresh, with the dead
/// token, which failed again a minute later.
///
/// Trimmed on both sides because Save trims what it stores.
bool accountTestDescribesSavedToken(
  AppSettings saved, {
  required String token,
  required String clientId,
}) =>
    token.trim() == saved.twitchOauthToken.trim() &&
    clientId.trim() == saved.twitchClientId.trim();

/// Whether the custom player path names a file: checked off the UI thread,
/// and only once the typing stops.
///
/// This was `File(path).existsSync()`, called six times per rebuild, and the
/// dialog rebuilds on every keystroke and every slider tick. Free on a local
/// disk. For a player kept on a share (`\\nas\tools\mpv.exe`) that is slow or
/// offline, every one of those stats blocked the UI thread, and the dialog
/// froze for seconds per character typed.
class PlayerPathCheck {
  PlayerPathCheck({
    required String path,
    required bool exists,
    Future<bool> Function(String path)? probe,
    this.debounce = const Duration(milliseconds: 350),
  })  : _path = normalize(path),
        _exists = exists,
        _probe = probe ?? ((path) => File(path).exists());

  /// The launcher's own normalisation, so the verdict is about the file that
  /// would actually run. Explorer's "Copy as path" wraps a path in quotes;
  /// the launcher strips them and the old check did not, so a player that
  /// played fine was labelled "File not found".
  static String normalize(String raw) => raw.trim().replaceAll('"', '');

  final Duration debounce;
  final Future<bool> Function(String path) _probe;
  String _path;
  bool? _exists;
  Timer? _pending;
  bool _disposed = false;

  /// The normalised path the verdict is about. Empty when none is set.
  String get path => _path;

  /// Whether [path] names a file; null while an edit waits to be checked.
  bool? get exists => _path.isEmpty ? false : _exists;

  /// Records the field's text.
  ///
  /// Free when the path has not changed, so it is safe on every keystroke.
  /// [onSettled] runs once the latest edit's verdict lands, and never for an
  /// edit a later one has replaced.
  void update(String rawPath, VoidCallback onSettled) {
    final next = normalize(rawPath);
    if (next == _path) return;
    _path = next;
    _exists = null;
    _pending?.cancel();
    if (next.isEmpty) return;
    _pending = Timer(debounce, () async {
      bool found;
      try {
        found = await _probe(next);
      } catch (_) {
        found = false;
      }
      // Replaced by a later edit while the stat ran, or the dialog is gone.
      if (_disposed || next != _path) return;
      _exists = found;
      onSettled();
    });
  }

  void dispose() {
    _disposed = true;
    _pending?.cancel();
  }
}

class SettingsDialog {
  static Future<void> show(
    BuildContext context, {
    required AppSettings settings,
    required ThemeUpdateListener themeNotifier,
    required String? authenticatedUserLogin,

    /// Re-probes the account token. Called once when the dialog opens, so the
    /// status row shows what Twitch says NOW rather than what it said at
    /// launch - the row used to be a string-emptiness check that could never
    /// go stale because it never consulted anything.
    required Future<void> Function() onRevalidateHelix,
    required VoidCallback onConnectAccount,

    /// Persists the staged settings. Save does not wait for it. Connect
    /// Account does: the OAuth flow reads the settings the app holds, so it
    /// must not start until the typed Client ID and port are the ones held.
    required FutureOr<void> Function(AppSettings) onSave,
    required void Function(String) openExternalLink,
    required VoidCallback onClearWatchHistory,
    required VoidCallback onOpenLogs,
    /// Invoked when the in-dialog update check finds a newer release, so the
    /// app can offer to install it. Without this the dialog told the user to
    /// "check the main window prompt", which only ever appears at startup.
    void Function(UpdateInfo)? onUpdateAvailable,

    /// What the two token Test buttons validate through. A fresh service when
    /// omitted, which is what the app does; tests pass a fake so a validation
    /// can be held open while the dialog closes underneath it.
    TwitchApiService? apiService,
  }) {
    final api = apiService ?? TwitchApiService();
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
    // The account token the field opened with. A Connect Account that
    // finishes while the dialog is open writes its token into `settings`
    // itself, and the untouched field still holds the old one: staging the
    // field put that back on Save - and, no longer matching, blanked the
    // Client ID that minted the new one and signed the account out.
    final openedToken = settings.twitchOauthToken.trim();
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
    bool tempNotifyNewVod = settings.notifyNewVod;
    bool tempNotifyFollowedWentLive = settings.notifyFollowedWentLive;

    // One probe per dialog open. This used to run 8x on EVERY rebuild (each
    // probe shells out / stats the filesystem for four players).
    final detectedPlayers = PlayerService().detectInstalledPlayers(settings);
    // The custom-path entry is the exception: it must react to what the user
    // is typing, not to the last saved settings. Seeded from the probe above,
    // which already stat'ed the saved path, so opening costs no second stat.
    final playerPathCheck = PlayerPathCheck(
      path: settings.customPlayerPath,
      exists: detectedPlayers['custom'] == true,
    );

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
    // Two tokens, two result slots. They were never separate before, which is
    // how a passing BROWSER token test came to read as "everything is
    // connected" while the ACCOUNT token was dead.
    bool isTestingToken = false;
    String? tokenTestResult;
    bool isTokenValid = false;
    bool isTestingAccount = false;
    String? accountTestResult;
    bool isAccountValid = false;
    // A file dialog is open for that field. It no longer blocks the app
    // (file_picker 13), so each Browse stayed pressable and opened another
    // dialog per click, the last to answer overwriting the field.
    bool isPickingPlayer = false;
    bool isPickingFolder = false;

    // Opening Settings is itself the check.
    WidgetsBinding.instance.addPostFrameCallback((_) => onRevalidateHelix());

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

    // Save and Connect Account both persist exactly this, so it is built in
    // one place. Connect used to leave without saving at all.
    bool stagedIsValid() => portError == null && maxDownloadsError == null;

    AppSettings stagedSettings() {
      // copyWith, not a fresh AppSettings: constructing a new
      // instance from only the fields this dialog knows about
      // silently reset every other persisted field to its
      // default, so saving wiped the theme mode, window
      // geometry, the VOD watch exclusion threshold and the
      // auto-play preemption toggle.
      //
      // An account token the user did not edit is the one in force now,
      // whatever the field still says (see openedToken).
      final typedToken = tokenController.text.trim();
      final token =
          typedToken == openedToken ? settings.twitchOauthToken : typedToken;
      return settings.copyWith(
        defaultQuality: tempQuality,
        twitchLowLatency: tempLowLatency,
        playerType: tempPlayerType,
        watchedThreshold: tempWatchedThreshold,
        twitchOauthToken: token,
        twitchTokenClientId: token == settings.twitchOauthToken
            ? settings.twitchTokenClientId
            : '',
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
        notifyNewVod: tempNotifyNewVod,
        notifyFollowedWentLive: tempNotifyFollowedWentLive,
        disableVodPostProcessing: tempDisableVodPostProcessing,
        customVodArgs: customVodArgsController.text.trim(),
        // The Styling tab edits these on the notifier directly;
        // persist what it currently holds so the choice survives
        // a restart instead of reverting to Dark + default accent.
        isDarkTheme: themeNotifier.isDarkTheme,
        lightAccentColorHex: colorToHex(themeNotifier.lightAccentColor),
        darkAccentColorHex: colorToHex(themeNotifier.darkAccentColor),
      );
    }

    // What the dialog stages before anything is touched. "Were there edits"
    // compares against this, not against `settings`: the two disagree with no
    // edit at all, because the stored default accent is '#FF6584' and
    // colorToHex writes '#FFFF6584', so every unsaved install would compare as
    // changed.
    final uneditedJson = jsonEncode(stagedSettings().toJson());
    bool hasStagedEdits() => jsonEncode(stagedSettings().toJson()) != uneditedJson;

    // Not dismissible: the dialog stages every edit and applies theme changes
    // live, so a click on the scrim would discard typed tokens and paths while
    // leaving the accent it had already previewed.
    void disposeControllers() {
      tokenController.dispose();
      webTokenController.dispose();
      playerPathController.dispose();
      playerArgsController.dispose();
      clientIdController.dispose();
      portController.dispose();
      downloadFolderController.dispose();
      maxDownloadsController.dispose();
      customVodArgsController.dispose();
      playerPathCheck.dispose();
    }

    return NeuDialog.show<void>(
      context,
      dismissible: false,
      builder: (context) {
        final dialog = StatefulBuilder(
          builder: (context, setDialogState) {
            // Null while an edit to the custom path waits to be checked.
            final playerPathFound = playerPathCheck.exists;
            final playerPathInk = playerPathFound == null
                ? NeuTheme.subtext(themeNotifier.isDarkTheme)
                : (playerPathFound
                    ? NeuTheme.liveText(themeNotifier.isDarkTheme)
                    : NeuTheme.dangerText(themeNotifier.isDarkTheme));
            void recheckPlayerPath() => playerPathCheck.update(
                  playerPathController.text,
                  () {
                    if (context.mounted) setDialogState(() {});
                  },
                );
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
                        // The shared clearance: the first hand-tuned fix
                        // (s8/s12) covered Rack and cut Soft's diagonal
                        // glow, worst on the material-picker tiles whose
                        // whole job is to demo the surface.
                        padding: const EdgeInsets.fromLTRB(
                            NeuShadowRoom.side,
                            NeuShadowRoom.above,
                            NeuShadowRoom.side,
                            NeuShadowRoom.below),
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
                              // Expanded, so the field bounds its items and a
                              // narrow window ellipsizes them. Unexpanded, the
                              // widest item sets the width and overflows the
                              // field instead. The arrow is the decoration's
                              // suffix either way, so nothing moves.
                              isExpanded: true,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                              ),
                              items: [
                                for (final (value, label) in const [
                                  ('best', 'Best Available'),
                                  ('1080p60', '1080p60 (Source)'),
                                  ('1080p', '1080p'),
                                  ('720p60', '720p60'),
                                  ('720p', '720p'),
                                  ('480p', '480p'),
                                  ('360p', '360p'),
                                  ('worst', 'Worst Available'),
                                ])
                                  DropdownMenuItem(
                                    value: value,
                                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ),
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
                            // Label-and-control rows keep the label in an
                            // Expanded, so a narrow window wraps the words
                            // instead of pushing the control past the edge,
                            // where it was clipped and could not be reached.
                            // This one overflowed at the 380px minimum window.
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
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
                                ),
                                const SizedBox(width: NeuSpace.s8),
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
                              // Expanded for the quality field's reason. Each
                              // name is Flexible so the status plate keeps its
                              // room and the name ellipsizes; the plate is the
                              // part that answers the question.
                              isExpanded: true,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 'default',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Flexible(child: Text('Default System Player', maxLines: 1, overflow: TextOverflow.ellipsis)),
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
                                      Flexible(child: Text('VLC Media Player', maxLines: 1, overflow: TextOverflow.ellipsis)),
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
                                      Flexible(child: Text('MPV Player', maxLines: 1, overflow: TextOverflow.ellipsis)),
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
                                      Flexible(child: Text('MPC-HC Player', maxLines: 1, overflow: TextOverflow.ellipsis)),
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
                                      Flexible(child: Text('Custom Executable Path', maxLines: 1, overflow: TextOverflow.ellipsis)),
                                      if (playerPathCheck.path.isNotEmpty && playerPathFound != null) ...[
                                        const SizedBox(width: NeuSpace.s8),
                                        Text(
                                          playerPathFound ? '(Valid Path)' : '(File Missing)',
                                          style: NeuType.plate(themeNotifier.isDarkTheme, color: playerPathInk),
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
                                      onChanged: (_) => setDialogState(recheckPlayerPath),
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
                                    onPressed: isPickingPlayer ? null : () async {
                                      final route = ModalRoute.of(context);
                                      setDialogState(() => isPickingPlayer = true);
                                      // pickFile, not pickFiles: since
                                      // file_picker 12, pickFiles allows a
                                      // multi-pick by default, and one
                                      // player is wanted here.
                                      final PlatformFile? picked = await FileDialogs.pickFile(
                                        type: FileType.custom,
                                        allowedExtensions: ['exe', 'app', 'sh', 'bat', 'cmd'],
                                      ).whenComplete(() {
                                        if (context.mounted) setDialogState(() => isPickingPlayer = false);
                                      });
                                      // The same guard as the token tests:
                                      // nothing here may touch the dialog,
                                      // or its disposed controllers, once it
                                      // has closed - nor fill in a field of
                                      // one that Cancel or Save already
                                      // closed and is only animating out.
                                      if (!context.mounted || route?.isActive == false) return;
                                      final pickedPath = picked?.path;
                                      if (pickedPath != null) {
                                        setDialogState(() {
                                          playerPathController.text = pickedPath;
                                          // Assigning .text fires no onChanged.
                                          recheckPlayerPath();
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
                              if (playerPathCheck.path.isNotEmpty) ...[
                                const SizedBox(height: NeuSpace.s6),
                                Row(
                                  children: [
                                    Icon(
                                      playerPathFound == null
                                          ? Icons.hourglass_empty
                                          : (playerPathFound ? Icons.check_circle : Icons.error_outline),
                                      size: 13,
                                      color: playerPathInk,
                                    ),
                                    const SizedBox(width: NeuSpace.s6),
                                    Expanded(
                                      child: Text(
                                        playerPathFound == null
                                            ? 'Checking path...'
                                            : (playerPathFound ? 'Executable found' : 'File not found at this path'),
                                        style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: playerPathInk),
                                      ),
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
                        // The shared clearance: the first hand-tuned fix
                        // (s8/s12) covered Rack and cut Soft's diagonal
                        // glow, worst on the material-picker tiles whose
                        // whole job is to demo the surface.
                        padding: const EdgeInsets.fromLTRB(
                            NeuShadowRoom.side,
                            NeuShadowRoom.above,
                            NeuShadowRoom.side,
                            NeuShadowRoom.below),
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
                                  onPressed: isPickingFolder ? null : () async {
                                    final route = ModalRoute.of(context);
                                    setDialogState(() => isPickingFolder = true);
                                    final String? selectedDirectory =
                                        await FileDialogs.pickFolder().whenComplete(() {
                                      if (context.mounted) setDialogState(() => isPickingFolder = false);
                                    });
                                    // As the player Browse above: not into
                                    // a dialog that has closed or is closing.
                                    if (!context.mounted || route?.isActive == false) return;
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
                        // The shared clearance: the first hand-tuned fix
                        // (s8/s12) covered Rack and cut Soft's diagonal
                        // glow, worst on the material-picker tiles whose
                        // whole job is to demo the surface.
                        padding: const EdgeInsets.fromLTRB(
                            NeuShadowRoom.side,
                            NeuShadowRoom.above,
                            NeuShadowRoom.side,
                            NeuShadowRoom.below),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                        // The shared clearance: the first hand-tuned fix
                        // (s8/s12) covered Rack and cut Soft's diagonal
                        // glow, worst on the material-picker tiles whose
                        // whole job is to demo the surface.
                        padding: const EdgeInsets.fromLTRB(
                            NeuShadowRoom.side,
                            NeuShadowRoom.above,
                            NeuShadowRoom.side,
                            NeuShadowRoom.below),
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
                                  // A Wrap, not a Row: in a narrow window the button
                                  // drops under the status instead of squeezing it to
                                  // nothing. On one line, spaceBetween keeps the old
                                  // status-left, button-right arrangement.
                                  Wrap(
                                    alignment: WrapAlignment.spaceBetween,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    spacing: NeuSpace.s8,
                                    runSpacing: NeuSpace.s8,
                                    children: [
                                      // The indicator used to be
                                      // `twitchOauthToken.isNotEmpty`, which
                                      // reports that a STRING exists - a test
                                      // a revoked token passes forever. It now
                                      // shows what Twitch last said about the
                                      // ACCOUNT token, and says which token
                                      // that is.
                                      ValueListenableBuilder<TwitchAuthStatus>(
                                        valueListenable: twitchAuth.helix,
                                        builder: (context, status, _) {
                                          final ok = status.isUsable;
                                          final bad = status.needsReconnect;
                                          final ink = ok
                                              ? NeuTheme.liveText(themeNotifier.isDarkTheme)
                                              : (bad
                                                  ? NeuTheme.dangerText(themeNotifier.isDarkTheme)
                                                  : NeuTheme.warningText(themeNotifier.isDarkTheme));
                                          return Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                ok
                                                    ? Icons.check_circle
                                                    : (bad ? Icons.link_off : Icons.help_outline),
                                                color: ink,
                                                size: 16,
                                              ),
                                              const SizedBox(width: NeuSpace.s8),
                                              Flexible(
                                                child: Text(
                                                  connectionLabel(status),
                                                  overflow: TextOverflow.ellipsis,
                                                  style: NeuType.label(themeNotifier.isDarkTheme, color: ink),
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: themeNotifier.primaryColor,
                                          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        // Disabled whenever Save is: an invalid
                                        // port cannot be saved, and the sign-in
                                        // flow listens on it.
                                        onPressed: !stagedIsValid()
                                            ? null
                                            : () async {
                                                // Connect is Save, then sign in.
                                                // It used to leave without
                                                // saving, so a Client ID or port
                                                // typed a few lines below was
                                                // ignored: the flow bound the
                                                // OLD port for the OLD client,
                                                // Twitch rejected the redirect,
                                                // and every other staged edit
                                                // was lost without a word.
                                                // Saving also settles the live
                                                // Appearance edits, which this
                                                // exit used to restore - every
                                                // exit still saves or restores.
                                                //
                                                // Built before the pop, which
                                                // disposes the controllers it
                                                // reads. Skipped when nothing is
                                                // staged, so a plain Connect
                                                // does not rewrite the config.
                                                final staged = stagedSettings();
                                                final changed = hasStagedEdits();
                                                Navigator.pop(context);
                                                if (changed) await onSave(staged);
                                                onConnectAccount();
                                              },
                                        icon: Icon(Icons.login, size: 12,
                                            color: stagedIsValid()
                                                ? NeuTheme.onAccent(themeNotifier.primaryColor)
                                                : NeuTheme.disabledText(themeNotifier.isDarkTheme)),
                                        label: Text('Connect Account', style: NeuType.captionStrong(themeNotifier.isDarkTheme,
                                            color: stagedIsValid()
                                                ? NeuTheme.onAccent(themeNotifier.primaryColor)
                                                : NeuTheme.disabledText(themeNotifier.isDarkTheme))),
                                      ),
                                    ],
                                  ),
                                  ValueListenableBuilder<TwitchAuthStatus>(
                                    valueListenable: twitchAuth.helix,
                                    builder: (context, status, _) {
                                      final detail = connectionDetail(status);
                                      if (detail != null) {
                                        return Padding(
                                          padding: const EdgeInsets.only(top: NeuSpace.s8),
                                          child: Text(
                                            detail,
                                            style: NeuType.caption(themeNotifier.isDarkTheme,
                                                color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                                          ),
                                        );
                                      }
                                      if (settings.twitchOauthToken.trim().isEmpty) {
                                        return const SizedBox.shrink();
                                      }
                                      return Padding(
                                        padding: const EdgeInsets.only(top: NeuSpace.s8),
                                        child: Text(
                                          'Connecting allows you to automatically load your followed channels, view channel VOD lists, stream subscriber-only feeds, and remove ads.',
                                          style: NeuType.caption(themeNotifier.isDarkTheme),
                                        ),
                                      );
                                    },
                                  ),
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
                              children: [
                                // The longest label in the dialog: below about
                                // 555px it pushed "Get Token Manually" out of
                                // reach.
                                Expanded(
                                  child: Text('Account token \u2014 followed channels, VOD lists, ad-free', style: NeuType.label(themeNotifier.isDarkTheme)),
                                ),
                                const SizedBox(width: NeuSpace.s8),
                                TextButton(
                                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                  onPressed: () => openExternalLink('https://twitchapps.com/tmi/'),
                                  child: const Text('Get Token Manually', style: NeuType.captionMetrics),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextField(
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
                                ),
                                const SizedBox(width: NeuSpace.s8),
                                SizedBox(
                                  height: 36,
                                  child: ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: isTestingAccount ? NeuTheme.surface(themeNotifier.isDarkTheme) : themeNotifier.primaryColor,
                                      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(NeuRadius.r6)),
                                    ),
                                    // Tests the TYPED token against the TYPED
                                    // Client ID - the pairing every Helix call
                                    // actually sends, and the pairing that was
                                    // failing while each field looked fine on
                                    // its own.
                                    onPressed: isTestingAccount
                                        ? null
                                        : () async {
                                            // Taken before the await: the
                                            // fields stay editable during the
                                            // round trip, and what matters
                                            // below is what was TESTED.
                                            final testedToken = tokenController.text;
                                            final testedClientId = clientIdController.text;
                                            final route = ModalRoute.of(context);
                                            setDialogState(() {
                                              isTestingAccount = true;
                                              accountTestResult = null;
                                            });
                                            final status = await api.validateHelixToken(
                                                testedToken, testedClientId);
                                            // Cancel, Save and Connect all stay
                                            // live while this runs. Returning
                                            // once any of them has popped also
                                            // skips publishing: after a Save,
                                            // `settings` is no longer what the
                                            // app is using. `mounted` alone is
                                            // not that test - the builder
                                            // outlives the pop by the whole
                                            // exit animation - but the route
                                            // stops being active at the pop.
                                            if (!context.mounted || route?.isActive == false) return;
                                            final testedIsSaved = accountTestDescribesSavedToken(
                                                settings,
                                                token: testedToken,
                                                clientId: testedClientId);
                                            setDialogState(() {
                                              isTestingAccount = false;
                                              isAccountValid = status.isUsable;
                                              accountTestResult = status.isUsable
                                                  ? 'Account token OK \u2014 signed in as ${status.login}, follows permission granted'
                                                      '${testedIsSaved ? '' : '. Save to start using it.'}'
                                                  : (connectionDetail(status) ?? connectionLabel(status));
                                            });
                                            if (testedIsSaved) {
                                              twitchAuth.recordHelixProbe(status,
                                                  credential: TwitchApiService.helixCredential(
                                                      testedToken, testedClientId));
                                            }
                                          },
                                    child: isTestingAccount
                                        ? SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: NeuProgressRing(
                                                size: NeuProgressRingSize.xs,
                                                color: NeuTheme.onAccent(themeNotifier.primaryColor),
                                                semanticLabel: 'Testing account token'),
                                          )
                                        : Text('Test', style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.onAccent(themeNotifier.primaryColor))),
                                  ),
                                ),
                              ],
                            ),
                            if (accountTestResult != null) ...[
                              const SizedBox(height: NeuSpace.s6),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    isAccountValid ? Icons.check_circle : Icons.error,
                                    size: 14,
                                    color: isAccountValid ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme),
                                  ),
                                  const SizedBox(width: NeuSpace.s6),
                                  Expanded(
                                    child: Text(
                                      accountTestResult!,
                                      style: NeuType.caption(themeNotifier.isDarkTheme,
                                          color: isAccountValid ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: NeuSpace.s12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text('Browser token \u2014 watch-progress sync only', style: NeuType.label(themeNotifier.isDarkTheme)),
                                ),
                                const SizedBox(width: NeuSpace.s8),
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
                                            final result = await api
                                                .validateOAuthToken(webTokenController.text);
                                            if (!context.mounted) return;
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
                        // The shared clearance: the first hand-tuned fix
                        // (s8/s12) covered Rack and cut Soft's diagonal
                        // glow, worst on the material-picker tiles whose
                        // whole job is to demo the surface.
                        padding: const EdgeInsets.fromLTRB(
                            NeuShadowRoom.side,
                            NeuShadowRoom.above,
                            NeuShadowRoom.side,
                            NeuShadowRoom.below),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Window & Tray', style: NeuType.headingSm(themeNotifier.isDarkTheme)),
                            const SizedBox(height: NeuSpace.s8),
                            // A Wrap and an intrinsically sized dropdown, not
                            // the Expanded label the switch rows use. A
                            // dropdown is as wide as its longest choice, so
                            // beside an Expanded label it still overflows once
                            // that choice outgrows the row. Here it keeps its
                            // natural width while there is room, drops to its
                            // own line when there is not, and ellipsizes only
                            // when a whole line is too short for it.
                            Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: NeuSpace.s8,
                              children: [
                                Text('Close button', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                IntrinsicWidth(
                                  child: DropdownButton<String>(
                                    value: tempCloseAction,
                                    isExpanded: true,
                                    underline: const SizedBox.shrink(),
                                    style: NeuType.bodySm(themeNotifier.isDarkTheme),
                                    dropdownColor: themeNotifier.surfaceColor,
                                    items: [
                                      for (final (value, label) in const [
                                        ('tray', 'Minimize to tray'),
                                        ('exit', 'Exit the app'),
                                      ])
                                        DropdownMenuItem(
                                          value: value,
                                          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        ),
                                    ],
                                    onChanged: (val) {
                                      if (val != null) setDialogState(() => tempCloseAction = val);
                                    },
                                  ),
                                ),
                              ],
                            ),
                            Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: NeuSpace.s8,
                              children: [
                                Text('Minimize button', style: NeuType.bodySm(themeNotifier.isDarkTheme)),
                                IntrinsicWidth(
                                  child: DropdownButton<String>(
                                    value: tempMinimizeAction,
                                    isExpanded: true,
                                    underline: const SizedBox.shrink(),
                                    style: NeuType.bodySm(themeNotifier.isDarkTheme),
                                    dropdownColor: themeNotifier.surfaceColor,
                                    items: [
                                      for (final (value, label) in const [
                                        ('taskbar', 'Minimize to taskbar'),
                                        ('tray', 'Minimize to tray'),
                                      ])
                                        DropdownMenuItem(
                                          value: value,
                                          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                        ),
                                    ],
                                    onChanged: (val) {
                                      if (val != null) setDialogState(() => tempMinimizeAction = val);
                                    },
                                  ),
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
                              children: [
                                Expanded(child: Text('Start minimized to tray', style: NeuType.bodySm(themeNotifier.isDarkTheme))),
                                const SizedBox(width: NeuSpace.s8),
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
                              children: [
                                Expanded(child: Text('Favorite channel goes live', style: NeuType.bodySm(themeNotifier.isDarkTheme))),
                                const SizedBox(width: NeuSpace.s8),
                                NeuSwitch(
                                  value: tempNotifyWentLive,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyWentLive = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              children: [
                                Expanded(child: Text('Favorite channel has a new VOD', style: NeuType.bodySm(themeNotifier.isDarkTheme))),
                                const SizedBox(width: NeuSpace.s8),
                                NeuSwitch(
                                  value: tempNotifyNewVod,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyNewVod = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              children: [
                                // Off by default: with a large followed list
                                // this is a toast every few minutes.
                                Expanded(child: Text('Followed channel goes live', style: NeuType.bodySm(themeNotifier.isDarkTheme))),
                                const SizedBox(width: NeuSpace.s8),
                                NeuSwitch(
                                  value: tempNotifyFollowedWentLive,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyFollowedWentLive = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              children: [
                                Expanded(child: Text('Auto-play starts a stream', style: NeuType.bodySm(themeNotifier.isDarkTheme))),
                                const SizedBox(width: NeuSpace.s8),
                                NeuSwitch(
                                  value: tempNotifyAutoPlay,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyAutoPlay = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              children: [
                                Expanded(child: Text('Auto-download starts', style: NeuType.bodySm(themeNotifier.isDarkTheme))),
                                const SizedBox(width: NeuSpace.s8),
                                NeuSwitch(
                                  value: tempNotifyAutoDownloadStart,
                                  activeColor: themeNotifier.primaryColor,
                                  onChanged: (val) => setDialogState(() => tempNotifyAutoDownloadStart = val),
                                ),
                              ],
                            ),
                            const SizedBox(height: NeuSpace.s6),
                            Row(
                              children: [
                                // Not "Download completes": it governs the
                                // failure notification too. These rows wrap
                                // now rather than overflow, but a label that
                                // breaks where its siblings do not still
                                // reads as the odd one out, so it stays short.
                                Expanded(child: Text('Download completes or fails', style: NeuType.bodySm(themeNotifier.isDarkTheme))),
                                const SizedBox(width: NeuSpace.s8),
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
                            const SizedBox(height: NeuSpace.s8),
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
                    !stagedIsValid()
                        ? null
                        : () {
                              onSave(stagedSettings());
                              Navigator.pop(context);
                            },
                  ),
                ],
              ),
            );
          },
        );
        // The controllers go when the dialog's widgets do, not when its
        // future completes. The future completes at the pop, but the route
        // stays on screen through its exit animation, and the focus change
        // at the pop rebuilds whichever field held the caret - which then
        // re-subscribed to a controller already disposed, and asserted on
        // every Save or Cancel made straight after typing.
        return _DisposeWhenUnmounted(onDispose: disposeControllers, child: dialog);
      },
    );
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

/// Runs [onDispose] once, when it leaves the tree for good.
///
/// Children are unmounted before their parent, so by the time this runs every
/// field below it has already let go of its controller.
class _DisposeWhenUnmounted extends StatefulWidget {
  const _DisposeWhenUnmounted({required this.onDispose, required this.child});

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<_DisposeWhenUnmounted> createState() => _DisposeWhenUnmountedState();
}

class _DisposeWhenUnmountedState extends State<_DisposeWhenUnmounted> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
