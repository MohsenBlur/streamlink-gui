import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/twitch_channel.dart';
import '../../models/twitch_video.dart';
import '../../state/vod_browser_controller.dart';
import '../../theme/neu_material_themes.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../dashboard_header.dart';
import '../interactive_popover.dart';
import '../neumorphic/neu_button.dart';
import '../neumorphic/neu_checkbox.dart';
import '../neumorphic/neu_icon_action.dart';
import '../neumorphic/neu_progress.dart';
import '../neumorphic/neu_switch.dart';
import '../neumorphic/neu_text_field.dart';
import '../vods_grid.dart';
import 'app_layout.dart';
import 'selection_bar.dart';

/// An open channel: its header, the VOD toolbar (or the selection bar in
/// selection mode), the browser-token warning, the grid and Load more.
///
/// Moved out of `_MainScreenState` as it was. Everything it shows is handed
/// in, and everything it does is a callback: the list itself is the
/// [VodBrowserController]'s, the selection and the game filter are the
/// screen's, and the screen rebuilds this on every change to either.
class ChannelDashboard extends StatelessWidget {
  const ChannelDashboard({
    super.key,
    required this.channel,
    required this.settings,
    required this.vodBrowser,
    required this.pulseController,
    required this.isPlaying,
    required this.isMultiSelectMode,
    required this.selectedVodIds,
    required this.isWebTokenExpired,
    required this.selectedGamesFilter,
    required this.vodSearchController,
    required this.displayMenu,
    required this.isVodPlaying,
    required this.isVodDownloaded,
    required this.downloadStatus,
    required this.downloadProgress,
    required this.onPlayLive,
    required this.onRefreshChannel,
    required this.openExternalLink,
    required this.onEnterSelection,
    required this.onExitSelection,
    required this.onClearSelection,
    required this.onSelectAllVisible,
    required this.onBulkMark,
    required this.onBulkDownload,
    required this.onBulkDelete,
    required this.onRefreshVods,
    required this.onUpdateToken,
    required this.onDismissWebTokenWarning,
    required this.onGameFilterSelected,
    required this.onClearGameFilter,
    required this.onPlayVod,
    required this.onDownloadVod,
    required this.onDeleteDownload,
    required this.onCancelDownload,
    required this.onVodSelectedChange,
    required this.onOpenFolder,
    required this.onLoadMore,
  });

  final TwitchChannel channel;
  final AppSettings settings;

  /// The open channel's list: its VODs, spinners, error, cursor and the
  /// "couldn't refresh" note.
  final VodBrowserController vodBrowser;
  final AnimationController pulseController;

  /// The channel's live stream is open in a player.
  final bool isPlaying;

  final bool isMultiSelectMode;
  final Set<String> selectedVodIds;

  /// Twitch refused the browser token on the last fetch the user asked for.
  final bool isWebTokenExpired;
  final Set<String> selectedGamesFilter;
  final TextEditingController vodSearchController;

  /// The display popover's content ([VodDisplayMenu]).
  final Widget displayMenu;

  final bool Function(String vodId) isVodPlaying;
  final bool Function(String vodId) isVodDownloaded;
  final String? Function(String vodId) downloadStatus;
  final double? Function(String vodId) downloadProgress;

  final VoidCallback onPlayLive;

  /// The header's refresh: the channel's details and its VOD list.
  final VoidCallback onRefreshChannel;
  final void Function(String url) openExternalLink;
  final VoidCallback onEnterSelection;
  final VoidCallback onExitSelection;
  final VoidCallback onClearSelection;
  final VoidCallback onSelectAllVisible;

  /// Marks the selection watched (true) or unwatched.
  final void Function(bool watched) onBulkMark;
  final VoidCallback onBulkDownload;
  final VoidCallback onBulkDelete;

  /// "Check for new VODs".
  final VoidCallback onRefreshVods;
  final VoidCallback onUpdateToken;
  final VoidCallback onDismissWebTokenWarning;
  final void Function(String game) onGameFilterSelected;
  final VoidCallback onClearGameFilter;
  final void Function(TwitchVideo vod) onPlayVod;
  final void Function(TwitchVideo vod) onDownloadVod;
  final void Function(String vodId) onDeleteDownload;
  final void Function(String vodId) onCancelDownload;
  final void Function(String vodId, bool selected) onVodSelectedChange;
  final void Function(TwitchVideo vod) onOpenFolder;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    // maybeOf, not of. This was a method called from MainScreen's build()
    // with the State's own context, which sits ABOVE the AppLayout that
    // build() returns - so AppLayout.of asserted "No AppLayout ancestor" and
    // took the entire channel dashboard down. Below it now, maybeOf finds the
    // same values either way.
    final theme = Theme.of(context);
    final layout = AppLayout.maybeOf(context);
    // isSmall is gone: the VOD toolbar no longer has a wide-only variant to
    // switch to, because the inline duplicate of the display controls was
    // removed in favour of the single popover.
    final isCompact = layout.isRail;
    // CustomScrollView so the VOD grid renders as a real SliverGrid and
    // off-screen cards are culled; the old SingleChildScrollView +
    // shrinkWrap GridView materialized every card at once.
    return CustomScrollView(
            slivers: [
              SliverPadding(
                // s16 minimum: the viewport clips at its bounds, and a d3
                // card's cast shadow reaches ~15px - s12 cut its tail on
                // every bottom-row card in compact windows.
                padding: EdgeInsets.all(isCompact ? NeuSpace.s16 : NeuSpace.s24),
                sliver: SliverMainAxisGroup(slivers: [
                // Real-time Stats Card Widget
                SliverToBoxAdapter(child: DashboardHeader(
                  channel: channel,
                  pulseController: pulseController,
                  isPlaying: isPlaying,
                  onPlay: onPlayLive,
                  // The whole channel: its details (follower count
                  // included, which the batched poll leaves out) and its
                  // VOD list, merged in place.
                  onRefresh: onRefreshChannel,
                  openExternalLink: openExternalLink,
                )),

                // VOD section (if OAuth token present)
                if (settings.twitchOauthToken.trim().isNotEmpty) ...[
                  SliverToBoxAdapter(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  SizedBox(height: isCompact ? 12 : 32),
                  // In selection mode the SelectionBar REPLACES this row
                  // rather than growing out of it. Appending the bulk actions
                  // to the toolbar is what made the toolbar overflow: four
                  // labelled buttons, a count, a progress ring and two icon
                  // buttons, with no compact branch anywhere.
                  if (isMultiSelectMode)
                    SelectionBar(
                      selectedCount: selectedVodIds.length,
                      onExit: onExitSelection,
                      onClear: onClearSelection,
                      onSelectAllVisible: onSelectAllVisible,
                      actions: [
                        SelectionAction(
                          label: 'Watched',
                          icon: Icons.check_circle_outline,
                          tone: SelectionTone.accent,
                          onPressed: selectedVodIds.isEmpty
                              ? null
                              : () => onBulkMark(true),
                        ),
                        SelectionAction(
                          label: 'Unwatched',
                          icon: Icons.unpublished_outlined,
                          onPressed: selectedVodIds.isEmpty
                              ? null
                              : () => onBulkMark(false),
                        ),
                        SelectionAction(
                          label: 'Download',
                          icon: Icons.download,
                          tone: SelectionTone.positive,
                          onPressed: selectedVodIds.isEmpty
                              ? null
                              : onBulkDownload,
                        ),
                        SelectionAction(
                          label: 'Delete files',
                          icon: Icons.delete_outline,
                          tone: SelectionTone.destructive,
                          onPressed: selectedVodIds.isEmpty
                              ? null
                              : onBulkDelete,
                        ),
                      ],
                    )
                  else
                    Row(
                      children: [
                        // A labelled button, not a bare pencil. The pencil had
                        // a tooltip and nothing else, so the only way to learn
                        // the grid had a selection mode was to hover a 40px
                        // icon and wait.
                        NeuButton(
                          onPressed: onEnterSelection,
                          padding: const EdgeInsets.symmetric(
                              horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                          borderRadius: BorderRadius.circular(NeuRadius.r8),
                          tooltip: 'Pick several VODs to download or mark',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.checklist,
                                  size: 15,
                                  color: NeuTheme.text(
                                      themeNotifier.isDarkTheme)),
                              const SizedBox(width: NeuSpace.s6),
                              Text('Select',
                                  style: NeuType.captionStrong(
                                      themeNotifier.isDarkTheme,
                                      color: NeuTheme.text(
                                          themeNotifier.isDarkTheme))),
                            ],
                          ),
                        ),
                        // The note a failed refresh leaves gives way (with
                        // an ellipsis) before any control does.
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: StaleVodNote(stale: vodBrowser.stale),
                          ),
                        ),
                        const SizedBox(width: NeuSpace.s8),
                        if (vodBrowser.isLoading || vodBrowser.isRefreshing) ...[
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: NeuProgressRing(
                                size: NeuProgressRingSize.sm,
                                semanticLabel: 'Loading'),
                          ),
                          const SizedBox(width: NeuSpace.s12),
                        ],
                        // The list refreshes by itself (a broadcast starting
                        // or ending, every few minutes while on screen, on
                        // coming back from the tray); this is for not
                        // waiting. Merged in, so loaded pages and the
                        // selection stay.
                        NeuIconAction(
                          icon: Icons.refresh,
                          tooltip: 'Check for new VODs',
                          onPressed: vodBrowser.isLoading || vodBrowser.isRefreshing
                              ? null
                              : onRefreshVods,
                        ),
                        const SizedBox(width: NeuSpace.s8),
                        // One control path, not two. These settings used to be
                        // rendered inline when the window was wide and in a
                        // popover when it was narrow, and the two copies had
                        // already drifted ('Font: ' versus 'Font Size: ', a
                        // 110px slider versus an Expanded one).
                        InteractivePopover(
                          popover: displayMenu,
                          child: VodDisplayButton(theme: theme),
                        ),
                      ],
                    ),
                  const SizedBox(height: NeuSpace.s16),
                  if (isWebTokenExpired) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: NeuSpace.s16),
                      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s12),
                      // Intentional: translucent warning tint, readable over both themes.
                      decoration: BoxDecoration(
                        color: NeuTheme.warning.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(NeuRadius.r8),
                        border: Border.all(color: NeuTheme.warning.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: NeuTheme.warningText(themeNotifier.isDarkTheme), size: 20),
                          const SizedBox(width: NeuSpace.s12),
                          Expanded(
                            child: Text(
                              'Your Twitch Browser OAuth Token has expired. VOD watch progress tracking is currently paused.',
                              style: NeuType.headingSm(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                            ),
                          ),
                          const SizedBox(width: NeuSpace.s12),
                          TextButton(
                            style: TextButton.styleFrom(
                              backgroundColor: NeuTheme.warning.withValues(alpha: 0.2),
                              foregroundColor: NeuTheme.warningText(themeNotifier.isDarkTheme),
                              padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                            ),
                            onPressed: onUpdateToken,
                            child: const Text('Update Token', style: NeuType.labelMetrics),
                          ),
                          const SizedBox(width: NeuSpace.s8),
                          NeuIconAction(
                            icon: Icons.close,
                            tooltip: 'Dismiss',
                            size: NeuActionSize.sm,
                            style: NeuActionStyle.flat,
                            onPressed: onDismissWebTokenWarning,
                          ),
                        ],
                      ),
                    ),
                  ],
                  ])),

                  // Modular Vods Grid Component
                  VodsGrid(
                    vods: vodBrowser.vods,
                    isLoading: vodBrowser.isLoading,
                    vodsError: vodBrowser.error,
                    vodScale: settings.vodCardScale,
                    vodTitleFontSize: settings.vodTitleFontSize,
                    showGamesOnThumbnails: settings.showGamesOnThumbnails,
                    selectedGamesFilter: selectedGamesFilter,
                    vodSearchController: vodSearchController,
                    theme: theme,
                    isMultiSelectMode: isMultiSelectMode,
                    selectedVodIds: selectedVodIds,
                    isPlaying: isVodPlaying,
                    isDownloaded: isVodDownloaded,
                    getDownloadStatus: downloadStatus,
                    getDownloadProgress: downloadProgress,
                    pulseController: pulseController,
                    watchedThreshold: settings.watchedThreshold,
                    activeProgressColor: themeNotifier.activeProgressColor,
                    watchedProgressColor: themeNotifier.watchedProgressColor,
                    onGameFilterSelected: onGameFilterSelected,
                    onClearGameFilter: onClearGameFilter,
                    onPlay: onPlayVod,
                    onDownload: onDownloadVod,
                    onDeleteDownload: onDeleteDownload,
                    onCancelDownload: onCancelDownload,
                    onVodSelectedChange: onVodSelectedChange,
                    onOpenFolder: onOpenFolder,
                  ),
                  
                  if (vodBrowser.cursor != null && vodBrowser.cursor!.isNotEmpty && vodBrowser.vods.isNotEmpty) ...[
                    SliverToBoxAdapter(child: Column(children: [
                    const SizedBox(height: NeuSpace.s24),
                    Center(
                      child: Container(
                        width: 180,
                        height: 40,
                        // Through the engine: a flat outlined token-fill pill
                        // under a grid of machined VOD cards was the web
                        // outline-button idiom, and it is what the page ends
                        // on.
                        decoration: NeuTheme.raised(themeNotifier.isDarkTheme,
                            radius: NeuRadius.r8),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            foregroundColor: NeuTheme.text(themeNotifier.isDarkTheme),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(NeuRadius.r8),
                            ),
                            elevation: 0,
                          ),
                          onPressed: vodBrowser.isLoading
                              ? null
                              : onLoadMore,
                          child: vodBrowser.isLoading
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: NeuProgressRing(size: NeuProgressRingSize.sm, color: NeuTheme.text(themeNotifier.isDarkTheme), semanticLabel: 'Loading'),
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.expand_more, size: 18),
                                    SizedBox(width: NeuSpace.s6),
                                    Text('Load More VODs', style: NeuType.labelMetrics),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    ])),
                  ],
                ],
                ]),
              ),
            ],
    );
  }
}

/// "Couldn't refresh" over a list that is not current, with when it is
/// from. A failed fetch over a cached list used to say nothing at all, so a
/// list from hours ago passed for a current one.
class StaleVodNote extends StatelessWidget {
  const StaleVodNote({super.key, required this.stale});

  /// Null when the list is current: nothing is shown.
  final StaleVodList? stale;

  @override
  Widget build(BuildContext context) {
    final stale = this.stale;
    if (stale == null) return const SizedBox.shrink();
    final isDark = themeNotifier.isDarkTheme;
    final since = stale.since;
    String two(int v) => v < 10 ? '0$v' : '$v';
    final clock = '${two(since.hour)}:${two(since.minute)}';
    return Tooltip(
      message: stale.reason,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 14, color: NeuTheme.warningText(isDark)),
          const SizedBox(width: NeuSpace.s6),
          Flexible(
            child: Text(
              "Couldn't refresh - showing the list from $clock",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NeuType.caption(isDark, color: NeuTheme.warningText(isDark)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The VOD grid's display settings, in the toolbar's popover: game badges,
/// the text filter, the game filter, card and title size.
///
/// It edits the screen's own state - the settings, the filter set, the
/// search field - through [update], the screen's setState, exactly as it did
/// as a method of the screen; the StatefulBuilders inside repaint the
/// popover, which the screen's rebuild does not reach.
class VodDisplayMenu extends StatelessWidget {
  const VodDisplayMenu({
    super.key,
    required this.settings,
    required this.vods,
    required this.selectedGamesFilter,
    required this.vodSearchController,
    required this.update,
    required this.onSave,
  });

  final AppSettings settings;

  /// The list on screen, whose games the game filter offers.
  final List<TwitchVideo> vods;
  final Set<String> selectedGamesFilter;
  final TextEditingController vodSearchController;
  final void Function(VoidCallback change) update;

  /// Writes the settings changed here.
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 320,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      padding: const EdgeInsets.all(NeuSpace.s16),
      decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r12),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatefulBuilder(
              builder: (context, setMenuState) {
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Gives way to the switch: wider than the menu, the
                    // label ran past its edge (by 95px in the test font).
                    Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.sports_esports, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                          const SizedBox(width: NeuSpace.s6),
                          Flexible(
                            child: Text('Show All Games on Thumbnails', style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme))),
                          ),
                        ],
                      ),
                    ),
                    NeuSwitch(
                      value: settings.showGamesOnThumbnails,
                      onChanged: (val) {
                        update(() {
                          settings.showGamesOnThumbnails = val;
                        });
                        onSave();
                        setMenuState(() {});
                      },
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: NeuSpace.s12),
            Text('Filter Broadcasts:', style: NeuType.captionStrong(themeNotifier.isDarkTheme)),
            const SizedBox(height: NeuSpace.s6),
            NeuTextField(
              controller: vodSearchController,
              hintText: 'Filter VODs...',
              prefixIcon: Icons.search,
              size: NeuFieldSize.md,
              onChanged: (val) => update(() {}),
              onClear: () => update(() {}),
            ),
            const SizedBox(height: NeuSpace.s12),
            StatefulBuilder(
              builder: (context, setMenuState) {
                final uniqueGames = vods.expand((vod) => vod.games).toSet().toList()..sort();
                if (uniqueGames.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Filter by Games:', style: NeuType.captionStrong(themeNotifier.isDarkTheme)),
                        if (selectedGamesFilter.isNotEmpty)
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () {
                                update(() {
                                  selectedGamesFilter.clear();
                                });
                                setMenuState(() {});
                              },
                              child: Text(
                                'Clear All',
                                style: NeuType.plate(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: NeuSpace.s8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: NeuTheme.sunkenDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r6),
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: NeuSpace.s4),
                        children: uniqueGames.map((game) {
                          final isChecked = selectedGamesFilter.contains(game);
                          return InkWell(
                            onTap: () {
                              update(() {
                                if (isChecked) {
                                  selectedGamesFilter.remove(game);
                                } else {
                                  selectedGamesFilter.add(game);
                                }
                              });
                              setMenuState(() {});
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s6),
                              child: Row(
                                children: [
                                  NeuCheckbox(
                                    value: isChecked,
                                    activeColor: theme.primaryColor,
                                    size: 16,
                                    onChanged: (val) {
                                      update(() {
                                        if (isChecked) {
                                          selectedGamesFilter.remove(game);
                                        } else {
                                          selectedGamesFilter.add(game);
                                        }
                                      });
                                      setMenuState(() {});
                                    },
                                  ),
                                  const SizedBox(width: NeuSpace.s8),
                                  Expanded(
                                    child: Text(
                                      game,
                                      style: NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: NeuSpace.s16),
            Row(
              children: [
                Icon(Icons.photo_size_select_large, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                const SizedBox(width: NeuSpace.s6),
                Text('Card Size: ', style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
                Expanded(
                  child: SliderTheme(
                    data: neuSliderTheme(context),
                    child: Slider(
                      value: settings.vodCardScale,
                      min: 200.0,
                      max: 600.0,
                      onChanged: (val) {
                        update(() {
                          settings.vodCardScale = val;
                        });
                      },
                      onChangeEnd: (_) => onSave(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NeuSpace.s8),
            Row(
              children: [
                Icon(Icons.format_size, size: 14, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                const SizedBox(width: NeuSpace.s6),
                Text('Font Size: ', style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme))),
                Expanded(
                  child: SliderTheme(
                    data: neuSliderTheme(context),
                    child: Slider(
                      value: settings.vodTitleFontSize,
                      min: AppSettings.minVodTitleFontSize,
                      max: AppSettings.maxVodTitleFontSize,
                      onChanged: (val) {
                        update(() {
                          settings.vodTitleFontSize = val;
                        });
                      },
                      onChangeEnd: (_) => onSave(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The trigger for the VOD display settings.
///
/// Was a hover-morphing chip that only revealed its accent styling when the
/// pointer was over it, and appeared ONLY when the window was narrow - so at
/// wide widths the controls it opens had no button at all, and at narrow
/// widths there was no static hint that a menu existed. It is now a plain
/// labelled button, present at every width.
class VodDisplayButton extends StatelessWidget {
  const VodDisplayButton({super.key, required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    // A plain raised chip, NOT a NeuButton. With onPressed: null the button
    // painted the full disabled treatment - dimmed ink, flat depth, basic
    // cursor, excluded from Tab order - so the only entry point to the
    // grid's display settings LOOKED dead while working by accident of the
    // gesture arena. InteractivePopover owns the tap, cursor and focus.
    return Tooltip(
      message: 'Card size, title size, filters and game badges',
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
      decoration: NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tune, size: 15, color: NeuTheme.text(isDark)),
          const SizedBox(width: NeuSpace.s6),
          Text('Display',
              style: NeuType.bodySm(isDark)),
          const SizedBox(width: NeuSpace.s2),
          Icon(Icons.arrow_drop_down, size: 16, color: NeuTheme.subtext(isDark)),
        ],
      ),
      ),
    );
  }
}
