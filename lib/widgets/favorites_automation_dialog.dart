import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_checkbox.dart';
import '../main.dart';

class _ChannelAutomationState {
  final TwitchChannel originalChannel;
  bool autoPlayLive;
  int autoPlayPriority;
  bool autoDownloadVods;
  int maxVodKeepCount;
  bool stopAtLastWatchedVod;

  _ChannelAutomationState({
    required this.originalChannel,
    required this.autoPlayLive,
    required this.autoPlayPriority,
    required this.autoDownloadVods,
    required this.maxVodKeepCount,
    required this.stopAtLastWatchedVod,
  });

  factory _ChannelAutomationState.fromChannel(TwitchChannel ch) {
    return _ChannelAutomationState(
      originalChannel: ch,
      autoPlayLive: ch.autoPlayLive,
      autoPlayPriority: ch.autoPlayPriority,
      autoDownloadVods: ch.autoDownloadVods,
      maxVodKeepCount: ch.maxVodKeepCount,
      stopAtLastWatchedVod: ch.stopAtLastWatchedVod,
    );
  }

  void applyToOriginal() {
    originalChannel.autoPlayLive = autoPlayLive;
    originalChannel.autoPlayPriority = autoPlayPriority;
    originalChannel.autoDownloadVods = autoDownloadVods;
    originalChannel.maxVodKeepCount = maxVodKeepCount;
    originalChannel.stopAtLastWatchedVod = stopAtLastWatchedVod;
  }
}

class FavoritesAutomationDialog extends StatefulWidget {
  final List<TwitchChannel> favorites;
  final AppSettings settings;
  final VoidCallback onSettingsSaved;

  const FavoritesAutomationDialog({
    Key? key,
    required this.favorites,
    required this.settings,
    required this.onSettingsSaved,
  }) : super(key: key);

  @override
  State<FavoritesAutomationDialog> createState() => _FavoritesAutomationDialogState();
}

class _FavoritesAutomationDialogState extends State<FavoritesAutomationDialog> {
  late int _threshold;
  late List<_ChannelAutomationState> _favChannels;

  @override
  void initState() {
    super.initState();
    _threshold = widget.settings.vodWatchExclusionThreshold;
    _favChannels = widget.favorites.map((ch) => _ChannelAutomationState.fromChannel(ch)).toList();
    _sortPriorityList();
  }

  void _sortPriorityList() {
    _favChannels.sort((a, b) {
      if (a.autoPlayLive && b.autoPlayLive) {
        return a.autoPlayPriority.compareTo(b.autoPlayPriority);
      } else if (a.autoPlayLive) {
        return -1;
      } else if (b.autoPlayLive) {
        return 1;
      }
      return a.originalChannel.username.toLowerCase().compareTo(b.originalChannel.username.toLowerCase());
    });
  }

  void _updatePriorities() {
    int currentPriority = 0;
    for (var ch in _favChannels) {
      if (ch.autoPlayLive) {
        ch.autoPlayPriority = currentPriority++;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final priorityChannels = _favChannels.where((c) => c.autoPlayLive).toList();

    return Dialog(
      backgroundColor: themeNotifier.backgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.primaryColor.withOpacity(0.4), width: 1.5),
      ),
      child: Container(
        width: 720,
        height: 650,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title Header
            Row(
              children: [
                Stack(
                  alignment: Alignment.bottomRight,
                  children: [
                    Icon(Icons.play_arrow, color: theme.primaryColor, size: 28),
                    const Icon(Icons.star, color: Colors.amber, size: 14),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Auto Download & Play Manager',
                    style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 20),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                  onPressed: () {
                    // Close without applying changes
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(color: NeuTheme.border(themeNotifier.isDarkTheme)),
            const SizedBox(height: 12),

            // Threshold Setting Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 12),
              child: Row(
                children: [
                  Icon(Icons.tune, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'VOD Exclusion Threshold',
                          style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13),
                        ),
                        Text(
                          'Excludes VODs from auto-download if watch progress exceeds this limit',
                          style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _threshold.toDouble(),
                            min: 5,
                            max: 90,
                            divisions: 17,
                            activeColor: theme.primaryColor,
                            label: '$_threshold%',
                            onChanged: (val) {
                              setState(() {
                                _threshold = val.toInt();
                              });
                            },
                          ),
                        ),
                        Text(
                          '$_threshold%',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: theme.primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Preempt Switch Toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: themeNotifier.surfaceColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Preempt Lower Priority Streams',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'If a lower priority stream is playing and a higher priority channel goes live, switch automatically.',
                          style: TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: widget.settings.autoPlayPreemptLowerPriority,
                    activeColor: theme.primaryColor,
                    onChanged: (val) {
                      setState(() {
                        widget.settings.autoPlayPreemptLowerPriority = val;
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Content List
            Expanded(
              child: _favChannels.isEmpty
                  ? const Center(
                      child: Text(
                        'No Favorite channels added yet.',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : ListView(
                      children: [
                        if (priorityChannels.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Priority Live Auto-Play Order (Drag to Reorder)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.amberAccent,
                              ),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: themeNotifier.surfaceColor,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.amber.withOpacity(0.3)),
                            ),
                            child: ReorderableListView(
                              shrinkWrap: true,
                              buildDefaultDragHandles: false,
                              physics: const NeverScrollableScrollPhysics(),
                              proxyDecorator: (Widget child, int index, Animation<double> animation) {
                                return AnimatedBuilder(
                                  animation: animation,
                                  builder: (BuildContext context, Widget? child) {
                                    return Material(
                                      elevation: 8,
                                      color: themeNotifier.surfaceColor,
                                      borderRadius: BorderRadius.circular(8),
                                      shadowColor: Colors.black.withOpacity(0.5),
                                      child: child,
                                    );
                                  },
                                  child: child,
                                );
                              },
                              onReorder: (oldIndex, newIndex) {
                                setState(() {
                                  if (newIndex > oldIndex) newIndex -= 1;
                                  final item = priorityChannels.removeAt(oldIndex);
                                  priorityChannels.insert(newIndex, item);
                                  for (int i = 0; i < priorityChannels.length; i++) {
                                    priorityChannels[i].autoPlayPriority = i;
                                  }
                                  _favChannels.removeWhere((c) => c.autoPlayLive);
                                  _favChannels.insertAll(0, priorityChannels);
                                });
                              },
                              children: priorityChannels.asMap().entries.map((entry) {
                                final index = entry.key;
                                final ch = entry.value;
                                return Container(
                                  key: ValueKey('priority_${ch.originalChannel.username}'),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    border: Border(bottom: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme), width: 0.5)),
                                  ),
                                  child: Row(
                                    children: [
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.grab,
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            child: Icon(Icons.drag_handle, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      if (ch.originalChannel.avatarUrl != null)
                                        CircleAvatar(
                                          radius: 14,
                                          backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                          backgroundImage: NetworkImage(ch.originalChannel.avatarUrl!),
                                        )
                                      else
                                        CircleAvatar(
                                          radius: 14,
                                          backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                          child: Icon(Icons.person, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                        ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          ch.originalChannel.username,
                                          style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: theme.primaryColor.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: theme.primaryColor, width: 1),
                                        ),
                                        child: Text(
                                          'Priority #${priorityChannels.indexOf(ch) + 1}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: theme.primaryColor,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],

                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'All Favorite Channels Controls',
                            style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 13),
                          ),
                        ),

                        ..._favChannels.map((ch) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(12),
                            decoration: NeuTheme.raisedDecoration(
                              themeNotifier.isDarkTheme,
                              radius: 12,
                              border: Border.all(
                                color: (ch.autoPlayLive || ch.autoDownloadVods)
                                    ? theme.primaryColor.withOpacity(0.4)
                                    : NeuTheme.border(themeNotifier.isDarkTheme),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (ch.originalChannel.avatarUrl != null)
                                      CircleAvatar(
                                        radius: 16,
                                        backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                        backgroundImage: NetworkImage(ch.originalChannel.avatarUrl!),
                                      )
                                    else
                                      CircleAvatar(
                                        radius: 16,
                                        backgroundColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                        child: Icon(Icons.person, size: 16, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                      ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        ch.originalChannel.username,
                                        style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 14),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 16,
                                  runSpacing: 10,
                                  children: [
                                    // Auto Play Checkbox
                                    InkWell(
                                      onTap: () {
                                        setState(() {
                                          ch.autoPlayLive = !ch.autoPlayLive;
                                          _sortPriorityList();
                                          _updatePriorities();
                                        });
                                      },
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          NeuCheckbox(
                                            value: ch.autoPlayLive,
                                            activeColor: theme.primaryColor,
                                            isDark: themeNotifier.isDarkTheme,
                                            onChanged: (val) {
                                              setState(() {
                                                ch.autoPlayLive = val ?? false;
                                                _sortPriorityList();
                                                _updatePriorities();
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Auto Play When Live',
                                            style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),

                                    // Auto Download Checkbox
                                    InkWell(
                                      onTap: () {
                                        setState(() {
                                          ch.autoDownloadVods = !ch.autoDownloadVods;
                                        });
                                      },
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          NeuCheckbox(
                                            value: ch.autoDownloadVods,
                                            activeColor: theme.primaryColor,
                                            isDark: themeNotifier.isDarkTheme,
                                            onChanged: (val) {
                                              setState(() {
                                                ch.autoDownloadVods = val ?? false;
                                              });
                                            },
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Auto Download VODs',
                                            style: NeuTheme.bodyStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),

                                    if (ch.autoDownloadVods) ...[
                                      // Max VOD Keep Count Dropdown
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'Keep Max VODs: ',
                                            style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                          ),
                                          DropdownButton<int>(
                                            value: ch.maxVodKeepCount.clamp(1, 5),
                                            dropdownColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                            style: TextStyle(color: theme.primaryColor, fontWeight: FontWeight.bold),
                                            items: [1, 2, 3, 4, 5].map((val) {
                                              return DropdownMenuItem<int>(
                                                value: val,
                                                child: Text('$val'),
                                              );
                                            }).toList(),
                                            onChanged: (val) {
                                              if (val != null) {
                                                setState(() {
                                                  ch.maxVodKeepCount = val;
                                                });
                                              }
                                            },
                                          ),
                                        ],
                                      ),

                                      // Stop at Last Watched (> 5%) Checkbox
                                      InkWell(
                                        onTap: () {
                                          setState(() {
                                            ch.stopAtLastWatchedVod = !ch.stopAtLastWatchedVod;
                                          });
                                        },
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            NeuCheckbox(
                                              value: ch.stopAtLastWatchedVod,
                                              activeColor: theme.primaryColor,
                                              isDark: themeNotifier.isDarkTheme,
                                              onChanged: (val) {
                                                setState(() {
                                                  ch.stopAtLastWatchedVod = val ?? true;
                                                });
                                              },
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Stop at last watched (> 5%)',
                                              style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ),
            ),

            const SizedBox(height: 16),
            Divider(color: NeuTheme.border(themeNotifier.isDarkTheme)),
            const SizedBox(height: 12),

            // Save & Close Button
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.primaryColor,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.check, color: Colors.white, size: 18),
                label: const Text(
                  'Save & Apply',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                ),
                onPressed: () {
                  widget.settings.vodWatchExclusionThreshold = _threshold;
                  _updatePriorities();
                  for (final st in _favChannels) {
                    st.applyToOriginal();
                  }
                  widget.onSettingsSaved();
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
