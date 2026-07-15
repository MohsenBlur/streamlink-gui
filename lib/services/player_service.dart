import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/app_settings.dart';
import '../models/twitch_video.dart';
import 'twitch_api_service.dart';

class PlayerService {
  final TwitchApiService _apiService = TwitchApiService();
  
  String? downloadArchiveFilePath;

  // Active Downloads
  final Map<String, double> activeDownloadsProgress = {};
  final Map<String, Process> activeDownloadProcesses = {};
  final Map<String, String> activeDownloadTasks = {};
  final List<String> downloadQueue = [];
  final Map<String, TwitchVideo> queuedDownloadTasks = {};
  bool isQueueProcessing = false;

  // Active Players
  final Map<String, Process> activePlayerProcesses = {};
  final Map<String, int> activePlayerPorts = {};
  final Map<String, Timer> activePlayerTimers = {};
  final Set<String> playingVodIds = {};
  final Set<String> runningChannels = {};
  final Map<String, String> playerTabTitles = {};
  
  // Windows PowerShell bridges
  final Map<String, Process> _winIpcBridges = {};

  // Event Callbacks
  void Function(String vodId, double progress, String status)? onDownloadProgress;
  void Function(String vodId)? onDownloadCancelled;
  void Function(String vodId, String title, String filePath)? onDownloadCompleted;
  void Function(String vodId, String title, int exitCode)? onDownloadFailed;
  
  void Function(String key, String title)? onPlayerStarted;
  void Function(String key, int exitCode)? onPlayerStopped;
  void Function(String key, String line)? onPlayerLog;
  void Function(String vodId, int position, double progress)? onWatchProgressUpdated;

  int getNextAvailablePlayerPort() {
    int port = 8089;
    while (activePlayerPorts.containsValue(port)) {
      port++;
    }
    return port;
  }

  void log(String key, String line) {
    onPlayerLog?.call(key, line);
  }

  File? getDownloadedVodFile(String vodId, String channelName, String downloadFolder) {
    if (downloadFolder.trim().isEmpty) return null;
    final dir = Directory('${downloadFolder.trim()}/$channelName');
    if (!dir.existsSync()) return null;
    try {
      final files = dir.listSync();
      for (final file in files) {
        if (file is File) {
          final name = file.path.toLowerCase();
          if (RegExp(' - $vodId\\.[a-zA-Z0-9]+\$').hasMatch(name) &&
              !name.endsWith('.part') &&
              !name.endsWith('.ytdl') &&
              !name.endsWith('.tmp') &&
              !name.endsWith('.temp')) {
            return file;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  void removeVodFromArchive(String vodId) {
    if (downloadArchiveFilePath == null) return;
    final file = File(downloadArchiveFilePath!);
    if (!file.existsSync()) return;
    
    try {
      final lines = file.readAsLinesSync();
      final newLines = <String>[];
      bool changed = false;
      for (final line in lines) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts.last.trim() == vodId) {
          changed = true;
          continue;
        }
        newLines.add(line);
      }
      if (changed) {
        file.writeAsStringSync(newLines.join('\n') + (newLines.isNotEmpty ? '\n' : ''), flush: true);
      }
    } catch (_) {}
  }

  Future<void> startVodDownload(TwitchVideo vod, String channelName, AppSettings settings) async {
    final downloadFolder = settings.vodDownloadFolder.trim();
    if (downloadFolder.isEmpty) {
      throw Exception('Download folder is empty');
    }

    final outputDir = Directory('$downloadFolder/$channelName');
    if (!outputDir.existsSync()) {
      outputDir.createSync(recursive: true);
    }

    final vodId = vod.id;
    activeDownloadsProgress[vodId] = 0.0;
    activeDownloadTasks[vodId] = 'Starting...';
    onDownloadProgress?.call(vodId, 0.0, 'Starting...');

    final outputTemplate = '${outputDir.path}/%(title)s - %(id)s.%(ext)s';
    final url = 'https://twitch.tv/videos/$vodId';

    final args = <String>[];
    if (downloadArchiveFilePath != null && downloadArchiveFilePath!.trim().isNotEmpty) {
      args.addAll(['--download-archive', downloadArchiveFilePath!.trim()]);
    }
    args.addAll(['-o', outputTemplate, url]);

    try {
      final proc = await Process.start(
        'yt-dlp',
        args,
        runInShell: false,
      );

      activeDownloadProcesses[vodId] = proc;

      proc.stdout.transform(utf8.decoder).listen((line) {
        // Robust regex matching both integer & decimal percentage output
        final pctMatch = RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(line);
        final speedMatch = RegExp(r'at\s+(\S+)').firstMatch(line);

        double? pct;
        String? speed;
        if (pctMatch != null) {
          pct = double.tryParse(pctMatch.group(1)!);
        }
        if (speedMatch != null) {
          speed = speedMatch.group(1);
        }

        if (pct != null) {
          final double progress = pct / 100.0;
          activeDownloadsProgress[vodId] = progress;
          String statusText = '';
          if (speed != null) {
            statusText = 'Downloading: ${pct.toStringAsFixed(1)}% ($speed)';
          } else {
            statusText = 'Downloading: ${pct.toStringAsFixed(1)}%';
          }
          activeDownloadTasks[vodId] = statusText;
          onDownloadProgress?.call(vodId, progress, statusText);
        }
      });

      proc.stderr.transform(utf8.decoder).listen((_) {});

      final exitCode = await proc.exitCode;
      _cleanupDownloadState(vodId);

      if (exitCode == 0) {
        final downloadedFile = getDownloadedVodFile(vodId, channelName, settings.vodDownloadFolder);
        final filePath = downloadedFile?.path ?? '';
        onDownloadCompleted?.call(vodId, vod.title, filePath);
        _cleanupOldestDownloads(settings);
      } else {
        onDownloadFailed?.call(vodId, vod.title, exitCode);
      }
    } catch (e) {
      _cleanupDownloadState(vodId);
      onDownloadFailed?.call(vodId, vod.title, -1);
    }
  }

  void _cleanupDownloadState(String vodId) {
    activeDownloadProcesses.remove(vodId);
    activeDownloadsProgress.remove(vodId);
    activeDownloadTasks.remove(vodId);
  }

  void queueVodDownload(TwitchVideo vod, String channelName, AppSettings settings) {
    final vodId = vod.id;
    if (queuedDownloadTasks.containsKey(vodId) || activeDownloadProcesses.containsKey(vodId)) {
      return;
    }

    queuedDownloadTasks[vodId] = vod;
    downloadQueue.add(vodId);
    activeDownloadTasks[vodId] = 'Queued';
    onDownloadProgress?.call(vodId, 0.0, 'Queued');

    _processDownloadQueue(settings, channelName);
  }

  Future<void> _processDownloadQueue(AppSettings settings, String channelName) async {
    if (isQueueProcessing) return;
    isQueueProcessing = true;

    while (downloadQueue.isNotEmpty) {
      final vodId = downloadQueue.first;
      final vod = queuedDownloadTasks[vodId];
      if (vod != null) {
        await startVodDownload(vod, channelName, settings);
      }
      downloadQueue.remove(vodId);
      queuedDownloadTasks.remove(vodId);
    }

    isQueueProcessing = false;
  }

  Future<void> cancelVodDownload(String vodId, String channelName, String downloadFolder) async {
    final proc = activeDownloadProcesses[vodId];
    if (proc != null) {
      try {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }

    downloadQueue.remove(vodId);
    queuedDownloadTasks.remove(vodId);
    _cleanupDownloadState(vodId);
    onDownloadCancelled?.call(vodId);
    removeVodFromArchive(vodId);

    // Delete temporary incomplete files
    if (downloadFolder.trim().isNotEmpty) {
      final dir = Directory('${downloadFolder.trim()}/$channelName');
      if (dir.existsSync()) {
        try {
          final files = dir.listSync();
          for (final file in files) {
            if (file is File) {
              final name = file.path;
              if (name.contains(' - $vodId')) {
                await file.delete();
              }
            }
          }
        } catch (_) {}
      }
    }
  }

  void _cleanupOldestDownloads(AppSettings settings) {
    if (settings.maxDownloadsToKeep <= 0) return;
    final downloadFolder = settings.vodDownloadFolder.trim();
    if (downloadFolder.isEmpty) return;

    final mainDir = Directory(downloadFolder);
    if (!mainDir.existsSync()) return;

    try {
      final allFiles = <File>[];
      final entities = mainDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is File) {
          final name = entity.path;
          // Protect active .part/.ytdl downloads
          if (RegExp(r' - \d+\.[a-zA-Z0-9]+$').hasMatch(name) &&
              !name.endsWith('.part') &&
              !name.endsWith('.ytdl')) {
            allFiles.add(entity);
          }
        }
      }

      if (allFiles.length > settings.maxDownloadsToKeep) {
        allFiles.sort((a, b) {
          try {
            return a.lastModifiedSync().compareTo(b.lastModifiedSync());
          } catch (_) {
            return 0;
          }
        });

        int deletedCount = 0;
        while (allFiles.length > settings.maxDownloadsToKeep) {
          final oldestFile = allFiles.removeAt(0);
          try {
            if (oldestFile.existsSync()) {
              oldestFile.deleteSync();
              deletedCount++;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> playDownloadedVod(File file, TwitchVideo vod, AppSettings settings) async {
    final path = file.path;
    final args = <String>[];
    String exe = '';

    final seekTime = (vod.watchPosition != null && vod.watchPosition! > 10) ? vod.watchPosition! : 0;
    final watchedThresholdPct = settings.watchedThreshold / 100.0;
    final isFullyWatched = vod.watchProgress != null && vod.watchProgress! >= watchedThresholdPct;
    final finalSeek = isFullyWatched ? 0 : seekTime;

    final port = getNextAvailablePlayerPort();
    final key = vod.id;
    final title = 'Local: ${vod.title}';

    if (settings.playerType == 'vlc') {
      exe = 'vlc';
      if (finalSeek > 0) {
        args.add('--start-time=$finalSeek');
      }
      args.addAll([
        '--extraintf=http',
        '--http-port=$port',
        '--http-password=streamlink',
        '--http-host=127.0.0.1' // Bind securely to loopback
      ]);
      args.add(path);
    } else if (settings.playerType == 'mpv') {
      exe = 'mpv';
      if (finalSeek > 0) {
        args.add('--start=$finalSeek');
      }
      if (Platform.isWindows) {
        args.add('--input-ipc-server=\\\\.\\pipe\\mpv-socket-$key');
      } else {
        args.add('--input-ipc-server=/tmp/mpv-socket-$key');
      }
      args.add(path);
    } else if (settings.playerType == 'custom' && settings.customPlayerPath.trim().isNotEmpty) {
      exe = settings.customPlayerPath.trim();
      final lowerPath = exe.toLowerCase();
      if (lowerPath.contains('vlc')) {
        if (finalSeek > 0) {
          args.add('--start-time=$finalSeek');
        }
        args.addAll([
          '--extraintf=http',
          '--http-port=$port',
          '--http-password=streamlink',
          '--http-host=127.0.0.1'
        ]);
      } else if (lowerPath.contains('mpv')) {
        if (finalSeek > 0) {
          args.add('--start=$finalSeek');
        }
        if (Platform.isWindows) {
          args.add('--input-ipc-server=\\\\.\\pipe\\mpv-socket-$key');
        } else {
          args.add('--input-ipc-server=/tmp/mpv-socket-$key');
        }
      }
      args.add(path);
    } else {
      exe = 'cmd';
      args.addAll(['/c', 'start', '""', path]);
    }

    try {
      playingVodIds.add(vod.id);
      activePlayerPorts[vod.id] = port;
      playerTabTitles[key] = title;

      onPlayerStarted?.call(key, title);
      log(key, '[System] Initializing local player for VOD ${vod.id}...');
      log(key, '[System] Seek time offset: ${finalSeek}s');
      log(key, '[System] Running local file command: $exe ${args.join(" ")}');

      final proc = await Process.start(
        exe,
        args,
        runInShell: false,
      );

      activePlayerProcesses[vod.id] = proc;

      // Start Named Pipe bridge on Windows for MPV watch progress
      if (exe.toLowerCase().contains('mpv')) {
        if (Platform.isWindows) {
          await _startWindowsIpcBridge(key, port);
        }
      }

      _startVODProgressTracker(vod, port, settings);

      proc.exitCode.then((exitCode) {
        log(key, '[System] Local player process exited with code $exitCode');
        playingVodIds.remove(vod.id);
        activePlayerProcesses.remove(vod.id);
        activePlayerPorts.remove(vod.id);
        _stopWindowsIpcBridge(key);
        _stopVODProgressTracker(vod.id);
        onPlayerStopped?.call(key, exitCode);
      });
    } catch (e) {
      playingVodIds.remove(vod.id);
      activePlayerPorts.remove(vod.id);
      log(key, '[System Error] Failed to launch local player: $e');
      onPlayerStopped?.call(key, -1);
    }
  }

  Future<void> launchStreamlinkForVod(TwitchVideo vod, String channelName, AppSettings settings) async {
    String titleString = '$channelName - ${vod.title}';
    final args = <String>[];
    args.addAll(['--title', titleString]);

    final token = settings.twitchOauthToken.trim().startsWith('oauth:') 
        ? settings.twitchOauthToken.trim().substring(6)
        : settings.twitchOauthToken.trim();
    
    final clientId = settings.twitchClientId.trim().isNotEmpty
        ? settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    if (token.isNotEmpty && clientId == 'kimne78kx3ncx6brgo4mv6wki5h1ko') {
      args.addAll(['--twitch-api-header', 'Authorization=OAuth $token']);
    }

    final port = getNextAvailablePlayerPort();
    final extraArgsList = <String>[];

    final key = vod.id;
    final title = 'VOD: ${vod.title}';

    if (settings.playerType == 'vlc') {
      args.addAll(['--player', 'vlc']);
      extraArgsList.addAll([
        '--extraintf=http',
        '--http-port=$port',
        '--http-password=streamlink',
        '--http-host=127.0.0.1'
      ]);
    } else if (settings.playerType == 'mpv') {
      args.addAll(['--player', 'mpv']);
      if (Platform.isWindows) {
        extraArgsList.add('--input-ipc-server=\\\\.\\pipe\\mpv-socket-$key');
      } else {
        extraArgsList.add('--input-ipc-server=/tmp/mpv-socket-$key');
      }
    } else if (settings.playerType == 'custom' && settings.customPlayerPath.trim().isNotEmpty) {
      args.addAll(['--player', settings.customPlayerPath.trim()]);
      final lowerPath = settings.customPlayerPath.toLowerCase();
      if (lowerPath.contains('vlc')) {
        extraArgsList.addAll([
          '--extraintf=http',
          '--http-port=$port',
          '--http-password=streamlink',
          '--http-host=127.0.0.1'
        ]);
      } else if (lowerPath.contains('mpv')) {
        if (Platform.isWindows) {
          extraArgsList.add('--input-ipc-server=\\\\.\\pipe\\mpv-socket-$key');
        } else {
          extraArgsList.add('--input-ipc-server=/tmp/mpv-socket-$key');
        }
      }
    }

    String combinedPlayerArgs = '';
    if (settings.customPlayerArgs.trim().isNotEmpty) {
      combinedPlayerArgs = settings.customPlayerArgs.trim();
    }
    if (extraArgsList.isNotEmpty) {
      if (combinedPlayerArgs.isNotEmpty) {
        combinedPlayerArgs += ' ' + extraArgsList.join(' ');
      } else {
        combinedPlayerArgs = extraArgsList.join(' ');
      }
    }

    if (combinedPlayerArgs.isNotEmpty) {
      args.addAll(['--player-args', combinedPlayerArgs]);
    }

    final watchedThresholdPct = settings.watchedThreshold / 100.0;
    final isFullyWatched = vod.watchProgress != null && vod.watchProgress! >= watchedThresholdPct;
    if (vod.watchPosition != null && vod.watchPosition! > 10 && !isFullyWatched) {
      args.addAll(['--hls-start-offset', '${vod.watchPosition}s']);
    }

    args.add('twitch.tv/videos/${vod.id}');
    args.add(settings.defaultQuality);

    playingVodIds.add(vod.id);
    activePlayerPorts[vod.id] = port;
    playerTabTitles[key] = title;

    onPlayerStarted?.call(key, title);
    log(key, '[System] Initializing Streamlink for twitch.tv/videos/${vod.id} ${settings.defaultQuality}...');
    log(key, '[System] Arguments: ${args.join(" ")}');

    try {
      final proc = await Process.start(
        'streamlink',
        args,
        runInShell: false,
      );

      activePlayerProcesses[vod.id] = proc;
      
      // Spawn Windows Named Pipe to TCP Bridge for MPV players
      final usesMpv = settings.playerType == 'mpv' || 
          (settings.playerType == 'custom' && settings.customPlayerPath.toLowerCase().contains('mpv'));
      if (usesMpv) {
        if (Platform.isWindows) {
          await _startWindowsIpcBridge(key, port);
        }
      }

      _startVODProgressTracker(vod, port, settings);

      proc.stdout.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            log(key, '[Streamlink] ${line.trim()}');
          }
        }
      });

      proc.stderr.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            log(key, '[Streamlink ERR] ${line.trim()}');
          }
        }
      });

      proc.exitCode.then((exitCode) {
        log(key, '[System] Streamlink process for VOD ${vod.id} exited with code $exitCode');
        playingVodIds.remove(vod.id);
        activePlayerProcesses.remove(vod.id);
        activePlayerPorts.remove(vod.id);
        _stopWindowsIpcBridge(key);
        _stopVODProgressTracker(vod.id);
        onPlayerStopped?.call(key, exitCode);
      });
    } catch (e) {
      log(key, '[System Error] Failed to start Streamlink: $e');
      playingVodIds.remove(vod.id);
      activePlayerPorts.remove(vod.id);
      onPlayerStopped?.call(key, -1);
    }
  }

  Future<void> launchStreamlinkForLive(String channelName, bool isLive, String? streamTitle, String? game, AppSettings settings) async {
    String titleString = channelName;
    if (isLive) {
      final titleText = streamTitle ?? 'Live Stream';
      final gameText = game ?? 'Twitch';
      titleString = '$channelName - $titleText ($gameText)';
    } else {
      titleString = '$channelName - Offline Stream';
    }

    final args = <String>[];
    args.addAll(['--title', titleString]);

    final token = settings.twitchOauthToken.trim().startsWith('oauth:') 
        ? settings.twitchOauthToken.trim().substring(6)
        : settings.twitchOauthToken.trim();
    
    final clientId = settings.twitchClientId.trim().isNotEmpty
        ? settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    if (token.isNotEmpty && clientId == 'kimne78kx3ncx6brgo4mv6wki5h1ko') {
      args.addAll(['--twitch-api-header', 'Authorization=OAuth $token']);
    }

    if (settings.twitchLowLatency) {
      args.add('--twitch-low-latency');
    }

    if (settings.playerType == 'vlc') {
      args.addAll(['--player', 'vlc']);
    } else if (settings.playerType == 'mpv') {
      args.addAll(['--player', 'mpv']);
    } else if (settings.playerType == 'custom' && settings.customPlayerPath.trim().isNotEmpty) {
      args.addAll(['--player', settings.customPlayerPath.trim()]);
    }

    if (settings.customPlayerArgs.trim().isNotEmpty) {
      args.addAll(['--player-args', settings.customPlayerArgs.trim()]);
    }

    args.add('twitch.tv/$channelName');
    args.add(settings.defaultQuality);

    final key = 'stream_$channelName';
    final title = '$channelName (Live)';
    
    runningChannels.add(channelName);
    playerTabTitles[key] = title;

    onPlayerStarted?.call(key, title);
    log(key, '[System] Initializing Streamlink for twitch.tv/$channelName ${settings.defaultQuality}...');
    log(key, '[System] Arguments: ${args.join(" ")}');

    try {
      final proc = await Process.start(
        'streamlink',
        args,
        runInShell: false,
      );

      activePlayerProcesses[key] = proc;

      proc.stdout.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            log(key, '[Streamlink] ${line.trim()}');
          }
        }
      });

      proc.stderr.transform(utf8.decoder).listen((data) {
        for (var line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            log(key, '[Streamlink Err] ${line.trim()}');
          }
        }
      });

      proc.exitCode.then((exitCode) {
        log(key, '[System] Streamlink process for channel $channelName terminated with exit code $exitCode');
        runningChannels.remove(channelName);
        activePlayerProcesses.remove(key);
        onPlayerStopped?.call(key, exitCode);
      });
    } catch (e) {
      log(key, '[System Error] Failed to run streamlink: $e');
      log(key, '[System Error] Ensure Streamlink is installed and available in your environment.');
      runningChannels.remove(channelName);
      activePlayerProcesses.remove(key);
      onPlayerStopped?.call(key, -1);
    }
  }

  void _startVODProgressTracker(TwitchVideo vod, int port, AppSettings settings) {
    int lastSynced = -1;
    String webToken = settings.twitchWebOauthToken.trim();
    if (webToken.startsWith('oauth:')) {
      webToken = webToken.substring(6);
    }
    if (webToken.isEmpty) {
      log(vod.id, '[System] No Browser OAuth Token configured. Skipping sync.');
      return;
    }

    final timer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      final isVlc = settings.playerType == 'vlc' || 
          (settings.playerType == 'custom' && settings.customPlayerPath.toLowerCase().contains('vlc'));
      final isMpv = settings.playerType == 'mpv' || 
          (settings.playerType == 'custom' && settings.customPlayerPath.toLowerCase().contains('mpv'));

      if (isVlc) {
        try {
          final auth = 'Basic ' + base64Encode(utf8.encode(':streamlink'));
          final response = await http.get(
            Uri.parse('http://localhost:$port/requests/status.json'),
            headers: {
              'Authorization': auth,
            },
          ).timeout(const Duration(seconds: 2));

          if (response.statusCode == 200) {
            final data = json.decode(response.body);
            final state = data['state'] as String?;
            final time = data['time'] as int?;
            if (state == 'playing' && time != null && time > 0) {
              if ((time - lastSynced).abs() >= 3) {
                lastSynced = time;
                _syncProgress(vod, time, webToken);
              }
            }
          }
        } catch (_) {}
      } else if (isMpv) {
        try {
          Socket? socket;
          if (Platform.isWindows) {
            // Windows Named Pipe IPC runs through the PowerShell TCP loopback bridge
            socket = await Socket.connect('127.0.0.1', port, timeout: const Duration(seconds: 2));
          } else {
            // macOS/Linux Unix domain socket connection
            socket = await Socket.connect(
              InternetAddress('/tmp/mpv-socket-${vod.id}', type: InternetAddressType.unix),
              0,
              timeout: const Duration(seconds: 2)
            );
          }

          String responseBuffer = '';
          socket.listen((data) {
            responseBuffer += utf8.decode(data);
            if (responseBuffer.contains('\n')) {
              socket?.destroy();
            }
          });
          socket.write('{"command": ["get_property", "time-pos"]}\n');
          socket.write('{"command": ["get_property", "pause"]}\n');
          await Future.delayed(const Duration(milliseconds: 300));

          final lines = responseBuffer.split('\n').where((l) => l.trim().isNotEmpty).toList();
          if (lines.isNotEmpty) {
            double? timePos;
            bool isPaused = false;
            for (final line in lines) {
              try {
                final parsed = json.decode(line);
                if (parsed['data'] is num) {
                  timePos = (parsed['data'] as num).toDouble();
                } else if (parsed['data'] is bool) {
                  isPaused = parsed['data'] as bool;
                }
              } catch (_) {}
            }
            if (timePos != null && !isPaused) {
              final rounded = timePos.round();
              if ((rounded - lastSynced).abs() >= 3) {
                lastSynced = rounded;
                _syncProgress(vod, rounded, webToken);
              }
            }
          }
        } catch (_) {}
      }
    });

    activePlayerTimers[vod.id] = timer;
  }

  void _stopVODProgressTracker(String videoID) {
    activePlayerTimers.remove(videoID)?.cancel();
  }

  Future<void> _syncProgress(TwitchVideo vod, int position, String webToken) async {
    try {
      await _apiService.syncSingleVODProgressDirect(vod.id, position, webToken);
      final totalSeconds = _apiService.parseDurationToSeconds(vod.duration);
      final progress = totalSeconds > 0 ? position / totalSeconds : 0.0;
      onWatchProgressUpdated?.call(vod.id, position, progress);
    } catch (_) {}
  }

  // Windows Named Pipe to TCP loopback bridge script execution
  Future<void> _startWindowsIpcBridge(String vodId, int port) async {
    final pipeName = 'mpv-socket-$vodId';
    final bridgeScript = '''
      \$ErrorActionPreference = 'Stop'
      try {
        \$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', '$pipeName', [System.IO.Pipes.PipeDirection]::InOut)
        \$pipe.Connect(8000) # wait up to 8s for MPV to initialize the pipe
        \$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        \$listener.Start()
        \$tcpClient = \$listener.AcceptTcpClient()
        \$tcpStream = \$tcpClient.GetStream()
        
        \$pTask = \$pipe.CopyToAsync(\$tcpStream)
        \$tTask = \$tcpStream.CopyToAsync(\$pipe)
        [System.Threading.Tasks.Task]::WaitAny(@(\$pTask, \$tTask))
        
        \$tcpClient.Close()
        \$listener.Stop()
        \$pipe.Close()
      } catch {
        exit 1
      }
    ''';

    try {
      final proc = await Process.start(
        'powershell',
        ['-WindowStyle', 'Hidden', '-Command', bridgeScript],
        runInShell: false
      );
      _winIpcBridges[vodId] = proc;
    } catch (_) {}
  }

  void _stopWindowsIpcBridge(String vodId) {
    final proc = _winIpcBridges.remove(vodId);
    if (proc != null) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
  }

  void killProcess(String key) {
    final proc = activePlayerProcesses[key];
    if (proc != null) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
  }

  void stopAll() {
    for (final proc in activePlayerProcesses.values) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
    activePlayerProcesses.clear();

    for (final timer in activePlayerTimers.values) {
      timer.cancel();
    }
    activePlayerTimers.clear();

    for (final proc in activeDownloadProcesses.values) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
    activeDownloadProcesses.clear();
    
    for (final proc in _winIpcBridges.values) {
      try {
        if (Platform.isWindows) {
          Process.runSync('taskkill', ['/F', '/T', '/PID', proc.pid.toString()]);
        } else {
          proc.kill();
        }
      } catch (_) {}
    }
    _winIpcBridges.clear();
  }
}
