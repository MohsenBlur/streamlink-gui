import 'package:flutter/material.dart';
import '../models/twitch_video.dart';
import '../state/download_view_state.dart';
import 'horizontal_mouse_scrollable.dart';
import '../theme/neu_theme.dart';
import '../theme/theme_notifier.dart';

class LogNotifier extends ChangeNotifier {
  final Map<String, List<String>> _logs = {};
  
  List<String> getLogs(String key) => _logs[key] ?? [];
  
  void appendLog(String key, String line) {
    final list = _logs.putIfAbsent(key, () => []);
    list.add(line);
    // Buffer limit: max 1000 lines to prevent memory leaks
    if (list.length > 1000) {
      list.removeRange(0, list.length - 1000);
    }
    notifyListeners();
  }
  
  void clear(String key) {
    _logs[key]?.clear();
    notifyListeners();
  }
  
  void removeKey(String key) {
    _logs.remove(key);
    notifyListeners();
  }
}

class ConsolePanel extends StatefulWidget {
  final LogNotifier logNotifier;
  final Map<String, String> playerTabTitles;
  final Set<String> playingVodIds;
  final Set<String> runningChannels;
  final String? selectedConsoleTabKey;
  final bool consoleCollapsed;
  final ValueChanged<String?> onTabSelected;
  final VoidCallback onToggleCollapse;
  final ValueChanged<String> onKillProcess;
  final ValueChanged<String> onCloseTab;

  // Active/queued downloads state
  final Map<String, double> activeDownloadsProgress;
  final Map<String, String> activeDownloadTasks;
  final List<String> downloadQueue;
  final Map<String, TwitchVideo> queuedDownloadTasks;
  final Map<String, String> downloadTitles;

  /// Ids with a live yt-dlp process; the single source of truth that
  /// separates "Active Downloads" from "Queue List".
  final Set<String> activeProcessIds;
  final ValueChanged<String> onCancelDownload;

  const ConsolePanel({
    Key? key,
    required this.logNotifier,
    required this.playerTabTitles,
    required this.playingVodIds,
    required this.runningChannels,
    required this.selectedConsoleTabKey,
    required this.consoleCollapsed,
    required this.onTabSelected,
    required this.onToggleCollapse,
    required this.onKillProcess,
    required this.onCloseTab,
    required this.activeDownloadsProgress,
    required this.activeDownloadTasks,
    required this.downloadQueue,
    required this.queuedDownloadTasks,
    required this.downloadTitles,
    required this.activeProcessIds,
    required this.onCancelDownload,
  }) : super(key: key);

  @override
  State<ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<ConsolePanel> {
  final Map<String, ScrollController> _scrollControllers = {};
  bool _hasUnreadLogs = false;

  @override
  void initState() {
    super.initState();
    widget.logNotifier.addListener(_onLogUpdated);
  }

  @override
  void didUpdateWidget(ConsolePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.logNotifier != widget.logNotifier) {
      oldWidget.logNotifier.removeListener(_onLogUpdated);
      widget.logNotifier.addListener(_onLogUpdated);
    }
    if (!widget.consoleCollapsed) {
      _hasUnreadLogs = false;
    }
    _pruneScrollControllers();
  }

  @override
  void dispose() {
    widget.logNotifier.removeListener(_onLogUpdated);
    for (final ctrl in _scrollControllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _onLogUpdated() {
    if (widget.consoleCollapsed && !_hasUnreadLogs) {
      if (mounted) {
        setState(() {
          _hasUnreadLogs = true;
        });
      }
    }
  }

  ScrollController _getScrollController(String key) {
    return _scrollControllers.putIfAbsent(key, () => ScrollController());
  }

  /// The tab the last frame rendered; switching tabs re-pins to the bottom.
  String? _lastScrolledKey;

  void _scrollToBottom(String key) {
    final controller = _scrollControllers[key];
    final switchedTab = _lastScrolledKey != key;
    _lastScrolledKey = key;

    // The extent read here is last frame's layout - i.e. the pin state from
    // BEFORE the incoming log lines. Only follow the tail when the user was
    // already near it (or just switched tabs); a reader scrolled up stays put.
    final wasPinned = controller == null ||
        !controller.hasClients ||
        controller.position.maxScrollExtent - controller.offset < 80;
    if (!switchedTab && !wasPinned) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _scrollControllers[key];
      if (controller != null && controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Drops ScrollControllers for tabs that no longer exist. Runs post-frame
  /// because the closing tab's ListView may still be attached this frame.
  void _pruneScrollControllers() {
    final stale = _scrollControllers.keys
        .where((k) =>
            k != '__downloads_manager__' &&
            !widget.playerTabTitles.containsKey(k))
        .toList();
    if (stale.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final k in stale) {
        if (!widget.playerTabTitles.containsKey(k) &&
            k != '__downloads_manager__') {
          _scrollControllers.remove(k)?.dispose();
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeKey = widget.selectedConsoleTabKey;
    if (activeKey == null || (!widget.playerTabTitles.containsKey(activeKey) && activeKey != '__downloads_manager__')) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final activeController = _getScrollController(activeKey);
    final isPlayerRunning = activeKey != '__downloads_manager__' &&
                            (widget.playingVodIds.contains(activeKey) || 
                             widget.runningChannels.contains(activeKey.replaceFirst('stream_', '')));

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.fastOutSlowIn,
      height: widget.consoleCollapsed ? 38 : 220,
      decoration: BoxDecoration(
        color: themeNotifier.backgroundColor,
        boxShadow: [
          BoxShadow(
            color: NeuTheme.shadow(themeNotifier.isDarkTheme).withOpacity(0.5),
            offset: const Offset(0, -3),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Console Header
          Container(
            height: 36,
            color: themeNotifier.surfaceColor,
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    widget.consoleCollapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: NeuTheme.text(themeNotifier.isDarkTheme),
                  ),
                  onPressed: widget.onToggleCollapse,
                  tooltip: widget.consoleCollapsed ? 'Expand Console' : 'Collapse Console',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Terminal Console',
                  style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 12),
                ),
                if (widget.consoleCollapsed) ...[
                  if (widget.activeDownloadTasks.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: NeuTheme.live,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: NeuTheme.live.withOpacity(0.5),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ] else if (_hasUnreadLogs) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: theme.primaryColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: theme.primaryColor.withOpacity(0.5),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
                const SizedBox(width: 16),
                
                // Tabs List
                Expanded(
                  child: HorizontalMouseScrollable(
                    child: Row(
                      children: [
                        // Downloads Manager Tab
                        (() {
                          final isSelected = activeKey == '__downloads_manager__';
                          final isTabRunning = widget.activeDownloadsProgress.isNotEmpty;
                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () {
                                widget.onTabSelected('__downloads_manager__');
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                decoration: isSelected
                                    ? NeuTheme.sunkenDecoration(
                                        themeNotifier.isDarkTheme,
                                        radius: 6,
                                        border: Border.all(color: NeuTheme.live.withOpacity(0.6), width: 1.5),
                                      )
                                    : NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 6),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.download, size: 12, color: isTabRunning ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Downloads Manager',
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        color: isSelected ? theme.primaryColor : NeuTheme.text(themeNotifier.isDarkTheme),
                                      ),
                                    ),
                                    if (isTabRunning) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: NeuTheme.live,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          );
                        })(),

                        // Running / Logged Processes Tabs
                        ...widget.playerTabTitles.keys.map((key) {
                          final title = widget.playerTabTitles[key] ?? key;
                          final isSelected = activeKey == key;
                          final isRunning = widget.playingVodIds.contains(key) ||
                                            widget.runningChannels.contains(key.replaceFirst('stream_', ''));
                          final icon = key.startsWith('stream_') ? Icons.live_tv : Icons.play_circle_outline;

                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () {
                                widget.onTabSelected(key);
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                decoration: isSelected
                                    ? NeuTheme.sunkenDecoration(
                                        themeNotifier.isDarkTheme,
                                        radius: 6,
                                        border: Border.all(color: theme.primaryColor, width: 1.5),
                                      )
                                    : NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 6),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      icon,
                                      size: 12,
                                      color: isRunning ? theme.primaryColor : NeuTheme.subtext(themeNotifier.isDarkTheme),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      title,
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        color: isSelected ? theme.primaryColor : NeuTheme.text(themeNotifier.isDarkTheme),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    InkWell(
                                      onTap: () {
                                        widget.onCloseTab(key);
                                      },
                                      borderRadius: BorderRadius.circular(10),
                                      child: Icon(
                                        Icons.close,
                                        size: 12,
                                        color: NeuTheme.disabledText(themeNotifier.isDarkTheme),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  ),
                ),
                
                if (isPlayerRunning) ...[
                  SizedBox(
                    height: 26,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: NeuTheme.dangerText(themeNotifier.isDarkTheme),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.stop, size: 14),
                      label: const Text('Kill Process', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      onPressed: () => widget.onKillProcess(activeKey),
                    ),
                  ),
                ],
                if (activeKey.startsWith('dl-') &&
                    (widget.activeProcessIds.contains(activeKey.substring(3)) ||
                        widget.downloadQueue.contains(activeKey.substring(3)) ||
                        widget.activeDownloadTasks.containsKey(activeKey.substring(3)))) ...[
                  SizedBox(
                    height: 26,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: NeuTheme.dangerText(themeNotifier.isDarkTheme),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.cancel_outlined, size: 14),
                      label: const Text('Cancel Download', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      onPressed: () => widget.onCancelDownload(activeKey.substring(3)),
                    ),
                  ),
                ],
                if (activeKey != '__downloads_manager__') ...[
                  IconButton(
                    icon: Icon(Icons.delete_outline, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                    onPressed: () {
                      widget.logNotifier.clear(activeKey);
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    splashRadius: 16,
                    tooltip: 'Clear Console logs',
                  ),
                ],
                const SizedBox(width: 12),
              ],
            ),
          ),
          
          // Console Content / Downloads Manager Content
          if (!widget.consoleCollapsed)
            Expanded(
              child: activeKey == '__downloads_manager__'
                  ? _buildDownloadsManagerView()
                  : SelectionArea(
                      child: ListenableBuilder(
                        listenable: widget.logNotifier,
                        builder: (context, _) {
                          final activeLogs = widget.logNotifier.getLogs(activeKey);
                          _scrollToBottom(activeKey);
                          
                          return ListView.builder(
                            controller: activeController,
                            padding: const EdgeInsets.all(12),
                            itemCount: activeLogs.length,
                            itemBuilder: (context, index) {
                              final log = activeLogs[index];
                              Color logColor = NeuTheme.text(themeNotifier.isDarkTheme);
                              final logIsDark = themeNotifier.isDarkTheme;
                              if (log.contains('[Error]') || log.contains('[Streamlink Err]') || log.contains('error:') || log.contains('failed')) {
                                logColor = NeuTheme.dangerText(logIsDark);
                              } else if (log.startsWith('[System]')) {
                                logColor = logIsDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1);
                              } else if (log.startsWith('[Streamlink]')) {
                                logColor = theme.primaryColor;
                              } else if (log.contains('[cli][info]') || log.contains('Available streams:')) {
                                logColor = logIsDark ? const Color(0xFF10B981) : const Color(0xFF047857);
                              } else if (log.contains('[Download]')) {
                                logColor = NeuTheme.liveText(logIsDark);
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
                          );
                        },
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildDownloadsManagerView() {
    final split = splitDownloadIds(
      taskIds: widget.activeDownloadTasks.keys,
      queueIds: widget.downloadQueue,
      startedIds: widget.activeProcessIds,
    );
    final activeKeys = split.active;
    final queuedKeys = split.queued;

    if (activeKeys.isEmpty && queuedKeys.isEmpty) {
      return Center(
        child: Text(
          'No active or queued downloads.',
          style: TextStyle(fontFamily: 'Consolas', fontSize: 12, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
        ),
      );
    }

    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (activeKeys.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Active Downloads',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: NeuTheme.liveText(themeNotifier.isDarkTheme), fontFamily: 'Consolas'),
              ),
            ),
            ...activeKeys.map((vodId) {
              final progress = widget.activeDownloadsProgress[vodId] ?? 0.0;
              final taskText = widget.activeDownloadTasks[vodId] ?? 'Downloading...';
              final title = widget.downloadTitles[vodId] ?? 'VOD $vodId';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: NeuTheme.text(themeNotifier.isDarkTheme), fontFamily: 'Consolas'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(2),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: NeuTheme.border(themeNotifier.isDarkTheme),
                                    valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor),
                                    minHeight: 4,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                taskText,
                                style: TextStyle(fontSize: 11, color: NeuTheme.subtext(themeNotifier.isDarkTheme), fontFamily: 'Consolas'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: NeuTheme.dangerText(themeNotifier.isDarkTheme),
                        side: BorderSide(color: NeuTheme.dangerText(themeNotifier.isDarkTheme), width: 1),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        minimumSize: Size.zero,
                      ),
                      onPressed: () => widget.onCancelDownload(vodId),
                      icon: const Icon(Icons.cancel_outlined, size: 14),
                      label: const Text('Cancel', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              );
            }).toList(),
          ],
          if (queuedKeys.isNotEmpty) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Queue List',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: themeNotifier.isDarkTheme ? Colors.amberAccent : Colors.amber.shade800, fontFamily: 'Consolas'),
              ),
            ),
            ...queuedKeys.map((vodId) {
              final title = widget.downloadTitles[vodId] ?? 'VOD $vodId';

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(fontSize: 12, color: NeuTheme.text(themeNotifier.isDarkTheme), fontFamily: 'Consolas'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Queued',
                        style: TextStyle(fontSize: 10, color: themeNotifier.isDarkTheme ? Colors.amberAccent : Colors.amber.shade800, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      icon: Icon(Icons.cancel_outlined, size: 16, color: NeuTheme.dangerText(themeNotifier.isDarkTheme)),
                      onPressed: () => widget.onCancelDownload(vodId),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Cancel queue',
                    ),
                  ],
                ),
              );
            }).toList(),
          ],
        ],
      ),
    );
  }
}
