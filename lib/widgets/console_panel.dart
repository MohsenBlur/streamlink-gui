import 'dart:io';
import 'package:flutter/material.dart';
import '../models/twitch_video.dart';
import 'horizontal_mouse_scrollable.dart';

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

  void _scrollToBottom(String key) {
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

    return Container(
      height: widget.consoleCollapsed ? 38 : 220,
      decoration: const BoxDecoration(
        color: Color(0xFF07090E),
        border: Border(top: BorderSide(color: Color(0xFF1E2433), width: 1.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Console Header
          Container(
            height: 36,
            color: const Color(0xFF111420),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    widget.consoleCollapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 18,
                    color: Colors.white70,
                  ),
                  onPressed: widget.onToggleCollapse,
                  tooltip: widget.consoleCollapsed ? 'Expand Console' : 'Collapse Console',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 16,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Terminal Console',
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                  ),
                ),
                if (widget.consoleCollapsed) ...[
                  if (widget.activeDownloadTasks.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.greenAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.greenAccent.withOpacity(0.5),
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
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF1A1F31) : const Color(0xFF0D0F16),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: isSelected ? Colors.greenAccent.withOpacity(0.4) : const Color(0xFF1E2433),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.download, size: 12, color: isTabRunning ? Colors.greenAccent : Colors.white60),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Downloads Manager',
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        color: isSelected ? Colors.white : Colors.white60,
                                      ),
                                    ),
                                    if (isTabRunning) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: Colors.greenAccent,
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
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF1A1F31) : const Color(0xFF0D0F16),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: isSelected ? theme.primaryColor.withOpacity(0.5) : const Color(0xFF1E2433),
                                    width: 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      icon,
                                      size: 12,
                                      color: isRunning ? theme.primaryColor : Colors.white38,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      title,
                                      style: TextStyle(
                                        fontFamily: 'Consolas',
                                        fontSize: 11,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        color: isSelected ? Colors.white : Colors.white60,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    InkWell(
                                      onTap: () {
                                        widget.onCloseTab(key);
                                      },
                                      borderRadius: BorderRadius.circular(10),
                                      child: const Icon(
                                        Icons.close,
                                        size: 12,
                                        color: Colors.white30,
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
                        foregroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.stop, size: 14),
                      label: const Text('Kill Process', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      onPressed: () => widget.onKillProcess(activeKey),
                    ),
                  ),
                ],
                if (activeKey != '__downloads_manager__') ...[
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 14, color: Colors.white30),
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
                              Color logColor = const Color(0xFFCBD5E1);
                              if (log.contains('[Error]') || log.contains('[Streamlink Err]') || log.contains('error:') || log.contains('failed')) {
                                logColor = const Color(0xFFF43F5E);
                              } else if (log.startsWith('[System]')) {
                                logColor = const Color(0xFF38BDF8);
                              } else if (log.startsWith('[Streamlink]')) {
                                logColor = theme.primaryColor;
                              } else if (log.contains('[cli][info]') || log.contains('Available streams:')) {
                                logColor = const Color(0xFF10B981);
                              } else if (log.contains('[Download]')) {
                                logColor = const Color(0xFF34D399);
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
    final activeKeys = widget.activeDownloadTasks.keys.toList();
    final queuedKeys = widget.downloadQueue;

    if (activeKeys.isEmpty && queuedKeys.isEmpty) {
      return const Center(
        child: Text(
          'No active or queued downloads.',
          style: TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Colors.white38),
        ),
      );
    }

    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (activeKeys.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Active Downloads',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.greenAccent, fontFamily: 'Consolas'),
              ),
            ),
            ...activeKeys.map((vodId) {
              final progress = widget.activeDownloadsProgress[vodId] ?? 0.0;
              final taskText = widget.activeDownloadTasks[vodId] ?? 'Downloading...';
              final title = widget.downloadTitles[vodId] ?? 'VOD $vodId';

              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F131E),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white, fontFamily: 'Consolas'),
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
                                    backgroundColor: Colors.white10,
                                    valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor),
                                    minHeight: 4,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                taskText,
                                style: const TextStyle(fontSize: 11, color: Colors.white60, fontFamily: 'Consolas'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent, width: 1),
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
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Queue List',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent, fontFamily: 'Consolas'),
              ),
            ),
            ...queuedKeys.map((vodId) {
              final title = widget.downloadTitles[vodId] ?? 'VOD $vodId';

              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F131E),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontSize: 12, color: Colors.white70, fontFamily: 'Consolas'),
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
                      child: const Text(
                        'Queued',
                        style: TextStyle(fontSize: 10, color: Colors.amberAccent, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      icon: const Icon(Icons.cancel_outlined, size: 16, color: Colors.redAccent),
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
