import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../theme/neu_theme.dart';
import 'shell/engraved_rule.dart';
import '../theme/neu_material_themes.dart';
import 'neumorphic/neu_avatar.dart';
import 'neumorphic/neu_checkbox.dart';
import 'neumorphic/neu_switch.dart';
import '../theme/theme_notifier.dart';
import 'shell/neu_dialog.dart';

class _ChannelAutomationState {
  final TwitchChannel originalChannel;
  bool autoPlayLive;
  int autoPlayPriority;
  bool autoDownloadVods;
  int maxVodKeepCount;
  bool stopAtLastWatchedVod;
  bool autoDownloadFastDownload;

  _ChannelAutomationState({
    required this.originalChannel,
    required this.autoPlayLive,
    required this.autoPlayPriority,
    required this.autoDownloadVods,
    required this.maxVodKeepCount,
    required this.stopAtLastWatchedVod,
    required this.autoDownloadFastDownload,
  });

  factory _ChannelAutomationState.fromChannel(TwitchChannel ch) {
    return _ChannelAutomationState(
      originalChannel: ch,
      autoPlayLive: ch.autoPlayLive,
      autoPlayPriority: ch.autoPlayPriority,
      autoDownloadVods: ch.autoDownloadVods,
      maxVodKeepCount: ch.maxVodKeepCount,
      stopAtLastWatchedVod: ch.stopAtLastWatchedVod,
      autoDownloadFastDownload: ch.autoDownloadFastDownload,
    );
  }

  void applyToOriginal() {
    originalChannel.autoPlayLive = autoPlayLive;
    originalChannel.autoPlayPriority = autoPlayPriority;
    originalChannel.autoDownloadVods = autoDownloadVods;
    originalChannel.maxVodKeepCount = maxVodKeepCount;
    originalChannel.stopAtLastWatchedVod = stopAtLastWatchedVod;
    originalChannel.autoDownloadFastDownload = autoDownloadFastDownload;
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
  late bool _preemptLowerPriority;
  late List<_ChannelAutomationState> _favChannels;

  @override
  void initState() {
    super.initState();
    _threshold = widget.settings.vodWatchExclusionThreshold;
    // Staged, like the threshold and every per-channel switch. This one wrote
    // straight to the live settings, so it took effect immediately and stuck
    // even when the dialog was closed with the X - whose handler is commented
    // "Close without applying changes".
    _preemptLowerPriority = widget.settings.autoPlayPreemptLowerPriority;
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

    // This was the one dialog painted on `backgroundColor` rather than
    // `surfaceColor`, so it was visibly a different colour from its siblings.
    return NeuDialog(
      title: 'Automation',
      subtitle: 'What happens on its own when a favourite goes live',
      icon: Icons.play_circle_outline,
      width: 760,
      maxHeight: 680,
      scrollable: false,
      content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Threshold Setting Bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s12),
              decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r12),
              child: Row(
                children: [
                  Icon(Icons.tune, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                  const SizedBox(width: NeuSpace.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Skip VODs already watched past',
                          style: NeuType.headingSm(themeNotifier.isDarkTheme),
                        ),
                        Text(
                          'Auto-download leaves these alone.',
                          style: NeuType.caption(themeNotifier.isDarkTheme),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: Row(
                      children: [
                        Expanded(
                          child: SliderTheme(
                            data: neuSliderTheme(context,
                                accent: theme.primaryColor),
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
                        ),
                        Text(
                          '$_threshold%',
                          style: NeuType.headingSm(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: NeuSpace.s12),

            // Preempt Switch Toggle
            Container(
              padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
              decoration: BoxDecoration(
                color: themeNotifier.surfaceColor,
                borderRadius: BorderRadius.circular(NeuRadius.r12),
                border: Border.all(color: NeuTheme.border(themeNotifier.isDarkTheme)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Switch to a higher priority channel',
                          style: NeuType.headingSm(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                        ),
                        const SizedBox(height: NeuSpace.s2),
                        Text(
                          'When one goes live while a lower-priority stream is playing.',
                          style: NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                        ),
                      ],
                    ),
                  ),
                  NeuSwitch(
                    value: _preemptLowerPriority,
                    activeColor: theme.primaryColor,
                    onChanged: (val) {
                      setState(() {
                        _preemptLowerPriority = val;
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: NeuSpace.s16),

            // Content List
            Expanded(
              child: _favChannels.isEmpty
                  ? Center(
                      child: Text(
                        'No favourites yet. Star a channel to automate it.',
                        style: TextStyle(color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                      ),
                    )
                  : ListView(
                      padding: NeuShadowRoom.list,
                      children: [
                        if (priorityChannels.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.only(bottom: NeuSpace.s8),
                            child: Text(
                              'Auto-play order - drag to reorder',
                              style: NeuType.headingSm(themeNotifier.isDarkTheme, color: NeuTheme.favoriteText(themeNotifier.isDarkTheme)),
                            ),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: themeNotifier.surfaceColor,
                              borderRadius: BorderRadius.circular(NeuRadius.r12),
                              border: Border.all(color: NeuTheme.favorite.withValues(alpha: 0.3)),
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
                                      borderRadius: BorderRadius.circular(NeuRadius.r8),
                                      shadowColor: Colors.black.withValues(alpha: 0.5),
                                      child: child,
                                    );
                                  },
                                  child: child,
                                );
                              },
                              // The replacement (onReorderItem, which pre-adjusts
                              // newIndex) only exists from Flutter 3.44; the
                              // local toolchain is 3.41.9 while CI builds 3.44.2.
                              // Migrate once the floor moves past 3.44.
                              // ignore: deprecated_member_use
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
                                  padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                                  // The last web-style hairline in the
                                  // app; every other separator engraves.
                                  child: Column(children: [
                                  Row(
                                    children: [
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.grab,
                                          child: Container(
                                            padding: const EdgeInsets.all(NeuSpace.s4),
                                            child: Icon(Icons.drag_handle, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: NeuSpace.s8),
                                      NeuAvatar(
                                        url: ch.originalChannel.avatarUrl,
                                        radius: 14,
                                        isDark: themeNotifier.isDarkTheme,
                                      ),
                                      const SizedBox(width: NeuSpace.s8),
                                      Expanded(
                                        child: Text(
                                          ch.originalChannel.username,
                                          style: NeuType.headingSm(themeNotifier.isDarkTheme),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s2),
                                        decoration: BoxDecoration(
                                          color: theme.primaryColor.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(NeuRadius.r12),
                                          border: Border.all(color: themeNotifier.accentInk, width: 1),
                                        ),
                                        child: Text(
                                          'Priority #${priorityChannels.indexOf(ch) + 1}',
                                          style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                                        ),
                                      ),
                                    ],
                                  ),
                                  EngravedRule(),
                                  ]),
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(height: NeuSpace.s20),
                        ],

                        Padding(
                          padding: const EdgeInsets.only(bottom: NeuSpace.s8),
                          child: Text(
                            'Every favourite',
                            style: NeuType.headingSm(themeNotifier.isDarkTheme),
                          ),
                        ),

                        ..._favChannels.map((ch) {
                          return Container(
                            margin: const EdgeInsets.only(bottom: NeuSpace.s8),
                            padding: const EdgeInsets.all(NeuSpace.s12),
                            decoration: NeuTheme.raisedDecoration(
                              themeNotifier.isDarkTheme,
                              radius: NeuRadius.r12,
                              border: Border.all(
                                color: (ch.autoPlayLive || ch.autoDownloadVods)
                                    ? theme.primaryColor.withValues(alpha: 0.4)
                                    : NeuTheme.border(themeNotifier.isDarkTheme),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    NeuAvatar(
                                      url: ch.originalChannel.avatarUrl,
                                      radius: NeuRadius.r16,
                                      isDark: themeNotifier.isDarkTheme,
                                    ),
                                    const SizedBox(width: NeuSpace.s12),
                                    Expanded(
                                      child: Text(
                                        ch.originalChannel.username,
                                        style: NeuType.headingSm(themeNotifier.isDarkTheme),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: NeuSpace.s8),
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
                                          const SizedBox(width: NeuSpace.s8),
                                          Text(
                                            'Play when live',
                                            style: NeuType.bodySm(themeNotifier.isDarkTheme),
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
                                          const SizedBox(width: NeuSpace.s8),
                                          Text(
                                            'Download VODs',
                                            style: NeuType.bodySm(themeNotifier.isDarkTheme),
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
                                            style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                          ),
                                          DropdownButton<int>(
                                            value: ch.maxVodKeepCount.clamp(1, 5),
                                            dropdownColor: NeuTheme.surface(themeNotifier.isDarkTheme),
                                            style: TextStyle(color: themeNotifier.accentInk, fontWeight: FontWeight.bold),
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
                                            const SizedBox(width: NeuSpace.s8),
                                            Text(
                                              // The cutoff is the exclusion
                                              // threshold above, not a fixed 5%:
                                              // the two rules share one number so
                                              // that the slider actually governs
                                              // both. Labelling it "5%" while the
                                              // slider drove the behaviour would
                                              // be a lie.
                                              'Stop at last watched (over $_threshold%)',
                                              style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // Fast Download Checkbox (Skip post-processing)
                                      InkWell(
                                        onTap: () {
                                          setState(() {
                                            ch.autoDownloadFastDownload = !ch.autoDownloadFastDownload;
                                          });
                                        },
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            NeuCheckbox(
                                              value: ch.autoDownloadFastDownload,
                                              activeColor: theme.primaryColor,
                                              isDark: themeNotifier.isDarkTheme,
                                              onChanged: (val) {
                                                setState(() {
                                                  ch.autoDownloadFastDownload = val ?? false;
                                                });
                                              },
                                            ),
                                            const SizedBox(width: NeuSpace.s8),
                                            Text(
                                              'Fast Download (Skip post-processing)',
                                              style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
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

          ],
        ),
      actions: [
        NeuDialogAction.secondary('Cancel', () => Navigator.of(context).pop()),
        NeuDialogAction.primary('Save and apply', () {
          widget.settings.vodWatchExclusionThreshold = _threshold;
          widget.settings.autoPlayPreemptLowerPriority = _preemptLowerPriority;
          _updatePriorities();
          for (final st in _favChannels) {
            st.applyToOriginal();
          }
          widget.onSettingsSaved();
          Navigator.of(context).pop();
        }),
      ],
    );
  }
}
