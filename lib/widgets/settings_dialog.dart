import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../models/app_settings.dart';
import '../services/player_service.dart';
import '../services/update_service.dart';
import '../utils/color_utils.dart';
import 'horizontal_mouse_scrollable.dart';

// Abstract theme notifier interface to break dependencies
abstract class ThemeUpdateListener extends ChangeNotifier {
  Color get primaryColor;
  Color get backgroundColor;
  Color get surfaceColor;
  Color get activeProgressColor;
  Color get watchedProgressColor;

  void updateTheme({
    Color? primary,
    Color? background,
    Color? surface,
    Color? activeProgress,
    Color? watchedProgress,
  });
}

class SettingsDialog {
  static void show(
    BuildContext context, {
    required AppSettings settings,
    required ThemeUpdateListener themeNotifier,
    required String? authenticatedUserLogin,
    required VoidCallback onConnectAccount,
    required void Function(AppSettings) onSave,
    required void Function(String) openExternalLink,
    required VoidCallback onClearWatchHistory,
  }) {
    String tempQuality = settings.defaultQuality;
    bool tempLowLatency = settings.twitchLowLatency;
    String tempPlayerType = settings.playerType;
    int tempWatchedThreshold = settings.watchedThreshold;
    int tempMaxRecentlyWatched = settings.maxRecentlyWatched;
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
    bool obscureToken = true;
    bool obscureWebToken = true;
    bool isTestingToken = false;
    String? tokenTestResult;
    bool isTokenValid = false;

    // Capture original theme colors to support Cancel/Rollback
    final origPrimary = parseHexColor(settings.primaryColorHex, const Color(0xFF9146FF));
    final origBackground = parseHexColor(settings.backgroundColorHex, const Color(0xFF0C0F17));
    final origSurface = parseHexColor(settings.surfaceColorHex, const Color(0xFF161B26));
    final origActiveProgress = parseHexColor(settings.activeProgressColorHex, const Color(0xFF9146FF));
    final origWatchedProgress = parseHexColor(settings.watchedProgressColorHex, const Color(0x804CAF50));

    Color tempPrimary = origPrimary;
    Color tempBackground = origBackground;
    Color tempSurface = origSurface;
    Color tempActiveProgress = origActiveProgress;
    Color tempWatchedProgress = origWatchedProgress;

    String activeColorKey = 'primary';
    final hexController = TextEditingController(text: colorToHex(tempPrimary));

    showDialog(
      context: context,
      barrierDismissible: false, // Force user to click save/cancel to ensure proper color rollback
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Color getActiveColor() {
              switch (activeColorKey) {
                case 'primary': return tempPrimary;
                case 'background': return tempBackground;
                case 'surface': return tempSurface;
                case 'activeProgress': return tempActiveProgress;
                case 'watchedProgress': return tempWatchedProgress;
                default: return tempPrimary;
              }
            }

            void updateActiveColor(Color c) {
              setDialogState(() {
                switch (activeColorKey) {
                  case 'primary': tempPrimary = c; break;
                  case 'background': tempBackground = c; break;
                  case 'surface': tempSurface = c; break;
                  case 'activeProgress': tempActiveProgress = c; break;
                  case 'watchedProgress': tempWatchedProgress = c; break;
                }
                final activeColor = getActiveColor();
                final hexStr = colorToHex(activeColor);
                if (hexController.text.toUpperCase() != hexStr.toUpperCase()) {
                  hexController.text = hexStr;
                }
              });
              themeNotifier.updateTheme(
                primary: tempPrimary,
                background: tempBackground,
                surface: tempSurface,
                activeProgress: tempActiveProgress,
                watchedProgress: tempWatchedProgress,
              );
            }

            Widget buildPresetCard({
              required String name,
              required Color primary,
              required Color bg,
              required Color surface,
              required Color activeProg,
              required Color watchedProg,
            }) {
              final isSelected = tempPrimary.value == primary.value &&
                  tempBackground.value == bg.value &&
                  tempSurface.value == surface.value;
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                  setDialogState(() {
                    tempPrimary = primary;
                    tempBackground = bg;
                    tempSurface = surface;
                    tempActiveProgress = activeProg;
                    tempWatchedProgress = watchedProg;
                    hexController.text = colorToHex(getActiveColor());
                  });
                  themeNotifier.updateTheme(
                    primary: tempPrimary,
                    background: tempBackground,
                    surface: tempSurface,
                    activeProgress: tempActiveProgress,
                    watchedProgress: tempWatchedProgress,
                  );
                },
                child: Container(
                  width: 110,
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected ? primary : Colors.white10,
                      width: isSelected ? 2 : 1,
                    ),
                    boxShadow: [
                      if (isSelected)
                        BoxShadow(
                          color: primary.withOpacity(0.3),
                          blurRadius: 6,
                        ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isSelected ? Colors.white : Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(width: 12, height: 12, decoration: BoxDecoration(color: primary, shape: BoxShape.circle)),
                          const SizedBox(width: 4),
                          Container(width: 12, height: 12, decoration: BoxDecoration(color: bg, shape: BoxShape.circle)),
                          const SizedBox(width: 4),
                          Container(width: 12, height: 12, decoration: BoxDecoration(color: surface, shape: BoxShape.circle)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
            }

            Widget buildColorSlider({
              required String label,
              required double value,
              required Color sliderColor,
              required ValueChanged<double> onChanged,
            }) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70)),
                        Text(value.round().toString(), style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: Colors.white70)),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        activeTrackColor: sliderColor,
                        inactiveTrackColor: Colors.white10,
                        thumbColor: sliderColor,
                      ),
                      child: Slider(
                        value: value,
                        min: 0,
                        max: 255,
                        onChanged: onChanged,
                      ),
                    ),
                  ],
                ),
              );
            }

            final presets = [
              const Color(0xFF9146FF), // Twitch Purple
              const Color(0xFF00F2FE), // Cyan Accent
              const Color(0xFF4CAF50), // Green
              const Color(0xFFF44336), // Red
              const Color(0xFFFF9800), // Orange
              const Color(0xFFFFEB3B), // Yellow
              const Color(0xFFE91E63), // Pink
              const Color(0xFF2196F3), // Blue
              const Color(0xFF0C0F17), // Dark Background
              const Color(0xFF161B26), // Dark Card
            ];

            final activeColor = getActiveColor();

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
                          const Text('Streamlink Settings'),
                        ],
                      ),
                    ),
                    TabBar(
                      labelColor: themeNotifier.primaryColor,
                      unselectedLabelColor: Colors.white60,
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
                  side: BorderSide(color: themeNotifier.primaryColor.withOpacity(0.3), width: 1.5),
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
                            const Text(
                              'Default Video Quality',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: tempQuality,
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
                                    const Text('Low Latency Streams', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Reduces delay on Twitch streams',
                                      style: TextStyle(fontSize: 11, color: Colors.white38),
                                    ),
                                  ],
                                ),
                                Switch(
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
                            const Text('VOD Watched Threshold', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Mark VOD as fully watched at $tempWatchedThreshold% completion.', style: const TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Text('50%', style: TextStyle(fontSize: 11, color: Colors.white38)),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                      activeTrackColor: themeNotifier.primaryColor,
                                      inactiveTrackColor: Colors.white10,
                                      thumbColor: themeNotifier.primaryColor,
                                    ),
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
                                const Text('100%', style: TextStyle(fontSize: 11, color: Colors.white38)),
                              ],
                            ),
                            const SizedBox(height: 18),
                            const Text('Recently Watched VODs Limit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Limit dashboard watch history to $tempMaxRecentlyWatched VODs.', style: const TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Text('1', style: TextStyle(fontSize: 11, color: Colors.white38)),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                      activeTrackColor: themeNotifier.primaryColor,
                                      inactiveTrackColor: Colors.white10,
                                      thumbColor: themeNotifier.primaryColor,
                                    ),
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
                                const Text('20', style: TextStyle(fontSize: 11, color: Colors.white38)),
                              ],
                            ),
                            const SizedBox(height: 24),
                            const Divider(color: Colors.white12),
                            const SizedBox(height: 12),
                            const Text('Watch History', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                                side: const BorderSide(color: Colors.redAccent, width: 1),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                              ),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Clear Watch History?'),
                                    content: const Text('Are you sure you want to clear your local watch progress history for all VODs? This action cannot be undone.'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
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
                            const Text('Player Type', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: tempPlayerType,
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
                                      Text('(Available)', style: TextStyle(fontSize: 10, color: Colors.greenAccent.shade200, fontWeight: FontWeight.bold)),
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
                                        PlayerService().detectInstalledPlayers(settings)['vlc'] == true ? '(Detected)' : '(Not Found)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: PlayerService().detectInstalledPlayers(settings)['vlc'] == true ? Colors.greenAccent : Colors.redAccent.shade100,
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
                                        PlayerService().detectInstalledPlayers(settings)['mpv'] == true ? '(Detected)' : '(Not Found)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: PlayerService().detectInstalledPlayers(settings)['mpv'] == true ? Colors.greenAccent : Colors.redAccent.shade100,
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
                                        PlayerService().detectInstalledPlayers(settings)['mpc-hc'] == true ? '(Detected)' : '(Not Found)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: PlayerService().detectInstalledPlayers(settings)['mpc-hc'] == true ? Colors.greenAccent : Colors.redAccent.shade100,
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
                                      if (settings.customPlayerPath.trim().isNotEmpty) ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          PlayerService().detectInstalledPlayers(settings)['custom'] == true ? '(Valid Path)' : '(File Missing)',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: PlayerService().detectInstalledPlayers(settings)['custom'] == true ? Colors.greenAccent : Colors.redAccent.shade100,
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
                              const Text('Custom Player Executable Path', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: playerPathController,
                                      style: const TextStyle(fontSize: 12),
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
                                    icon: const Icon(Icons.file_open, color: Colors.white, size: 16),
                                    label: const Text('Browse', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 18),
                            const Text('Custom Player Arguments (Optional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: playerArgsController,
                              style: const TextStyle(fontSize: 13),
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
                            const Text('Twitch API Authentication', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: themeNotifier.backgroundColor,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.white10),
                              ),
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
                                            color: settings.twitchOauthToken.trim().isNotEmpty ? Colors.green : Colors.orange,
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
                                              color: settings.twitchOauthToken.trim().isNotEmpty ? Colors.green : Colors.orange,
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
                                        icon: const Icon(Icons.login, size: 12, color: Colors.white),
                                        label: const Text('Connect Account', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
                                      ),
                                    ],
                                  ),
                                  if (settings.twitchOauthToken.trim().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    const Text(
                                      'Connecting allows you to automatically load your followed channels, view channel VOD lists, stream subscriber-only feeds, and remove ads.',
                                      style: TextStyle(fontSize: 10, color: Colors.white38, height: 1.4),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),
                            const Text('Twitch Client ID', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            const SizedBox(height: 4),
                            TextField(
                              controller: clientIdController,
                              style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                              decoration: const InputDecoration(
                                hintText: 'Twitch Client ID',
                                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Twitch OAuth Token (Optional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
                              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
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
                                const Text('Twitch Browser Token (Optional, for VOD Sync)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
                                    style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
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
                                      backgroundColor: isTestingToken ? const Color(0xFF1E2433) : themeNotifier.primaryColor,
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                    ),
                                    onPressed: isTestingToken
                                        ? null
                                        : () async {
                                            final rawInput = webTokenController.text.trim();
                                            if (rawInput.isEmpty) {
                                              setDialogState(() {
                                                tokenTestResult = 'Please enter a token first.';
                                                isTokenValid = false;
                                              });
                                              return;
                                            }
                                            setDialogState(() {
                                              isTestingToken = true;
                                              tokenTestResult = null;
                                            });

                                            String testToken = rawInput;
                                            if (testToken.startsWith('oauth:')) {
                                              testToken = testToken.substring(6);
                                            }

                                            try {
                                              final valUrl = Uri.parse('https://id.twitch.tv/oauth2/validate');
                                              final valRes = await http.get(valUrl, headers: {
                                                'Authorization': 'OAuth $testToken',
                                              }).timeout(const Duration(seconds: 5));

                                              if (valRes.statusCode == 200) {
                                                final decoded = json.decode(valRes.body);
                                                final login = decoded['login'] as String?;
                                                setDialogState(() {
                                                  isTestingToken = false;
                                                  isTokenValid = true;
                                                  tokenTestResult = 'Success! Connected as: $login';
                                                });
                                              } else {
                                                setDialogState(() {
                                                  isTestingToken = false;
                                                  isTokenValid = false;
                                                  tokenTestResult = 'Invalid token (Status ${valRes.statusCode})';
                                                });
                                              }
                                            } catch (e) {
                                              setDialogState(() {
                                                isTestingToken = false;
                                                isTokenValid = false;
                                                tokenTestResult = 'Connection error: $e';
                                              });
                                            }
                                          },
                                    child: isTestingToken
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white60),
                                          )
                                        : const Text('Test', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
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
                                    color: isTokenValid ? Colors.green : Colors.redAccent,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      tokenTestResult!,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isTokenValid ? Colors.green : Colors.redAccent,
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
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Preset Theme Swatches', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 8),
                            HorizontalMouseScrollable(
                              child: Row(
                                children: [
                                  buildPresetCard(
                                    name: 'Twitch Royal',
                                    primary: const Color(0xFFA970FF),
                                    bg: const Color(0xFF0B0E14),
                                    surface: const Color(0xFF151A23),
                                    activeProg: const Color(0xFFA970FF),
                                    watchedProg: const Color(0x9922C55E),
                                  ),
                                  buildPresetCard(
                                    name: 'Cyberpunk Neon',
                                    primary: const Color(0xFF00F2FE),
                                    bg: const Color(0xFF090A10),
                                    surface: const Color(0xFF121522),
                                    activeProg: const Color(0xFFFF007F),
                                    watchedProg: const Color(0x9910B981),
                                  ),
                                  buildPresetCard(
                                    name: 'Solar Sunset',
                                    primary: const Color(0xFFFF7A00),
                                    bg: const Color(0xFF0E0C0A),
                                    surface: const Color(0xFF1C1814),
                                    activeProg: const Color(0xFFFF9900),
                                    watchedProg: const Color(0x9934D399),
                                  ),
                                  buildPresetCard(
                                    name: 'Tokyo Drift',
                                    primary: const Color(0xFFFF2A85),
                                    bg: const Color(0xFF0A0612),
                                    surface: const Color(0xFF160E24),
                                    activeProg: const Color(0xFF7B2CBF),
                                    watchedProg: const Color(0x9900F5D4),
                                  ),
                                  buildPresetCard(
                                    name: 'Obsidian OLED',
                                    primary: const Color(0xFF38BDF8),
                                    bg: const Color(0xFF000000),
                                    surface: const Color(0xFF111111),
                                    activeProg: const Color(0xFF38BDF8),
                                    watchedProg: const Color(0x994ADE80),
                                  ),
                                  buildPresetCard(
                                    name: 'Nordic Emerald',
                                    primary: const Color(0xFF10B981),
                                    bg: const Color(0xFF07120E),
                                    surface: const Color(0xFF0F241C),
                                    activeProg: const Color(0xFF10B981),
                                    watchedProg: const Color(0x992DD4BF),
                                  ),
                                  buildPresetCard(
                                    name: 'Vampire Crimson',
                                    primary: const Color(0xFFF43F5E),
                                    bg: const Color(0xFF0F080A),
                                    surface: const Color(0xFF1F1115),
                                    activeProg: const Color(0xFFF43F5E),
                                    watchedProg: const Color(0x9910B981),
                                  ),
                                  buildPresetCard(
                                    name: 'Nordic Glacier',
                                    primary: const Color(0xFF60A5FA),
                                    bg: const Color(0xFF0F172A),
                                    surface: const Color(0xFF1E293B),
                                    activeProg: const Color(0xFF60A5FA),
                                    watchedProg: const Color(0x9934D399),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            const Text(
                              'Choose Custom Color to Edit',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: activeColorKey,
                              decoration: const InputDecoration(
                                contentPadding: EdgeInsets.symmetric(horizontal: 12),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'primary', child: Text('Primary Branding Color')),
                                DropdownMenuItem(value: 'background', child: Text('Application Background')),
                                DropdownMenuItem(value: 'surface', child: Text('Card / Sidebar / Dialog Background')),
                                DropdownMenuItem(value: 'activeProgress', child: Text('In-Progress VOD Color')),
                                DropdownMenuItem(value: 'watchedProgress', child: Text('Fully Watched VOD Color')),
                              ],
                              onChanged: (val) {
                                if (val != null) {
                                  setDialogState(() {
                                    activeColorKey = val;
                                    hexController.text = colorToHex(getActiveColor());
                                  });
                                }
                              },
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: activeColor,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Colors.white24, width: 1.5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.3),
                                        blurRadius: 4,
                                      )
                                    ]
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: TextField(
                                    controller: hexController,
                                    style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
                                    decoration: const InputDecoration(
                                      labelText: 'Hex Color Value',
                                      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    ),
                                    onChanged: (val) {
                                      final newCol = parseHexColor(val, getActiveColor());
                                      if (newCol != getActiveColor()) {
                                        updateActiveColor(newCol);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            buildColorSlider(
                              label: 'Red Channel',
                              value: activeColor.red.toDouble(),
                              sliderColor: Colors.redAccent,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(activeColor.alpha, val.round(), activeColor.green, activeColor.blue));
                              },
                            ),
                            buildColorSlider(
                              label: 'Green Channel',
                              value: activeColor.green.toDouble(),
                              sliderColor: Colors.greenAccent,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(activeColor.alpha, activeColor.red, val.round(), activeColor.blue));
                              },
                            ),
                            buildColorSlider(
                              label: 'Blue Channel',
                              value: activeColor.blue.toDouble(),
                              sliderColor: Colors.blueAccent,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(activeColor.alpha, activeColor.red, activeColor.green, val.round()));
                              },
                            ),
                            buildColorSlider(
                              label: 'Opacity (Alpha Channel)',
                              value: activeColor.alpha.toDouble(),
                              sliderColor: Colors.white70,
                              onChanged: (val) {
                                updateActiveColor(Color.fromARGB(val.round(), activeColor.red, activeColor.green, activeColor.blue));
                              },
                            ),
                            const SizedBox(height: 18),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: presets.map((preset) {
                                final isSelected = activeColor.value == preset.value;
                                return MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () {
                                      updateActiveColor(preset);
                                    },
                                    child: Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: preset,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isSelected ? Colors.white : Colors.white24,
                                          width: isSelected ? 2.5 : 1.0,
                                        ),
                                        boxShadow: [
                                          if (isSelected)
                                            BoxShadow(
                                              color: preset.withOpacity(0.5),
                                              blurRadius: 6,
                                            )
                                        ],
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
                            const Text('VOD Download Directory', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: downloadFolderController,
                                    style: const TextStyle(fontSize: 13),
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
                                    // Use standard native FilePicker (resolving Issue 2)
                                    final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                                    if (selectedDirectory != null && selectedDirectory.isNotEmpty) {
                                      setDialogState(() {
                                        downloadFolderController.text = selectedDirectory;
                                      });
                                    }
                                  },
                                  icon: const Icon(Icons.folder_open, color: Colors.white, size: 16),
                                  label: const Text('Browse', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            const Text('Maximum downloads to keep (Threshold)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 4),
                            const Text('Delete oldest downloads automatically when limit is reached. Leave empty or set to 0 for unlimited.', style: TextStyle(fontSize: 11, color: Colors.white38)),
                            const SizedBox(height: 8),
                            TextField(
                              controller: maxDownloadsController,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                hintText: 'e.g. 5, 10, or leave empty',
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E2433),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: const Text(
                              'v${UpdateService.currentVersion}',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
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
                                  const Icon(Icons.code, size: 14, color: Colors.white54),
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
                            onPressed: () async {
                              final updateInfo = await UpdateService().checkForUpdates();
                              if (context.mounted) {
                                if (updateInfo != null) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Update Available: v${updateInfo.version}! Check main window prompt.')),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Twitch Streamlink GUI is up to date (v${UpdateService.currentVersion}).')),
                                  );
                                }
                              }
                            },
                            icon: const Icon(Icons.refresh, size: 13, color: Colors.white54),
                            label: const Text('Check for Updates', style: TextStyle(fontSize: 11, color: Colors.white70)),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () {
                              themeNotifier.updateTheme(
                                primary: origPrimary,
                                background: origBackground,
                                surface: origSurface,
                                activeProgress: origActiveProgress,
                                watchedProgress: origWatchedProgress,
                              );
                              Navigator.pop(context);
                            },
                            child: const Text('Cancel', style: TextStyle(color: Colors.white30)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: themeNotifier.primaryColor),
                            onPressed: () {
                              final updated = AppSettings(
                                defaultQuality: tempQuality,
                                twitchLowLatency: tempLowLatency,
                                playerType: tempPlayerType,
                                watchedThreshold: tempWatchedThreshold,
                                twitchOauthToken: tokenController.text.trim(),
                                twitchWebOauthToken: webTokenController.text.trim(),
                                customPlayerPath: playerPathController.text.trim(),
                                customPlayerArgs: playerArgsController.text.trim(),
                                twitchClientId: clientIdController.text.trim(),
                                localServerPort: int.tryParse(portController.text.trim()) ?? 65432,
                                vodDownloadFolder: downloadFolderController.text.trim(),
                                maxDownloadsToKeep: int.tryParse(maxDownloadsController.text.trim()) ?? 0,
                                unfinishedDownloads: settings.unfinishedDownloads,
                                maxRecentlyWatched: tempMaxRecentlyWatched,
                                activeSidebarTab: settings.activeSidebarTab,
                                sidebarCollapsed: settings.sidebarCollapsed,
                              );

                              updated.primaryColorHex = colorToHex(tempPrimary);
                              updated.backgroundColorHex = colorToHex(tempBackground);
                              updated.surfaceColorHex = colorToHex(tempSurface);
                              updated.activeProgressColorHex = colorToHex(tempActiveProgress);
                              updated.watchedProgressColorHex = colorToHex(tempWatchedProgress);

                              onSave(updated);
                              Navigator.pop(context);
                            },
                            child: const Text('Save Changes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
    );
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
              const Text('How to get Browser Token'),
            ],
          ),
          backgroundColor: const Color(0xFF161B26),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'To enable background watch progress syncing and VOD progress bars, you must copy your first-party browser login token from Twitch:',
                    style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  _buildStep('1', 'Open your web browser, go to twitch.tv, and make sure you are logged in to your account.'),
                  const SizedBox(height: 12),
                  _buildStep('2', 'Press F12 (or right-click anywhere on the page and select Inspect) to open the Developer Tools panel.'),
                  const SizedBox(height: 12),
                  _buildStep('3', 'Locate your cookies:\n• Chrome/Edge: Go to the Application tab -> expand Cookies on the left -> select https://www.twitch.tv\n• Firefox: Go to the Storage tab -> expand Cookies -> select https://www.twitch.tv'),
                  const SizedBox(height: 12),
                  _buildStep('4', 'In the cookies list, find the one named auth-token. Double-click its value, copy it, and paste it into the settings field.'),
                  const SizedBox(height: 16),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.info, size: 14, color: Colors.white30),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Note: Do NOT click "Log Out" on the Twitch website after copying this token. Clicking log out will immediately revoke the token on Twitch\'s servers.',
                          style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.4), height: 1.3),
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
              child: const Text('Got it!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  static Widget _buildStep(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFF1E2433),
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orangeAccent),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.35),
          ),
        ),
      ],
    );
  }
}
