import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const TwitchStreamlinkApp());
}

class TwitchStreamlinkApp extends StatelessWidget {
  const TwitchStreamlinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twitch Streamlink GUI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0C0F17),
        primaryColor: const Color(0xFF9146FF), // Twitch Purple
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9146FF),
          secondary: Color(0xFF00F2FE), // Cyan Accent
          surface: Color(0xFF161B26),
          background: const Color(0xFF0C0F17),
          error: Color(0xFFFF4D4D),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF161B26),
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontFamily: 'Outfit', fontWeight: FontWeight.bold, color: Colors.white),
          bodyLarge: TextStyle(fontFamily: 'Inter', color: Color(0xFFE2E8F0)),
          bodyMedium: TextStyle(fontFamily: 'Inter', color: Color(0xFF94A3B8)),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF1F2937),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: Color(0xFF9146FF), width: 1.5),
          ),
          hintStyle: TextStyle(color: Colors.white38),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class AppSettings {
  String defaultQuality = 'best';
  bool twitchLowLatency = true;
  String twitchOauthToken = '';
  String playerType = 'default';
  String customPlayerPath = '';
  String customPlayerArgs = '';

  AppSettings({
    this.defaultQuality = 'best',
    this.twitchLowLatency = true,
    this.twitchOauthToken = '',
    this.playerType = 'default',
    this.customPlayerPath = '',
    this.customPlayerArgs = '',
  });

  Map<String, dynamic> toJson() => {
        'default_quality': defaultQuality,
        'twitch_low_latency': twitchLowLatency,
        'twitch_oauth_token': twitchOauthToken,
        'player_type': playerType,
        'custom_player_path': customPlayerPath,
        'custom_player_args': customPlayerArgs,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        defaultQuality: json['default_quality'] ?? 'best',
        twitchLowLatency: json['twitch_low_latency'] ?? true,
        twitchOauthToken: json['twitch_oauth_token'] ?? '',
        playerType: json['player_type'] ?? 'default',
        customPlayerPath: json['custom_player_path'] ?? '',
        customPlayerArgs: json['custom_player_args'] ?? '',
      );
}

class TwitchChannel {
  final String username;
  String? id;
  String? avatarUrl;
  String? followerCount;
  bool isLive = false;
  String? uptime;
  String? viewerCount;
  String? game;
  String? streamTitle;
  bool isLoading = false;
  String? errorMessage;
  DateTime? lastUpdated;

  TwitchChannel({required this.username});

  Map<String, dynamic> toJson() => {'username': username};
  factory TwitchChannel.fromJson(Map<String, dynamic> json) =>
      TwitchChannel(username: json['username'] as String);
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final List<TwitchChannel> _channels = [];
  TwitchChannel? _selectedChannel;
  bool _isGlobalLoading = false;
  final TextEditingController _searchController = TextEditingController();
  bool _isAdding = false;
  final AppSettings _settings = AppSettings();

  void _showSettingsDialog() {
    String tempQuality = _settings.defaultQuality;
    bool tempLowLatency = _settings.twitchLowLatency;
    String tempPlayerType = _settings.playerType;
    final tokenController = TextEditingController(text: _settings.twitchOauthToken);
    final playerPathController = TextEditingController(text: _settings.customPlayerPath);
    final playerArgsController = TextEditingController(text: _settings.customPlayerArgs);
    bool obscureToken = true;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);
            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.settings, color: theme.primaryColor),
                  const SizedBox(width: 10),
                  const Text('Streamlink Settings'),
                ],
              ),
              backgroundColor: const Color(0xFF161B26),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
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
                          DropdownMenuItem(value: '1080p60', child: Text('1080p 60fps')),
                          DropdownMenuItem(value: '1080p', child: Text('1080p')),
                          DropdownMenuItem(value: '720p60', child: Text('720p 60fps')),
                          DropdownMenuItem(value: '720p', child: Text('720p')),
                          DropdownMenuItem(value: '480p', child: Text('480p')),
                          DropdownMenuItem(value: 'worst', child: Text('Worst Available')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() => tempQuality = val);
                          }
                        },
                      ),
                      const SizedBox(height: 18),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Twitch Low Latency', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        subtitle: const Text('Reduces live stream delay, but may increase buffering on slow networks.', style: TextStyle(fontSize: 11)),
                        value: tempLowLatency,
                        activeColor: theme.primaryColor,
                        onChanged: (val) {
                          setDialogState(() => tempLowLatency = val);
                        },
                      ),
                      const SizedBox(height: 12),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 12),
                      const Text('Video Player Selection', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: tempPlayerType,
                        decoration: const InputDecoration(
                          contentPadding: EdgeInsets.symmetric(horizontal: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'default', child: Text('System / Streamlink Default')),
                          DropdownMenuItem(value: 'vlc', child: Text('Force VLC Player')),
                          DropdownMenuItem(value: 'mpv', child: Text('Force MPV Player')),
                          DropdownMenuItem(value: 'custom', child: Text('Use Custom Executable Path')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() => tempPlayerType = val);
                          }
                        },
                      ),
                      if (tempPlayerType == 'custom') ...[
                        const SizedBox(height: 14),
                        const Text('Custom Player Executable Path', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: playerPathController,
                          style: const TextStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: 'e.g. C:\\Program Files\\VideoLAN\\VLC\\vlc.exe',
                          ),
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
                      const SizedBox(height: 12),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Twitch OAuth Token (Optional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          TextButton(
                            onPressed: () => _openExternalLink('https://twitchapps.com/tmi/'),
                            child: const Text('Get Token', style: TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      TextField(
                        controller: tokenController,
                        obscureText: obscureToken,
                        style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
                        decoration: InputDecoration(
                          hintText: 'oauth:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
                          suffixIcon: IconButton(
                            icon: Icon(obscureToken ? Icons.visibility : Icons.visibility_off, size: 18),
                            onPressed: () => setDialogState(() => obscureToken = !obscureToken),
                          ),
                        ),
                      ),
                      const Text(
                        'Using an OAuth token allows viewing subscriber-only streams and removes ads if subscribed or Turbo member.',
                        style: TextStyle(fontSize: 10, color: Colors.white38, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white30)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor),
                  onPressed: () async {
                    setState(() {
                      _settings.defaultQuality = tempQuality;
                      _settings.twitchLowLatency = tempLowLatency;
                      _settings.playerType = tempPlayerType;
                      _settings.twitchOauthToken = tokenController.text.trim();
                      _settings.customPlayerPath = playerPathController.text.trim();
                      _settings.customPlayerArgs = playerArgsController.text.trim();
                    });
                    await _saveChannels();
                    if (mounted) {
                      Navigator.pop(context);
                      _showSnackBar('Settings saved successfully!', isError: false);
                    }
                  },
                  child: const Text('Save Changes', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Streamlink Process State
  Process? _activeStreamlinkProcess;
  final List<String> _streamlinkLogs = [];
  bool _isStreamlinkRunning = false;
  String? _runningChannel;
  final ScrollController _consoleScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  @override
  void dispose() {
    _activeStreamlinkProcess?.kill();
    _searchController.dispose();
    _consoleScrollController.dispose();
    super.dispose();
  }

  File _getStorageFile() {
    try {
      final exePath = Platform.resolvedExecutable;
      if (exePath.contains('flutter_tester') || exePath.contains('flutter_tools') || exePath.contains('dart')) {
        return File('channels_config.json');
      }
      final exeDir = Directory(exePath).parent.path;
      final exeFile = File('$exeDir/channels_config.json');

      // Helper to check if a directory is writable by attempting to create and delete a temporary file
      bool isDirWritable(String path) {
        try {
          final testFile = File('$path/.write_test');
          testFile.writeAsStringSync('test');
          testFile.deleteSync();
          return true;
        } catch (_) {
          return false;
        }
      }

      // If the executable directory is writable, keep portable mode configuration in exeDir
      if (isDirWritable(exeDir)) {
        return exeFile;
      }

      // If not writable (e.g., Program Files), use the user's AppData/Config directory
      String? appDataDir;
      if (Platform.isWindows) {
        appDataDir = Platform.environment['APPDATA'] ?? Platform.environment['LOCALAPPDATA'];
      } else if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          appDataDir = '$home/Library/Application Support';
        }
      } else if (Platform.isLinux) {
        appDataDir = Platform.environment['XDG_CONFIG_HOME'];
        if (appDataDir == null || appDataDir.isEmpty) {
          final home = Platform.environment['HOME'];
          if (home != null) {
            appDataDir = '$home/.config';
          }
        }
      }

      if (appDataDir != null) {
        final configDir = Directory('$appDataDir/TwitchStreamlinkGUI');
        final appDataFile = File('${configDir.path}/channels_config.json');

        // Migrate existing config file from exeDir if it exists but the AppData config doesn't
        if (!appDataFile.existsSync() && exeFile.existsSync()) {
          try {
            if (!configDir.existsSync()) {
              configDir.createSync(recursive: true);
            }
            exeFile.copySync(appDataFile.path);
          } catch (_) {
            // Ignore migration failure, fallback to clean config creation
          }
        } else if (!appDataFile.existsSync()) {
          try {
            if (!configDir.existsSync()) {
              configDir.createSync(recursive: true);
            }
          } catch (_) {}
        }
        return appDataFile;
      }

      return exeFile;
    } catch (_) {
      return File('channels_config.json');
    }
  }

  // Load channels from local configuration file
  Future<void> _loadChannels() async {
    setState(() => _isGlobalLoading = true);
    try {
      final file = _getStorageFile();
      List<String> usernames = [];

      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = json.decode(content);
          if (decoded is List) {
            usernames = decoded.map((item) => item.toString()).toList();
          } else if (decoded is Map) {
            final channelsJson = decoded['channels'];
            if (channelsJson is List) {
              usernames = channelsJson.map((item) => item.toString()).toList();
            }
            final settingsJson = decoded['settings'];
            if (settingsJson is Map<String, dynamic>) {
              setState(() {
                _settings.defaultQuality = settingsJson['default_quality'] ?? 'best';
                _settings.twitchLowLatency = settingsJson['twitch_low_latency'] ?? true;
                _settings.twitchOauthToken = settingsJson['twitch_oauth_token'] ?? '';
                _settings.playerType = settingsJson['player_type'] ?? 'default';
                _settings.customPlayerPath = settingsJson['custom_player_path'] ?? '';
                _settings.customPlayerArgs = settingsJson['custom_player_args'] ?? '';
              });
            }
          }
        }
      }

      _channels.clear();
      if (usernames.isNotEmpty) {
        for (var str in usernames) {
          final channel = TwitchChannel(username: str.toLowerCase().trim());
          _channels.add(channel);
        }
      } else {
        // Seed default channels if empty
        final defaults = ['limmy'];
        for (var name in defaults) {
          _channels.add(TwitchChannel(username: name));
        }
        await _saveChannels();
      }

      // Fetch stats for all loaded channels
      await _refreshAllChannels();
    } catch (e) {
      _showSnackBar('Error loading saved channels: $e', isError: true);
    } finally {
      setState(() => _isGlobalLoading = false);
    }
  }

  // Save channel usernames to local configuration file
  Future<void> _saveChannels() async {
    try {
      final file = _getStorageFile();
      final usernames = _channels.map((c) => c.username).toList();
      final config = {
        'channels': usernames,
        'settings': _settings.toJson(),
      };
      final content = json.encode(config);
      await file.writeAsString(content);
    } catch (e) {
      _showSnackBar('Error saving channels: $e', isError: true);
    }
  }

  // Fetch DecAPI statistics for a single channel
  Future<void> _fetchChannelStats(TwitchChannel channel) async {
    setState(() {
      channel.isLoading = true;
      channel.errorMessage = null;
    });

    final username = channel.username;
    try {
      // 1. Verify/Fetch User ID
      final idResponse = await http.get(Uri.parse('https://decapi.me/twitch/id/$username'));
      if (idResponse.statusCode == 200) {
        final resText = idResponse.body.trim();
        if (resText.toLowerCase().contains('user not found')) {
          throw Exception('Twitch user "$username" not found on Twitch.');
        }
        channel.id = resText;
      } else {
        throw Exception('API returned status code ${idResponse.statusCode}');
      }

      // 2. Fetch Avatar, Uptime, Followers, Viewers, Game, and Title in parallel
      final futures = await Future.wait([
        http.get(Uri.parse('https://decapi.me/twitch/avatar/$username')),
        http.get(Uri.parse('https://decapi.me/twitch/uptime/$username')),
        http.get(Uri.parse('https://decapi.me/twitch/followcount/$username')),
        http.get(Uri.parse('https://decapi.me/twitch/viewercount/$username')),
        http.get(Uri.parse('https://decapi.me/twitch/game/$username')),
        http.get(Uri.parse('https://decapi.me/twitch/title/$username')),
      ]);

      if (futures[0].statusCode == 200) {
        channel.avatarUrl = futures[0].body.trim();
      }
      
      if (futures[1].statusCode == 200) {
        final uptimeStr = futures[1].body.trim();
        if (uptimeStr.toLowerCase().contains('offline')) {
          channel.isLive = false;
          channel.uptime = 'Offline';
        } else {
          channel.isLive = true;
          channel.uptime = uptimeStr;
        }
      }

      if (futures[2].statusCode == 200) {
        channel.followerCount = _formatNumberString(futures[2].body.trim());
      }

      if (channel.isLive) {
        if (futures[3].statusCode == 200) {
          channel.viewerCount = _formatNumberString(futures[3].body.trim());
        }
        if (futures[4].statusCode == 200) {
          channel.game = futures[4].body.trim();
        }
        if (futures[5].statusCode == 200) {
          channel.streamTitle = futures[5].body.trim();
        }
      } else {
        channel.viewerCount = '0';
        channel.game = 'Offline';
        channel.streamTitle = 'No active broadcast';
      }

      channel.lastUpdated = DateTime.now();
    } catch (e) {
      channel.errorMessage = e.toString().replaceFirst('Exception: ', '');
      channel.isLive = false;
      channel.uptime = 'Offline';
    } finally {
      setState(() {
        channel.isLoading = false;
      });
    }
  }

  // Refresh all channels
  Future<void> _refreshAllChannels() async {
    final futures = _channels.map((c) => _fetchChannelStats(c));
    await Future.wait(futures);
    // If a channel is selected, update it in state
    if (_selectedChannel != null) {
      final index = _channels.indexWhere((c) => c.username == _selectedChannel!.username);
      if (index != -1) {
        setState(() {
          _selectedChannel = _channels[index];
        });
      }
    }
  }

  // Add a new Twitch channel to the list
  Future<void> _addChannel(String name) async {
    final cleanName = name.toLowerCase().trim();
    if (cleanName.isEmpty) return;

    if (_channels.any((c) => c.username == cleanName)) {
      _showSnackBar('Channel "$cleanName" is already in your list.', isError: true);
      return;
    }

    setState(() => _isAdding = true);

    final newChannel = TwitchChannel(username: cleanName);
    await _fetchChannelStats(newChannel);

    if (newChannel.errorMessage != null) {
      _showSnackBar('Failed to add channel: ${newChannel.errorMessage}', isError: true);
      setState(() => _isAdding = false);
      return;
    }

    setState(() {
      _channels.add(newChannel);
      _selectedChannel = newChannel;
      _searchController.clear();
      _isAdding = false;
    });

    await _saveChannels();
    _showSnackBar('Channel "$cleanName" added successfully!', isError: false);
  }

  // Remove a channel
  Future<void> _removeChannel(TwitchChannel channel) async {
    setState(() {
      _channels.removeWhere((c) => c.username == channel.username);
      if (_selectedChannel?.username == channel.username) {
        _selectedChannel = null;
      }
    });
    await _saveChannels();
    _showSnackBar('Channel "${channel.username}" removed.', isError: false);
  }

  // Streamlink Launching Logic
  Future<void> _launchStreamlink(String channelName) async {
    if (_isStreamlinkRunning) {
      _showSnackBar('Stopping active stream before starting a new one...', isError: false);
      _stopStreamlink();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    final channel = _channels.firstWhere(
      (c) => c.username == channelName.toLowerCase().trim(),
      orElse: () => TwitchChannel(username: channelName),
    );

    String titleString = channelName;
    if (channel.isLive) {
      final titleText = channel.streamTitle ?? 'Live Stream';
      final gameText = channel.game ?? 'Twitch';
      titleString = '${channel.username} - $titleText ($gameText)';
    } else {
      titleString = '${channel.username} - Offline Stream';
    }

    final args = <String>[];
    args.addAll(['--title', titleString]);

    if (_settings.twitchOauthToken.trim().isNotEmpty) {
      args.addAll(['--twitch-oauth-token', _settings.twitchOauthToken.trim()]);
    }

    if (_settings.twitchLowLatency) {
      args.add('--twitch-low-latency');
    }

    if (_settings.playerType == 'vlc') {
      args.addAll(['--player', 'vlc']);
    } else if (_settings.playerType == 'mpv') {
      args.addAll(['--player', 'mpv']);
    } else if (_settings.playerType == 'custom' && _settings.customPlayerPath.trim().isNotEmpty) {
      args.addAll(['--player', _settings.customPlayerPath.trim()]);
    }

    if (_settings.customPlayerArgs.trim().isNotEmpty) {
      args.addAll(['--player-args', _settings.customPlayerArgs.trim()]);
    }

    args.add('twitch.tv/$channelName');
    args.add(_settings.defaultQuality);

    setState(() {
      _streamlinkLogs.clear();
      _streamlinkLogs.add('[System] Initializing Streamlink for twitch.tv/$channelName ${_settings.defaultQuality}...');
      _streamlinkLogs.add('[System] Arguments: ${args.join(" ")}');
      _isStreamlinkRunning = true;
      _runningChannel = channelName;
    });

    try {
      // Run streamlink in a shell
      final proc = await Process.start(
        'streamlink',
        args,
        runInShell: true,
      );

      _activeStreamlinkProcess = proc;

      // Handle standard output stream
      proc.stdout.transform(utf8.decoder).listen((data) {
        if (!mounted) return;
        setState(() {
          for (var line in data.split('\n')) {
            if (line.trim().isNotEmpty) {
              _streamlinkLogs.add('[Streamlink] ${line.trim()}');
            }
          }
        });
        _scrollToConsoleBottom();
      });

      // Handle standard error stream
      proc.stderr.transform(utf8.decoder).listen((data) {
        if (!mounted) return;
        setState(() {
          for (var line in data.split('\n')) {
            if (line.trim().isNotEmpty) {
              _streamlinkLogs.add('[Streamlink Err] ${line.trim()}');
            }
          }
        });
        _scrollToConsoleBottom();
      });

      // Handle exit code
      proc.exitCode.then((exitCode) {
        if (!mounted) return;
        if (_runningChannel == channelName) {
          setState(() {
            _streamlinkLogs.add('[System] Streamlink process terminated with exit code $exitCode');
            _isStreamlinkRunning = false;
            _activeStreamlinkProcess = null;
          });
          _scrollToConsoleBottom();
        }
      });
    } catch (e) {
      setState(() {
        _streamlinkLogs.add('[System Error] Failed to run streamlink: $e');
        _streamlinkLogs.add('[System Error] Ensure Streamlink is installed and available in your environment.');
        _isStreamlinkRunning = false;
        _activeStreamlinkProcess = null;
      });
      _scrollToConsoleBottom();
    }
  }

  // Terminate active Streamlink process
  void _stopStreamlink() {
    if (_activeStreamlinkProcess != null) {
      _activeStreamlinkProcess!.kill();
      _activeStreamlinkProcess = null;
      setState(() {
        _streamlinkLogs.add('[System] Streamlink manually stopped by user.');
        _isStreamlinkRunning = false;
      });
      _scrollToConsoleBottom();
    }
  }

  void _scrollToConsoleBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_consoleScrollController.hasClients) {
        _consoleScrollController.animateTo(
          _consoleScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Open link in default web browser using OS explorer
  Future<void> _openExternalLink(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [url]);
      } else {
        _showSnackBar('Unsupported platform for launching external link', isError: true);
      }
    } catch (e) {
      _showSnackBar('Failed to open link: $e', isError: true);
    }
  }

  // UI Utilities
  void _showSnackBar(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        ),
        backgroundColor: isError ? Colors.redAccent : const Color(0xFF9146FF),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  String _formatNumberString(String value) {
    try {
      final numValue = int.tryParse(value);
      if (numValue == null) return value;
      if (numValue >= 1000000) {
        return '${(numValue / 1000000).toStringAsFixed(1)}M';
      } else if (numValue >= 1000) {
        return '${(numValue / 1000).toStringAsFixed(1)}K';
      }
      return numValue.toString();
    } catch (_) {
      return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      body: Row(
        children: [
          // Sidebar Panel
          Container(
            width: 320,
            color: const Color(0xFF111420),
            child: Column(
              children: [
                // Header / Branding
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Color(0xFF1E2433), width: 1.5)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.primaryColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.primaryColor, width: 1.5),
                        ),
                        child: Icon(Icons.live_tv, color: theme.colorScheme.secondary, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Streamlink Twitch',
                              style: theme.textTheme.titleLarge?.copyWith(fontSize: 18),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'DecAPI Live stats manager',
                              style: theme.textTheme.bodyMedium?.copyWith(fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings, color: Colors.white70, size: 20),
                        tooltip: 'Streamlink Settings',
                        onPressed: _showSettingsDialog,
                        hoverColor: theme.primaryColor.withOpacity(0.2),
                        splashRadius: 20,
                      ),
                    ],
                  ),
                ),
                
                // Add channel section
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: TextField(
                            controller: _searchController,
                            style: const TextStyle(fontSize: 13, color: Colors.white),
                            decoration: const InputDecoration(
                              hintText: 'Enter twitch username...',
                              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                            ),
                            onSubmitted: (val) => _addChannel(val),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 42,
                        width: 42,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.primaryColor,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: _isAdding ? null : () => _addChannel(_searchController.text),
                          child: _isAdding
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.add, color: Colors.white, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),

                // Global Actions
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF1E2433)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            foregroundColor: Colors.white70,
                          ),
                          onPressed: _isGlobalLoading ? null : _refreshAllChannels,
                          icon: _isGlobalLoading
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
                                )
                              : const Icon(Icons.refresh, size: 14),
                          label: const Text('Refresh All', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                
                // Channel list
                Expanded(
                  child: _isGlobalLoading && _channels.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _channels.isEmpty
                          ? const Center(
                              child: Text('No channels saved.\nAdd one above.', textAlign: TextAlign.center),
                            )
                          : ListView.builder(
                              itemCount: _channels.length,
                              itemBuilder: (context, index) {
                                final channel = _channels[index];
                                final isSelected = _selectedChannel?.username == channel.username;
                                return Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    color: isSelected
                                        ? theme.primaryColor.withOpacity(0.15)
                                        : Colors.transparent,
                                    border: Border.all(
                                      color: isSelected
                                          ? theme.primaryColor.withOpacity(0.4)
                                          : Colors.transparent,
                                      width: 1,
                                    ),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.only(left: 12, right: 4),
                                    leading: Stack(
                                      children: [
                                        CircleAvatar(
                                          radius: 18,
                                          backgroundColor: const Color(0xFF1F2937),
                                          backgroundImage: channel.avatarUrl != null
                                              ? NetworkImage(channel.avatarUrl!)
                                              : null,
                                          child: channel.avatarUrl == null
                                              ? const Icon(Icons.person, size: 18, color: Colors.white70)
                                              : null,
                                        ),
                                        Positioned(
                                          bottom: 0,
                                          right: 0,
                                          child: Container(
                                            width: 10,
                                            height: 10,
                                            decoration: BoxDecoration(
                                              color: channel.isLive ? Colors.green : Colors.grey,
                                              shape: BoxShape.circle,
                                              border: Border.all(color: const Color(0xFF111420), width: 1.5),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            channel.username,
                                            style: theme.textTheme.bodyLarge?.copyWith(
                                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                              fontSize: 14,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (channel.isLive)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.red,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: const Text(
                                              'LIVE',
                                              style: TextStyle(
                                                fontSize: 8,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    subtitle: channel.isLoading
                                        ? const Padding(
                                            padding: EdgeInsets.only(top: 4),
                                            child: LinearProgressIndicator(minHeight: 1.5),
                                          )
                                        : Text(
                                            channel.isLive
                                                ? (channel.game ?? 'Playing...')
                                                : 'Offline',
                                            style: const TextStyle(fontSize: 11),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.close, size: 16, color: Colors.white30),
                                      onPressed: () => _removeChannel(channel),
                                      hoverColor: Colors.red.withOpacity(0.2),
                                      splashRadius: 18,
                                    ),
                                    onTap: () {
                                      setState(() {
                                        _selectedChannel = channel;
                                      });
                                    },
                                  ),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
          
          // Main Content Area
          Expanded(
            child: Container(
              color: const Color(0xFF0C0F17),
              child: _selectedChannel == null
                  ? _buildWelcomeScreen(theme)
                  : _buildDashboard(theme, _selectedChannel!),
            ),
          ),
        ],
      ),
    );
  }

  // Welcome Screen when no channel is selected
  Widget _buildWelcomeScreen(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: const Color(0xFF161B26),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF1E2433), width: 2),
              boxShadow: [
                BoxShadow(
                  color: theme.primaryColor.withOpacity(0.1),
                  blurRadius: 40,
                  spreadRadius: 10,
                )
              ],
            ),
            child: Icon(Icons.live_tv, size: 72, color: theme.primaryColor),
          ),
          const SizedBox(height: 24),
          Text(
            'Twitch Channel Dashboard',
            style: theme.textTheme.titleLarge?.copyWith(fontSize: 24, letterSpacing: 0.5),
          ),
          const SizedBox(height: 10),
          const SizedBox(
            width: 320,
            child: Text(
              'Select a Twitch channel from the sidebar or search/add a new one to view real-time stats and launch streams.',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.5, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // Active Dashboard
  Widget _buildDashboard(ThemeData theme, TwitchChannel channel) {
    return Column(
      children: [
        // Main Dashboard Body (Scrollable)
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Live/Profile Header Card
                _buildHeaderCard(theme, channel),
                const SizedBox(height: 24),
                
                // Statistics Grid Section
                Text(
                  'Live Statistics',
                  style: theme.textTheme.titleLarge?.copyWith(fontSize: 16, letterSpacing: 0.5),
                ),
                const SizedBox(height: 12),
                
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 3,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 1.6,
                  children: [
                    _buildStatCard(
                      icon: Icons.title,
                      iconColor: theme.colorScheme.secondary,
                      title: 'Stream Title',
                      value: channel.isLive ? (channel.streamTitle ?? 'No Title') : 'Offline',
                      isLongText: true,
                    ),
                    _buildStatCard(
                      icon: Icons.gamepad,
                      iconColor: theme.colorScheme.secondary,
                      title: 'Current Game / Category',
                      value: channel.isLive ? (channel.game ?? 'N/A') : 'Offline',
                    ),
                    _buildStatCard(
                      icon: Icons.schedule,
                      iconColor: Colors.orangeAccent,
                      title: 'Uptime',
                      value: channel.isLive ? (channel.uptime ?? 'N/A') : 'Offline',
                    ),
                    _buildStatCard(
                      icon: Icons.visibility,
                      iconColor: Colors.redAccent,
                      title: 'Live Viewers',
                      value: channel.isLive ? (channel.viewerCount ?? '0') : '0',
                    ),
                    _buildStatCard(
                      icon: Icons.people,
                      iconColor: theme.primaryColor,
                      title: 'Followers',
                      value: channel.followerCount ?? 'N/A',
                    ),
                    _buildStatCard(
                      icon: Icons.badge,
                      iconColor: Colors.grey,
                      title: 'Twitch User ID',
                      value: channel.id ?? 'Fetching...',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        // Streamlink logs console drawer (Bottom Panel)
        _buildConsolePanel(theme),
      ],
    );
  }

  // Dashboard Header widget
  Widget _buildHeaderCard(ThemeData theme, TwitchChannel channel) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF161B26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E2433)),
        boxShadow: [
          BoxShadow(
            color: (channel.isLive ? Colors.green : Colors.grey).withOpacity(0.03),
            blurRadius: 20,
            spreadRadius: 2,
          )
        ],
      ),
      child: Row(
        children: [
          // Profile Avatar
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: channel.isLive ? Colors.greenAccent : Colors.white24,
                width: 2.5,
              ),
            ),
            child: CircleAvatar(
              radius: 40,
              backgroundColor: const Color(0xFF1F2937),
              backgroundImage: channel.avatarUrl != null ? NetworkImage(channel.avatarUrl!) : null,
              child: channel.avatarUrl == null
                  ? const Icon(Icons.person, size: 40, color: Colors.white70)
                  : null,
            ),
          ),
          const SizedBox(width: 20),
          
          // Info & Status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      channel.username,
                      style: theme.textTheme.titleLarge?.copyWith(fontSize: 22),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: channel.isLive
                            ? Colors.green.withOpacity(0.15)
                            : Colors.grey.withOpacity(0.15),
                        border: Border.all(
                          color: channel.isLive ? Colors.greenAccent : Colors.grey,
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        channel.isLive ? 'LIVE' : 'OFFLINE',
                        style: TextStyle(
                          color: channel.isLive ? Colors.greenAccent : Colors.grey,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  channel.isLive
                      ? 'Streaming: ${channel.game ?? "Unknown Game"}'
                      : 'Channel is currently offline',
                  style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.update, size: 12, color: Colors.white38),
                    const SizedBox(width: 4),
                    Text(
                      channel.lastUpdated != null
                          ? 'Last updated: ${channel.lastUpdated!.toLocal().toString().substring(11, 19)}'
                          : 'Not updated yet',
                      style: const TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                    const SizedBox(width: 12),
                    if (channel.errorMessage != null)
                      Flexible(
                        child: Text(
                          'Error: ${channel.errorMessage}',
                          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          
          // Quick actions container
          Column(
            children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.primaryColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(160, 44),
                  shadowColor: theme.primaryColor.withOpacity(0.4),
                  elevation: 6,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => _launchStreamlink(channel.username),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Launch Streamlink', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  // Open Twitch Browser button
                  _buildMiniActionBtn(
                    icon: Icons.open_in_new,
                    tooltip: 'Open Twitch channel',
                    onPressed: () => _openExternalLink('https://twitch.tv/${channel.username}'),
                  ),
                  const SizedBox(width: 8),
                  // Chat popout button
                  _buildMiniActionBtn(
                    icon: Icons.chat_bubble_outline,
                    tooltip: 'Open Twitch chat popout',
                    onPressed: () => _openExternalLink('https://twitch.tv/${channel.username}/chat'),
                  ),
                  const SizedBox(width: 8),
                  // Manual Refresh button
                  _buildMiniActionBtn(
                    icon: Icons.refresh,
                    tooltip: 'Refresh statistics',
                    onPressed: channel.isLoading ? null : () => _fetchChannelStats(channel),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Mini actions helper
  Widget _buildMiniActionBtn({required IconData icon, required String tooltip, required VoidCallback? onPressed}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF374151)),
      ),
      child: IconButton(
        icon: Icon(icon, size: 14, color: Colors.white70),
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        splashRadius: 16,
      ),
    );
  }

  // Card widgets for stats dashboard
  Widget _buildStatCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    bool isLongText = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E2433)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: isLongText ? 12 : 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    height: 1.3,
                  ),
                  maxLines: isLongText ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Console output Widget at the bottom
  Widget _buildConsolePanel(ThemeData theme) {
    if (_streamlinkLogs.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 200,
      decoration: const BoxDecoration(
        color: Color(0xFF07090E),
        border: Border(top: BorderSide(color: Color(0xFF1E2433), width: 1.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Console Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF111420),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _isStreamlinkRunning ? Colors.greenAccent : Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Streamlink Terminal Console${_runningChannel != null ? ' - $_runningChannel' : ''}',
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    if (_isStreamlinkRunning)
                      SizedBox(
                        height: 26,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          icon: const Icon(Icons.stop, size: 14),
                          label: const Text('Kill Process', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          onPressed: _stopStreamlink,
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 14, color: Colors.white30),
                      onPressed: () {
                        setState(() {
                          _streamlinkLogs.clear();
                        });
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      splashRadius: 16,
                      tooltip: 'Clear Console',
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Console Log Lines
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                controller: _consoleScrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _streamlinkLogs.length,
                itemBuilder: (context, index) {
                  final log = _streamlinkLogs[index];
                  Color logColor = Colors.white70;
                  if (log.startsWith('[System Error]') || log.startsWith('[Streamlink Err]')) {
                    logColor = Colors.redAccent;
                  } else if (log.startsWith('[System]')) {
                    logColor = theme.colorScheme.secondary;
                  } else if (log.contains('[cli][info]')) {
                    logColor = Colors.greenAccent;
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      log,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11,
                        color: logColor,
                        height: 1.3,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
