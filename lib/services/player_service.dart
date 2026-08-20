import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import '../models/app_settings.dart';
import '../utils/player_args.dart';
import '../models/twitch_video.dart';
import 'twitch_api_service.dart';

class PlayerService {
  final TwitchApiService _apiService = TwitchApiService();

  String _getExecutablePath(String name) {
    final exeName = Platform.isWindows ? '$name.exe' : name;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final devDir = Directory.current.path;

    final candidates = [
      path.join(exeDir, 'bin', 'bin', exeName),
      path.join(exeDir, 'bin', exeName),
      path.join(exeDir, exeName),
      path.join(devDir, 'bin', 'bin', exeName),
      path.join(devDir, 'bin', exeName),
    ];

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    // Fallback: system PATH
    return name;
  }

  Map<String, String> _getEnvironmentWithBin() {
    final env = Map<String, String>.from(Platform.environment);
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final devDir = Directory.current.path;

    final binSubPath = path.join(exeDir, 'bin', 'bin');
    final binPath = path.join(exeDir, 'bin');
    final devBinSubPath = path.join(devDir, 'bin', 'bin');
    final devBinPath = path.join(devDir, 'bin');

    final pathKey = env.keys.firstWhere((k) => k.toUpperCase() == 'PATH', orElse: () => 'PATH');
    final existingPath = env[pathKey] ?? '';
    env[pathKey] = '$binSubPath;$binPath;$devBinSubPath;$devBinPath;$existingPath';
    return env;
  }
  
  String? downloadArchiveFilePath;

  // Active Downloads
  final Map<String, double> activeDownloadsProgress = {};
  final Map<String, Process> activeDownloadProcesses = {};
  final Map<String, String> activeDownloadTasks = {};
  final List<String> downloadQueue = [];
  final Map<String, TwitchVideo> queuedDownloadTasks = {};
  final Map<String, String> downloadChannelNames = {};
  final Map<String, String> downloadTitles = {};
  bool isQueueProcessing = false;

  /// VOD ids whose download the user cancelled, so the exit handler can tell a
  /// deliberate cancel apart from a genuine failure.
  final Set<String> _cancelledDownloads = {};

  // Active Players
  final Map<String, Process> activePlayerProcesses = {};
  final Map<String, int> activePlayerPorts = {};
  final Map<String, Timer> activePlayerTimers = {};
  final Set<String> playingVodIds = {};

  /// vodId -> absolute path of the local file currently open in a player.
  /// Consulted by retention so it never deletes what the user is watching.
  final Map<String, String> playingVodFilePaths = {};

  /// Lowercased names of channels whose live stream is currently playing.
  final Set<String> runningChannels = {};

  /// Process-map key for a live stream.
  ///
  /// Callers must never build this by hand. Auto-play preemption used to call
  /// `killProcess(channelName)` while the process was registered under
  /// `stream_<channelName>`, so the lookup always missed: the log claimed the
  /// lower-priority stream had been killed while it kept playing, and the
  /// preemption feature was entirely dead.
  static String liveStreamKey(String channelName) =>
      'stream_' + channelName.toLowerCase().trim();

  /// Stops the live stream for [channelName], if one is running.
  void killLiveStream(String channelName) {
    killProcess(liveStreamKey(channelName));
  }

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

  String? findVlcPath() {
    final candidates = [
      _getExecutablePath('vlc'),
      r'C:\Program Files\VideoLAN\VLC\vlc.exe',
      r'C:\Program Files (x86)\VideoLAN\VLC\vlc.exe',
    ];
    for (final p in candidates) {
      if (p != 'vlc' && File(p).existsSync()) return p;
    }
    return null;
  }

  String? findMpvPath() {
    final candidates = [
      _getExecutablePath('mpv'),
      r'C:\Program Files\mpv\mpv.exe',
      r'C:\Program Files (x86)\mpv\mpv.exe',
    ];
    for (final p in candidates) {
      if (p != 'mpv' && File(p).existsSync()) return p;
    }
    return null;
  }

  String? findMpcHcPath() {
    final candidates = [
      _getExecutablePath('mpc-hc64'),
      _getExecutablePath('mpc-hc'),
      r'C:\Program Files\MPC-HC\mpc-hc64.exe',
      r'C:\Program Files\MPC-HC\mpc-hc.exe',
      r'C:\Program Files (x86)\MPC-HC\mpc-hc.exe',
      r'C:\Program Files (x86)\K-Lite Codec Pack\MPC-HC64\mpc-hc64.exe',
      r'C:\Program Files (x86)\K-Lite Codec Pack\MPC-HC\mpc-hc.exe',
    ];
    for (final p in candidates) {
      if (p != 'mpc-hc64' && p != 'mpc-hc' && File(p).existsSync()) return p;
    }
    return null;
  }

  Map<String, bool> detectInstalledPlayers(AppSettings settings) {
    return {
      'vlc': findVlcPath() != null,
      'mpv': findMpvPath() != null,
      'mpc-hc': findMpcHcPath() != null,
      'default': true,
      'custom': settings.customPlayerPath.trim().isNotEmpty &&
          File(settings.customPlayerPath.trim().replaceAll('"', '')).existsSync(),
    };
  }

  /// Resolves the configured player to a concrete one.
  ///
  /// 'default' means "whatever is installed"; it must be turned into a real
  /// player before building arguments. Only local playback did this, so the
  /// two streamlink paths fell through every branch and passed no --player at
  /// all - leaving Streamlink to guess, and skipping the player-specific
  /// arguments (VLC's HTTP interface, MPV's IPC socket, MPC-HC's web port)
  /// that watch-progress tracking depends on.
  String resolveEffectivePlayerType(AppSettings settings) {
    if (settings.playerType != 'default') return settings.playerType;
    if (findVlcPath() != null) return 'vlc';
    if (findMpvPath() != null) return 'mpv';
    if (findMpcHcPath() != null) return 'mpc-hc';
    return 'default';
  }

  /// The executable for the resolved player, or null when there is none.
  ///
  /// The bare-name fallbacks preserve the previous `--player` values: a player
  /// on PATH but not at a known install location keeps working, because
  /// streamlink resolves it itself.
  String? resolvePlayerExecutable(String effectivePlayerType, AppSettings settings) {
    if (effectivePlayerType == 'custom') {
      final p = settings.customPlayerPath.trim().replaceAll('"', '');
      return p.isEmpty ? null : p;
    }
    switch (effectivePlayerType) {
      case 'vlc':
        return findVlcPath() ?? 'vlc';
      case 'mpv':
        return findMpvPath() ?? 'mpv';
      case 'mpc-hc':
        return findMpcHcPath() ?? 'mpc-hc64';
    }
    return null;
  }

  void log(String key, String line) {
    onPlayerLog?.call(key, line);
  }

  /// Matches a completed download for [vodId], e.g. `Some Title - 12345.mp4`.
  ///
  /// Anchored on the extension so a shorter id cannot match a longer one's
  /// file. Several deletion paths used to test `path.contains(' - $vodId')`,
  /// which would happily match `Title - 123456789.mp4` while deleting id
  /// `12345`.
  static RegExp _vodFinalFilePattern(String vodId) =>
      // The negative lookahead keeps a bare `Title - 12345.ytdl` from being
      // treated as a finished download just because `ytdl` is alphanumeric.
      RegExp(
        r' - v?' + RegExp.escape(vodId) + r'\.(?!(?:part|ytdl|tmp|temp)$)[A-Za-z0-9]+$',
        caseSensitive: false,
      );

  /// Matches yt-dlp's in-progress artefacts: `Title - 12345.mp4.part`,
  /// `Title - 12345.f301.mp4.part` and the bare `Title - 12345.ytdl`.
  static RegExp _vodTempFilePattern(String vodId) =>
      RegExp(
        r' - v?' + RegExp.escape(vodId) + r'(\..*)?\.(part|ytdl|tmp|temp)$',
        caseSensitive: false,
      );

  Directory? _channelDirectory(String channelName, String downloadFolder) {
    final folder = downloadFolder.trim();
    if (folder.isEmpty) return null;
    final dir = Directory(path.join(folder, channelName));
    if (!dir.existsSync()) return null;
    return dir;
  }

  /// Completed files belonging to [vodId] (never partials).
  List<File> findDownloadedVodFiles(String vodId, String channelName, String downloadFolder) {
    final dir = _channelDirectory(channelName, downloadFolder);
    if (dir == null) return const [];
    final pattern = _vodFinalFilePattern(vodId);
    try {
      return dir.listSync().whereType<File>().where((f) => pattern.hasMatch(f.path)).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Partial/temporary files belonging to [vodId].
  List<File> findTemporaryVodFiles(String vodId, String channelName, String downloadFolder) {
    final dir = _channelDirectory(channelName, downloadFolder);
    if (dir == null) return const [];
    final pattern = _vodTempFilePattern(vodId);
    try {
      return dir.listSync().whereType<File>().where((f) => pattern.hasMatch(f.path)).toList();
    } catch (_) {
      return const [];
    }
  }

  File? getDownloadedVodFile(String vodId, String channelName, String downloadFolder) {
    final matches = findDownloadedVodFiles(vodId, channelName, downloadFolder);
    return matches.isEmpty ? null : matches.first;
  }

  /// Deletes every file belonging to [vodId] and returns how many were removed.
  ///
  /// Returns a count rather than assuming success: the delete paths previously
  /// reported "Deleted download" and dropped the registry entry even when
  /// nothing was removed, orphaning the file on disk.
  int deleteVodFiles(String vodId, String channelName, String downloadFolder,
      {bool includeTemporary = true}) {
    var deleted = 0;
    final targets = <File>[
      ...findDownloadedVodFiles(vodId, channelName, downloadFolder),
      if (includeTemporary) ...findTemporaryVodFiles(vodId, channelName, downloadFolder),
    ];
    for (final file in targets) {
      try {
        if (file.existsSync()) {
          file.deleteSync();
          deleted++;
        }
      } catch (_) {}
    }
    return deleted;
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

  void deleteTemporaryDownloadFiles(String vodId, String channelName, String downloadFolder) {
    // Previously matched `path.contains(vodId)` anywhere in the name, so a
    // short id could delete another in-flight download's partial file.
    for (final file in findTemporaryVodFiles(vodId, channelName, downloadFolder)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }

  Future<void> startVodDownload(TwitchVideo vod, String channelName, AppSettings settings, {bool isRetryWithFfmpeg = false, bool? overrideDisablePostProcessing}) async {
    final downloadFolder = settings.vodDownloadFolder.trim();
    if (downloadFolder.isEmpty) {
      throw Exception('Download folder is empty');
    }

    final outputDir = Directory('$downloadFolder/$channelName');
    if (!outputDir.existsSync()) {
      outputDir.createSync(recursive: true);
    }

    final vodId = vod.id;
    downloadChannelNames[vodId] = channelName;
    downloadTitles[vodId] = vod.title;
    activeDownloadsProgress[vodId] = 0.0;
    activeDownloadTasks[vodId] = 'Starting...';
    onDownloadProgress?.call(vodId, 0.0, 'Starting...');

    final outputTemplate = '${outputDir.path}/%(title)s - %(id)s.%(ext)s';
    final url = 'https://twitch.tv/videos/$vodId';

    final args = <String>[];
    if (downloadArchiveFilePath != null && downloadArchiveFilePath!.trim().isNotEmpty) {
      args.addAll(['--download-archive', downloadArchiveFilePath!.trim()]);
    }
    if (isRetryWithFfmpeg) {
      args.addAll(['--downloader', 'ffmpeg']);
    }
    final disablePostProc = overrideDisablePostProcessing ?? settings.disableVodPostProcessing;
    if (disablePostProc) {
      args.addAll([
        '--no-embed-thumbnail',
        '--no-add-metadata',
        '--no-sponsorblock',
        '--no-embed-subs',
      ]);
    }
    if (settings.customVodArgs.trim().isNotEmpty) {
      final customArgsList = settings.customVodArgs
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      args.addAll(customArgsList);
    }
    args.addAll([
      '-o', outputTemplate,
      url
    ]);

    final key = 'dl-$vodId';
    final title = 'Download: ${vod.title}';
    playerTabTitles[key] = title;
    onPlayerStarted?.call(key, title);

    log(key, '[System] Initializing VOD Download for: ${vod.title}');
    log(key, '[System] Arguments: yt-dlp ${args.join(" ")}');

    bool needsFfmpegFallback = false;

    try {
      final proc = await Process.start(
        _getExecutablePath('yt-dlp'),
        args,
        environment: _getEnvironmentWithBin(),
        runInShell: false,
      );

      activeDownloadProcesses[vodId] = proc;

      proc.stdout.transform(utf8.decoder).listen((line) {
        final trimmed = line.trim();
        log(key, trimmed);
        if (line.contains('Initialization fragment found after media fragments')) {
          needsFfmpegFallback = true;
        }

        if (trimmed.startsWith('[Metadata]') ||
            trimmed.startsWith('[EmbedThumbnail]') ||
            trimmed.startsWith('[ModifyChapters]') ||
            trimmed.startsWith('[EmbedSubtitle]') ||
            trimmed.startsWith('[Fixup') ||
            trimmed.startsWith('[Merger]')) {
          activeDownloadTasks[vodId] = 'Finalizing file...';
          onDownloadProgress?.call(vodId, 1.0, 'Finalizing file...');
          return;
        }

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
          if (progress >= 1.0) {
            statusText = 'Finishing download...';
          } else if (speed != null) {
            statusText = 'Downloading: ${pct.toStringAsFixed(1)}% ($speed)';
          } else {
            statusText = 'Downloading: ${pct.toStringAsFixed(1)}%';
          }
          activeDownloadTasks[vodId] = statusText;
          onDownloadProgress?.call(vodId, progress, statusText);
        }
      });

      proc.stderr.transform(utf8.decoder).listen((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;

        final isFfmpegInfo = trimmed.contains('frame=') ||
            trimmed.contains('fps=') ||
            trimmed.contains('size=') ||
            trimmed.contains('time=') ||
            trimmed.contains('bitrate=') ||
            trimmed.contains('speed=') ||
            trimmed.contains('Opening \'') ||
            trimmed.contains('[https @') ||
            trimmed.contains('[mov,') ||
            trimmed.contains('Found duplicated MOOV Atom') ||
            trimmed.contains('[in#0/hls');

        if (isFfmpegInfo) {
          log(key, trimmed);
        } else {
          log(key, '[Error] $trimmed');
        }

        if (trimmed.contains('Initialization fragment found after media fragments')) {
          needsFfmpegFallback = true;
        }
      });

      final exitCode = await proc.exitCode;
      _cleanupDownloadState(vodId);

      // A cancelled download exits non-zero like a failed one. Without this
      // check the ffmpeg fallback below restarted it - after the user cancelled
      // and after its partial files had been deleted - and the restarted run was
      // invisible to the cancel bookkeeping, so it could not be cancelled again.
      // It also reported "Download failed" on top of "Download cancelled".
      if (_cancelledDownloads.remove(vodId)) {
        log(key, '[System] Download cancelled by user.');
        return;
      }

      if (exitCode == 0) {
        log(key, '[System] Download finished successfully.');
        deleteTemporaryDownloadFiles(vodId, channelName, settings.vodDownloadFolder);
        final downloadedFile = getDownloadedVodFile(vodId, channelName, settings.vodDownloadFolder);
        final filePath = downloadedFile?.path ?? '';
        onDownloadCompleted?.call(vodId, vod.title, filePath);
        _cleanupOldestDownloads(settings);
      } else {
        if (!isRetryWithFfmpeg && needsFfmpegFallback && !_shuttingDown) {
          log(key, '[System Warning] HLS fragment error detected. Automatically retrying download using ffmpeg downloader...');
          deleteTemporaryDownloadFiles(vodId, channelName, settings.vodDownloadFolder);
          await Future.delayed(const Duration(seconds: 1));
          await startVodDownload(
            vod,
            channelName,
            settings,
            isRetryWithFfmpeg: true,
            // Carry the fast-download choice into the retry; it used to be
            // dropped, so the retry silently ran the slow post-processing path.
            overrideDisablePostProcessing: overrideDisablePostProcessing,
          );
        } else {
          log(key, '[System Error] Download failed with exit code $exitCode');
          onDownloadFailed?.call(vodId, vod.title, exitCode);
        }
      }
    } catch (e) {
      log(key, '[System Error] Download failed to start: $e');
      _cleanupDownloadState(vodId);
      onDownloadFailed?.call(vodId, vod.title, -1);
    }
  }

  void _cleanupDownloadState(String vodId) {
    activeDownloadProcesses.remove(vodId);
    activeDownloadsProgress.remove(vodId);
    activeDownloadTasks.remove(vodId);
    downloadChannelNames.remove(vodId);
    downloadTitles.remove(vodId);
  }

  final Map<String, bool> downloadTaskFastDownloadOverrides = {};

  void queueVodDownload(TwitchVideo vod, String channelName, AppSettings settings, {bool? overrideDisablePostProcessing}) {
    // Queueing a download means we are not shutting down after all.
    //
    // stopAll() latches _shuttingDown, and it is not only called on exit: the
    // update flow calls it before handing over to the updater. If that handover
    // then fails the app keeps running with the latch stuck on, and every
    // subsequent download - manual or automatic - would sit in the queue
    // forever, showing "Queued" and never starting.
    _shuttingDown = false;
    final vodId = vod.id;
    if (queuedDownloadTasks.containsKey(vodId) || activeDownloadProcesses.containsKey(vodId)) {
      return;
    }

    if (overrideDisablePostProcessing != null) {
      downloadTaskFastDownloadOverrides[vodId] = overrideDisablePostProcessing;
    }

    downloadChannelNames[vodId] = channelName;
    downloadTitles[vodId] = vod.title;
    queuedDownloadTasks[vodId] = vod;
    downloadQueue.add(vodId);
    activeDownloadTasks[vodId] = 'Queued';
    onDownloadProgress?.call(vodId, 0.0, 'Queued');

    _processDownloadQueue(settings, channelName);
  }

  /// Set by [stopAll] so the queue drain stops instead of starting the next
  /// download. Without this, killing the active yt-dlp let the loop below spawn
  /// a fresh one - after the resume list had already been written to disk, and
  /// while the app was shutting down, leaving a stray partial file behind.
  bool _shuttingDown = false;

  Future<void> _processDownloadQueue(AppSettings settings, String channelName) async {
    if (isQueueProcessing) return;
    isQueueProcessing = true;

    while (downloadQueue.isNotEmpty && !_shuttingDown) {
      final vodId = downloadQueue.first;
      final vod = queuedDownloadTasks[vodId];
      final chName = downloadChannelNames[vodId] ?? channelName;
      final overridePostProc = downloadTaskFastDownloadOverrides[vodId];
      if (vod != null) {
        await startVodDownload(vod, chName, settings, overrideDisablePostProcessing: overridePostProc);
      }
      downloadQueue.remove(vodId);
      queuedDownloadTasks.remove(vodId);
      downloadTaskFastDownloadOverrides.remove(vodId);
    }

    isQueueProcessing = false;
  }

  Future<void> cancelVodDownload(String vodId, String channelName, String downloadFolder) async {
    final proc = activeDownloadProcesses[vodId];

    // Only mark when a process actually exists to consume the marker.
    //
    // The exit handler in startVodDownload is the sole consumer. Cancelling a
    // download that is merely QUEUED (a first-class action - the Downloads
    // panel renders a cancel button for the queue) spawns no process, so the
    // marker would linger and then swallow the NEXT successful download of the
    // same VOD: it returns before the exitCode == 0 branch, so the completion
    // callback never fires, the file is never registered, and retention never
    // sees it.
    if (proc != null) {
      _cancelledDownloads.add(vodId);
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

    // Remove the partial output. Anchored matching only: this used to delete
    // anything whose path merely contained " - <vodId>", so cancelling a short
    // id could destroy an unrelated, fully downloaded VOD in the same folder.
    deleteVodFiles(vodId, channelName, downloadFolder);
  }

  void _cleanupOldestDownloads(AppSettings settings) {
    if (settings.maxDownloadsToKeep <= 0) return;
    final downloadFolder = settings.vodDownloadFolder.trim();
    if (downloadFolder.isEmpty) return;

    final mainDir = Directory(downloadFolder);
    if (!mainDir.existsSync()) return;

    final vodIdInName = RegExp(r' - v?(\d+)\.[A-Za-z0-9]+$', caseSensitive: false);

    try {
      final allFiles = <File>[];
      final entities = mainDir.listSync(recursive: true);
      for (final entity in entities) {
        if (entity is! File) continue;
        final name = entity.path;
        // Protect active .part/.ytdl downloads
        if (!vodIdInName.hasMatch(name) || name.endsWith('.part') || name.endsWith('.ytdl')) {
          continue;
        }
        // Never delete a file that is open in a player right now.
        if (playingVodFilePaths.values.any((p) => _isSamePath(p, name))) continue;
        allFiles.add(entity);
      }

      if (allFiles.length <= settings.maxDownloadsToKeep) return;

      allFiles.sort((a, b) {
        try {
          return a.lastModifiedSync().compareTo(b.lastModifiedSync());
        } catch (_) {
          return 0;
        }
      });

      while (allFiles.length > settings.maxDownloadsToKeep) {
        final oldestFile = allFiles.removeAt(0);
        try {
          if (!oldestFile.existsSync()) continue;
          final match = vodIdInName.firstMatch(oldestFile.path);
          oldestFile.deleteSync();
          // Keep yt-dlp's download archive in sync. Leaving a deleted VOD in
          // the archive made a later re-download exit 0 immediately without
          // producing a file, which surfaced as a bogus "Download completed".
          if (match != null) {
            removeVodFromArchive(match.group(1)!);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  static bool _isSamePath(String a, String b) =>
      path.normalize(a).toLowerCase() == path.normalize(b).toLowerCase();

  Future<void> playDownloadedVod(File file, TwitchVideo vod, AppSettings settings) async {
    final path = file.path;
    final args = <String>[];
    String exe = '';

    final finalSeek = resumeSeconds(
      watchPosition: vod.watchPosition,
      watchProgress: vod.watchProgress,
      watchedThreshold: settings.watchedThreshold,
    );

    final port = getNextAvailablePlayerPort();
    final key = vod.id;
    final title = 'Local: ${vod.title}';

    final String effectivePlayerType = resolveEffectivePlayerType(settings);

    final kind = classifyPlayer(effectivePlayerType, settings.customPlayerPath);
    final resolvedExe = resolvePlayerExecutable(effectivePlayerType, settings);

    if (resolvedExe == null) {
      // No usable player: hand the file to the shell as before.
      exe = 'cmd';
      args.addAll(['/c', 'start', '/WAIT', '""', path]);
    } else {
      exe = resolvedExe;
      // Local files are passed straight to Process.start, so no shlex quoting
      // here - unlike the streamlink path, which parses --player-args.
      args.addAll(buildPlayerArgs(
        kind: kind,
        startSeconds: finalSeek,
        port: port,
        ipcName: key,
        isWindows: Platform.isWindows,
      ));
      args.add(path);
    }

    try {
      playingVodIds.add(vod.id);
      // Recorded so retention never deletes the file being watched.
      playingVodFilePaths[vod.id] = file.path;
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
        playingVodFilePaths.remove(vod.id);
        activePlayerProcesses.remove(vod.id);
        activePlayerPorts.remove(vod.id);
        _stopWindowsIpcBridge(key);
        _stopVODProgressTracker(vod.id);
        onPlayerStopped?.call(key, exitCode);
      });
    } catch (e) {
      playingVodIds.remove(vod.id);
      playingVodFilePaths.remove(vod.id);
      activePlayerPorts.remove(vod.id);
      log(key, '[System Error] Failed to launch local player: $e');
      onPlayerStopped?.call(key, -1);
    }
  }

  Future<void> launchStreamlinkForVod(TwitchVideo vod, String channelName, AppSettings settings) async {
    String titleString = '$channelName - ${vod.title}';
    // Resolve "default" to a real player before building arguments.
    final playerType = resolveEffectivePlayerType(settings);
    final kind = classifyPlayer(playerType, settings.customPlayerPath);
    final playerExe = resolvePlayerExecutable(playerType, settings);

    final token = settings.twitchOauthToken.trim().startsWith('oauth:')
        ? settings.twitchOauthToken.trim().substring(6)
        : settings.twitchOauthToken.trim();

    final clientId = settings.twitchClientId.trim().isNotEmpty
        ? settings.twitchClientId.trim()
        : 'kimne78kx3ncx6brgo4mv6wki5h1ko';

    final port = getNextAvailablePlayerPort();
    final key = vod.id;
    final title = 'VOD: ${vod.title}';

    final cmd = buildVodStreamlinkArgs(
      vodId: vod.id,
      titleString: titleString,
      quality: settings.defaultQuality,
      oauthToken: token,
      clientId: clientId,
      kind: kind,
      playerExe: playerExe,
      customPlayerArgs: settings.customPlayerArgs,
      port: port,
      seekableStreaming: settings.seekableVodStreaming,
      resume: resumeSeconds(
        watchPosition: vod.watchPosition,
        watchProgress: vod.watchProgress,
        watchedThreshold: settings.watchedThreshold,
      ),
      isWindows: Platform.isWindows,
    );
    final args = cmd.args;

    playingVodIds.add(vod.id);
    activePlayerPorts[vod.id] = port;
    playerTabTitles[key] = title;

    onPlayerStarted?.call(key, title);
    log(key, '[System] Initializing Streamlink for twitch.tv/videos/${vod.id} ${settings.defaultQuality}...');
    log(key, cmd.passthrough
        ? '[System] Seekable streaming: the player opens the HLS URL itself, so its seek bar works.'
        : '[System] Piping mode: no seek bar. Streamlink skips ahead to ${cmd.appliedStart}s.');
    if (cmd.resumeUnsupported) {
      log(key, '[System] This player has no known start-position flag, so playback begins at 0. '
          'Drag the seek bar to ${vod.watchPosition}s.');
    }
    log(key, '[System] Arguments: ${args.join(" ")}');

    try {
      final proc = await Process.start(
        _getExecutablePath('streamlink'),
        args,
        environment: _getEnvironmentWithBin(),
        runInShell: false,
      );

      activePlayerProcesses[vod.id] = proc;
      
      // Spawn Windows Named Pipe to TCP Bridge for MPV players
      if (kind == PlayerKind.mpv && Platform.isWindows) {
        await _startWindowsIpcBridge(key, port);
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
    final cleanChannel = channelName.toLowerCase().trim();
    if (runningChannels.contains(cleanChannel)) {
      return;
    }
    String titleString = channelName;
    if (isLive) {
      final titleText = streamTitle ?? 'Live Stream';
      final gameText = game ?? 'Twitch';
      titleString = '$channelName - $titleText ($gameText)';
    } else {
      titleString = '$channelName - Offline Stream';
    }

    final args = <String>[];
    // Resolve "default" to a real player before building arguments.
    final playerType = resolveEffectivePlayerType(settings);
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

    // Note: --twitch-low-latency is deprecated/unrecognized in modern Streamlink versions

    if (playerType == 'vlc') {
      args.addAll(['--player', findVlcPath() ?? 'vlc']);
    } else if (playerType == 'mpv') {
      args.addAll(['--player', findMpvPath() ?? 'mpv']);
    } else if (playerType == 'mpc-hc') {
      args.addAll(['--player', findMpcHcPath() ?? 'mpc-hc64']);
    } else if (playerType == 'custom' && settings.customPlayerPath.trim().isNotEmpty) {
      args.addAll(['--player', settings.customPlayerPath.trim()]);
    }

    if (settings.customPlayerArgs.trim().isNotEmpty) {
      args.addAll(['--player-args', settings.customPlayerArgs.trim()]);
    }

    args.add('twitch.tv/$channelName');
    args.add(settings.defaultQuality);

    final key = liveStreamKey(channelName);
    final title = '$channelName (Live)';
    
    runningChannels.add(cleanChannel);
    playerTabTitles[key] = title;

    onPlayerStarted?.call(key, title);
    log(key, '[System] Initializing Streamlink for twitch.tv/$channelName ${settings.defaultQuality}...');
    log(key, '[System] Arguments: ${args.join(" ")}');

    try {
      final proc = await Process.start(
        _getExecutablePath('streamlink'),
        args,
        environment: _getEnvironmentWithBin(),
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
        runningChannels.remove(cleanChannel);
        activePlayerProcesses.remove(key);
        onPlayerStopped?.call(key, exitCode);
      });
    } catch (e) {
      log(key, '[System Error] Failed to run streamlink: $e');
      log(key, '[System Error] Ensure Streamlink is installed and available in your environment.');
      runningChannels.remove(cleanChannel);
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

    // Resolved once, not per tick: this used to call findVlcPath() /
    // findMpvPath() / findMpcHcPath() inside the callback, hitting the
    // filesystem several times every two seconds for the whole playback.
    final resolvedPlayer = resolveEffectivePlayerType(settings);
    final kind = classifyPlayer(resolvedPlayer, settings.customPlayerPath);
    final isVlc = kind == PlayerKind.vlc;
    final isMpv = kind == PlayerKind.mpv;
    final isMpc = kind == PlayerKind.mpcHc;

    final timer = Timer.periodic(const Duration(seconds: 2), (timer) async {

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
              if ((time - lastSynced).abs() >= 1) {
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
              if ((rounded - lastSynced).abs() >= 1) {
                lastSynced = rounded;
                _syncProgress(vod, rounded, webToken);
              }
            }
          }
        } catch (_) {}
      } else if (isMpc) {
        try {
          final response = await http.get(
            Uri.parse('http://127.0.0.1:$port/variables.html'),
          ).timeout(const Duration(seconds: 2));

          if (response.statusCode == 200) {
            final html = response.body;
            final posMatch = RegExp(r'id="position">(\d+)<').firstMatch(html);
            final stateMatch = RegExp(r'id="statestring">([^<]+)<').firstMatch(html);

            final state = stateMatch?.group(1);
            final posMs = posMatch != null ? int.tryParse(posMatch.group(1)!) : null;

            if (state != null && state.toLowerCase().contains('play') && posMs != null && posMs > 0) {
              final seconds = (posMs / 1000).round();
              if ((seconds - lastSynced).abs() >= 1) {
                lastSynced = seconds;
                _syncProgress(vod, seconds, webToken);
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
    // 1. Always update local progress immediately
    final totalSeconds = _apiService.parseDurationToSeconds(vod.duration);
    final progress = totalSeconds > 0 ? position / totalSeconds : 0.0;
    onWatchProgressUpdated?.call(vod.id, position, progress);

    // 2. Sync to Twitch in the background if token exists
    if (webToken.isNotEmpty) {
      try {
        await _apiService.syncSingleVODProgressDirect(vod.id, position, webToken);
      } catch (_) {}
    }
  }

  // Windows Named Pipe to TCP loopback bridge script execution.
  //
  // MPV exposes its JSON IPC on a Windows named pipe, which dart:io cannot open
  // directly, so a small PowerShell relay fronts it with a loopback TCP socket.
  //
  // The relay must serve MANY connections: the progress tracker opens a fresh
  // socket every two seconds and closes it as soon as a reply arrives. The
  // previous script accepted exactly ONE client and exited when either copy
  // completed - which the tracker's own close triggered - so every later poll
  // got connection-refused (swallowed by a bare catch) and the watch position
  // froze at the first sample. Worse, it connected to the pipe BEFORE starting
  // the listener, so the first polls were refused while it waited on MPV.
  Future<void> _startWindowsIpcBridge(String vodId, int port) async {
    final pipeName = 'mpv-socket-$vodId';
    final bridgeScript = '''
      \$ErrorActionPreference = 'Stop'
      try {
        # Listen first, so a poll arriving before MPV has created its pipe is
        # accepted and simply fails fast rather than being refused outright.
        \$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        \$listener.Start()

        while (\$true) {
          \$tcpClient = \$listener.AcceptTcpClient()
          try {
            # A fresh pipe connection per request. MPV's IPC server accepts
            # sequential clients, and this keeps each poll independent: a
            # half-finished exchange cannot wedge the next one.
            \$pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', '$pipeName', [System.IO.Pipes.PipeDirection]::InOut)
            \$pipe.Connect(2000)

            \$tcpStream = \$tcpClient.GetStream()
            \$pTask = \$pipe.CopyToAsync(\$tcpStream)
            \$tTask = \$tcpStream.CopyToAsync(\$pipe)
            [System.Threading.Tasks.Task]::WaitAny(@(\$pTask, \$tTask), 5000)
          } catch {
            # MPV not ready yet, or the client vanished: drop this exchange and
            # keep serving.
          } finally {
            if (\$pipe) { \$pipe.Dispose(); \$pipe = \$null }
            if (\$tcpClient) { \$tcpClient.Close() }
          }
        }
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
    // Download tabs never route here: cancelling a download must go through
    // cancelVodDownload so the _cancelledDownloads marker and partial-file
    // cleanup happen. A raw taskkill on yt-dlp would leave both dangling.
    assert(!key.startsWith('dl-'), 'downloads are cancelled, not killed');

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
    // Stop the queue drain before killing anything, so terminating the active
    // download cannot cause the next queued one to start.
    _shuttingDown = true;
    downloadQueue.clear();
    queuedDownloadTasks.clear();
    downloadTaskFastDownloadOverrides.clear();

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

    playingVodIds.clear();
    playingVodFilePaths.clear();

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
