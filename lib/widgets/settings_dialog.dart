import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../models/app_settings.dart';
import '../services/player_service.dart';
import '../services/update_service.dart';
import '../utils/color_utils.dart';
import '../theme/neu_theme.dart';

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

    showDialog(
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
                      // TAB 4: THEME & STYLING SETTINGS
                      SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Application Theme Mode', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFEBECF0),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: !themeNotifier.isDarkTheme ? themeNotifier.primaryColor : Colors.transparent,
                                          width: 2,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(color: Colors.white, offset: Offset(-3, -3), blurRadius: 6),
                                          BoxShadow(color: Color(0xFFA3B1C6), offset: Offset(3, 3), blurRadius: 6),
                                        ],
                                      ),
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
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1D212A),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: themeNotifier.isDarkTheme ? themeNotifier.primaryColor : Colors.transparent,
                                          width: 2,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(color: Color(0xFF2B303F), offset: Offset(-3, -3), blurRadius: 6),
                                          BoxShadow(color: Color(0xFF12151B), offset: Offset(3, 3), blurRadius: 6),
                                        ],
                                      ),
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
                            const Text('Light Theme Accent Color', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Accent color used when Soft Light theme is active.', style: TextStyle(fontSize: 11, color: themeNotifier.subtextColor)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                const Color(0xFFFF6584), // Soft Pink
                                const Color(0xFF7C3AED), // Twitch Purple
                                const Color(0xFF00F2FE), // Cyan
                                const Color(0xFF10B981), // Emerald
                                const Color(0xFFFF7A00), // Orange
                                const Color(0xFFF43F5E), // Rose
                              ].map((color) {
                                final isSelected = themeNotifier.lightAccentColor.value == color.value;
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
                                        color: isSelected ? Colors.white : Colors.black26,
                                        width: isSelected ? 3.0 : 1.0,
                                      ),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 24),
                            const Text('Dark Theme Accent Color', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Accent color used when Deep Dark theme is active.', style: TextStyle(fontSize: 11, color: themeNotifier.subtextColor)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                const Color(0xFFFF3B30), // Vibrant Red
                                const Color(0xFF8B5CF6), // Electric Purple
                                const Color(0xFF38BDF8), // Sky Blue
                                const Color(0xFFFF2A85), // Magenta
                                const Color(0xFFF59E0B), // Gold
                                const Color(0xFF10B981), // Emerald
                              ].map((color) {
                                final isSelected = themeNotifier.darkAccentColor.value == color.value;
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
                                        color: isSelected ? Colors.white : Colors.black45,
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
                            icon: Icon(Icons.refresh, size: 13, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                            label: Text('Check for Updates', style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11)),
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                            },
                            child: Text('Cancel', style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
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

                              updated.lightAccentColorHex = colorToHex(themeNotifier.lightAccentColor);
                              updated.darkAccentColorHex = colorToHex(themeNotifier.darkAccentColor);

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
              child: const Text('Got it!', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
