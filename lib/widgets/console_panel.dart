import 'dart:io';
import 'package:flutter/material.dart';

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
  }) : super(key: key);

  @override
  State<ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<ConsolePanel> {
  final Map<String, ScrollController> _scrollControllers = {};

  @override
  void dispose() {
    for (final ctrl in _scrollControllers.values) {
      ctrl.dispose();
    }
    super.dispose();
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
    if (activeKey == null || !widget.playerTabTitles.containsKey(activeKey)) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final activeController = _getScrollController(activeKey);
    final isPlayerRunning = widget.playingVodIds.contains(activeKey) || 
                            widget.runningChannels.contains(activeKey.replaceFirst('stream_', ''));

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
                const SizedBox(width: 16),
                
                // Tabs List
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: widget.playerTabTitles.keys.map((key) {
                      final isSelected = key == activeKey;
                      final isTabRunning = widget.playingVodIds.contains(key) || 
                                           widget.runningChannels.contains(key.replaceFirst('stream_', ''));
                      final title = widget.playerTabTitles[key] ?? key;
                      
                      return GestureDetector(
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
                              color: isSelected ? Colors.greenAccent.withOpacity(0.4) : const Color(0xFF1E2433),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: isTabRunning ? Colors.greenAccent : Colors.redAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                title.length > 25 ? '${title.substring(0, 22)}...' : title,
                                style: TextStyle(
                                  fontFamily: 'Consolas',
                                  fontSize: 11,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? Colors.white : Colors.white60,
                                ),
                              ),
                              const SizedBox(width: 6),
                              GestureDetector(
                                onTap: () {
                                  widget.onCloseTab(key);
                                },
                                child: const Icon(Icons.close, size: 10, color: Colors.white38),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
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
                const SizedBox(width: 12),
              ],
            ),
          ),
          
          // Console Log Lines List
          if (!widget.consoleCollapsed)
            Expanded(
              child: SelectionArea(
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
                        Color logColor = Colors.white70;
                        if (log.startsWith('[System Error]') || log.startsWith('[Streamlink Err]') || log.startsWith('[Streamlink ERR]')) {
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
