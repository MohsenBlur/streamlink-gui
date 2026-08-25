import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../state/channel_search.dart';
import 'hover_overlay_menu.dart';
import 'live_rainbow_border.dart';
import 'favorites_automation_dialog.dart';
import 'shell/neu_dialog.dart';
import 'interactive_popover.dart';
import 'live_preview_popup.dart';
import 'sidebar_search_popover.dart';
import 'neumorphic/neu_button.dart';
import 'neumorphic/neu_text_field.dart';
import 'neumorphic/neu_segmented_control.dart';
import 'package:flutter/gestures.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_avatar.dart';
import 'neumorphic/neu_icon_action.dart';
import 'shell/nav_scope.dart';
import 'shell/context_menu.dart';
import 'neumorphic/neu_progress.dart';
import '../theme/theme_notifier.dart';

class SidebarPanel extends StatefulWidget {
  final List<TwitchChannel> channels;
  final List<TwitchChannel> followedChannels;
  final TwitchChannel? selectedChannel;
  final AppSettings settings;
  final bool sidebarCollapsed;
  final bool isHorizontal;
  final int sidebarTab;
  final bool isAdding;
  final bool isGlobalLoading;
  final bool isLoadingFollowed;
  final String? authenticatedUserLogin;
  final String? authenticatedUserAvatar;
  final AnimationController pulseController;
  final TextEditingController searchController;
  
  final ValueChanged<TwitchChannel> onChannelSelected;

  /// Carries the tapped row's own channel. The old String signature forced
  /// main.dart to look the metadata up on _selectedChannel, so double-tapping
  /// a non-selected row launched with another channel's title/game/live state.
  final ValueChanged<TwitchChannel> onChannelDoubleTapped;

  /// Explicit play affordance (hover play button, search popover, Enter).
  final ValueChanged<TwitchChannel> onChannelPlayPressed;

  final ValueChanged<String> onAddChannel;

  /// Externally owned focus node for the search field (Ctrl+F).
  final FocusNode? searchFocusNode;
  final ValueChanged<TwitchChannel> onToggleFavorite;
  final ValueChanged<bool> onToggleCollapse;
  final VoidCallback? onGoToDashboard;
  final VoidCallback? onSaveAutomationSettings;
  final ValueChanged<int> onTabChanged;
  final VoidCallback onRefresh;
  final VoidCallback onShowSettings;
  final VoidCallback onShowLibrary;

  const SidebarPanel({
    Key? key,
    required this.channels,
    required this.followedChannels,
    required this.selectedChannel,
    required this.settings,
    required this.sidebarCollapsed,
    required this.isHorizontal,
    required this.sidebarTab,
    required this.isAdding,
    required this.isGlobalLoading,
    required this.isLoadingFollowed,
    required this.authenticatedUserLogin,
    required this.authenticatedUserAvatar,
    required this.pulseController,
    required this.searchController,
    required this.onChannelSelected,
    required this.onChannelDoubleTapped,
    required this.onChannelPlayPressed,
    required this.onAddChannel,
    this.searchFocusNode,
    required this.onToggleFavorite,
    required this.onToggleCollapse,
    this.onGoToDashboard,
    this.onSaveAutomationSettings,
    required this.onTabChanged,
    required this.onRefresh,
    required this.onShowSettings,
    required this.onShowLibrary,
  }) : super(key: key);

  @override
  State<SidebarPanel> createState() => SidebarPanelState();
}

class SidebarPanelState extends State<SidebarPanel> {
  late ScrollController _horizontalScrollController;

  @override
  void initState() {
    super.initState();
    _horizontalScrollController = ScrollController();
  }

  void _openFavoritesAutomationDialog() {
    // Dismissible: the dialog stages its edits and applies none until Save.
    NeuDialog.show<void>(
      context,
      dismissible: true,
      builder: (context) => FavoritesAutomationDialog(
        favorites: widget.channels,
        settings: widget.settings,
        onSettingsSaved: () {
          widget.onSaveAutomationSettings?.call();
        },
      ),
    );
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    super.dispose();
  }

  bool _isNewlyLive(TwitchChannel channel) {
    if (channel.wentLiveTime == null) return false;
    final diff = DateTime.now().difference(channel.wentLiveTime!);
    return diff.inSeconds < 60;
  }

  Widget _buildAvatarBorder({
    required TwitchChannel channel,
    required bool isSelected,
    required ThemeData theme,
    required Widget child,
  }) {
    if (_isNewlyLive(channel)) {
      // Freeze the ring exactly when the 60s newly-live window ends instead
      // of waiting for the next unrelated rebuild.
      final elapsed = DateTime.now().difference(channel.wentLiveTime!);
      final remaining = const Duration(seconds: 60) - elapsed;
      return LiveRainbowBorder(
        borderRadius: 100,
        strokeWidth: 2.5,
        stopAfter: remaining.isNegative ? Duration.zero : remaining,
        child: child,
      );
    }

    return Container(
      // Intentional: sub-grid. The hairline ring around the avatar.
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: isSelected
              ? theme.primaryColor
              : (channel.isLive ? NeuTheme.live.withValues(alpha: 0.8) : Colors.transparent),
          width: 2.0,
        ),
        boxShadow: [
          if (channel.isLive)
            BoxShadow(
              color: (isSelected ? theme.primaryColor : NeuTheme.live).withValues(alpha: 0.4),
              blurRadius: 6,
              spreadRadius: 1,
            ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    if (widget.isHorizontal) {
      return _buildHorizontalTopBar(theme);
    }
    
    final sidebarWidth = widget.sidebarCollapsed ? 70.0 : 280.0;

    return Container(
      width: sidebarWidth,
      // The faceplate. A flat `color:` was the right call while every material
      // was the same soft plastic; a panel carries the material's grain and its
      // bevelled edge, which is where a rack's brush actually reads.
      //
      // Radius zero: this panel is the full height of the window and its edges
      // are the window's own, so rounding them would float it inside itself.
      decoration: NeuTheme.panel(themeNotifier.isDarkTheme, radius: 0),
      child: widget.sidebarCollapsed
          ? _buildCollapsedSidebar(theme)
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s16),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme), width: 1.5)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: 'Dashboard Hub (Return Home)',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: InkWell(
                              onTap: widget.onGoToDashboard,
                              borderRadius: BorderRadius.circular(NeuRadius.r8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s4, vertical: NeuSpace.s4),
                                child: Row(
                                  children: [
                                    widget.authenticatedUserAvatar != null
                                         ? NeuAvatar(
                                             url: widget.authenticatedUserAvatar,
                                             radius: 18,
                                             isDark: themeNotifier.isDarkTheme,
                                           )
                                        : Container(
                                            padding: const EdgeInsets.all(NeuSpace.s6),
                                            decoration: BoxDecoration(
                                              color: theme.primaryColor.withValues(alpha: 0.15),
                                              borderRadius: BorderRadius.circular(NeuRadius.r8),
                                              border: Border.all(color: theme.primaryColor.withValues(alpha: 0.4), width: 1),
                                            ),
                                            child: Icon(Icons.dashboard_outlined, color: themeNotifier.accentInk, size: 20),
                                          ),
                                    const SizedBox(width: NeuSpace.s8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Streamlink GUI',
                                            style: NeuType.headingMd(themeNotifier.isDarkTheme),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: NeuSpace.s2),
                                          Row(
                                            children: [
                                              Container(
                                                width: 6,
                                                height: 6,
                                                decoration: BoxDecoration(
                                                  color: widget.authenticatedUserLogin != null ? NeuTheme.liveText(themeNotifier.isDarkTheme) : NeuTheme.subtext(themeNotifier.isDarkTheme),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                              const SizedBox(width: NeuSpace.s4),
                                              Expanded(
                                                child: Text(
                                                  widget.authenticatedUserLogin != null
                                                      ? '@${widget.authenticatedUserLogin}'
                                                      : 'Guest Mode',
                                                  style: NeuType.caption(themeNotifier.isDarkTheme),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.keyboard_double_arrow_left, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 20),
                        tooltip: 'Collapse Sidebar',
                        onPressed: () => widget.onToggleCollapse(true),
                        hoverColor: theme.primaryColor.withValues(alpha: 0.2),
                        splashRadius: 20,
                      ),
                    ],
                  ),
                ),

                // Add / Search channel section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s12),
                  child: Row(
                    children: [
                      Expanded(
                        child: NeuTextField(
                          controller: widget.searchController,
                          focusNode: widget.searchFocusNode,
                          hintText: 'Search or add username...',
                          prefixIcon: Icons.search,
                          onChanged: (val) => setState(() {}),
                          onSubmitted: (val) => _handleSearchSubmit(),
                          onClear: () => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: NeuSpace.s8),
                      NeuIconButton(
                        icon: widget.isAdding ? Icons.hourglass_top : Icons.add_rounded,
                        activeColor: theme.primaryColor,
                        isSelected: true,
                        size: 40,
                        tooltip: 'Add Channel',
                        onPressed: widget.isAdding ? null : () => widget.onAddChannel(widget.searchController.text),
                      ),
                    ],
                  ),
                ),

                // Sidebar Tabs (Only if authenticated)
                if (widget.settings.twitchOauthToken.trim().isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s4),
                    child: NeuSegmentedControl<int>(
                      selectedValue: widget.sidebarTab,
                      onValueChanged: (val) => widget.onTabChanged(val),
                      children: const {
                        0: Text('Favorites'),
                        1: Text('Followed'),
                        2: Text('Live'),
                      },
                    ),
                  ),
                  const SizedBox(height: NeuSpace.s8),
                ],

                // Global Actions Toolbar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                  child: Row(
                    children: [
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: NeuSpace.s8),
                          depth: 3.0,
                          onPressed: widget.isGlobalLoading || widget.isLoadingFollowed ? null : widget.onRefresh,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (widget.isGlobalLoading || widget.isLoadingFollowed)
                                 SizedBox(
                                   width: 14,
                                   height: 14,
                                   child: NeuProgressRing(size: NeuProgressRingSize.xs, semanticLabel: 'Loading'),
                                 )
                              else
                                const Icon(Icons.refresh, size: 14),
                              const SizedBox(width: NeuSpace.s6),
                              Flexible(
                                child: Text(
                                  widget.sidebarTab == 0
                                      ? 'Refresh Favorites'
                                      : (widget.sidebarTab == 1 ? 'Refresh Follows' : 'Refresh Live'),
                                  style: NeuType.bodySmMetrics,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: NeuSpace.s8),
                      _PinnedFavoritesAutomationButton(
                        onPressed: _openFavoritesAutomationDialog,
                        enabled: widget.sidebarTab == 0,
                        expanded: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: NeuSpace.s8),

                // Channel list
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final listToDisplay = _getListToDisplay();
                      final isLoading = widget.sidebarTab == 0
                          ? widget.isGlobalLoading
                          : (widget.sidebarTab == 1 ? widget.isLoadingFollowed : (widget.isGlobalLoading || widget.isLoadingFollowed));
                      final query = widget.searchController.text.toLowerCase().trim();
                      final hasExactMatch = listToDisplay.any((c) => c.username.toLowerCase().trim() == query);
                      final showAddPrompt = query.isNotEmpty && !hasExactMatch && widget.sidebarTab == 0;

                      if (isLoading && listToDisplay.isEmpty) {
                        return const Center(
                            child: NeuProgressRing(semanticLabel: 'Loading channels'));
                      }

                      if (listToDisplay.isEmpty && !showAddPrompt) {
                        return Center(
                          child: Text(
                            query.isNotEmpty
                                ? "No channels match '$query'."
                                : widget.sidebarTab == 0
                                    ? 'No favorites saved.\nAdd one above.'
                                    : (widget.sidebarTab == 1
                                        ? 'No followed channels found.\nMake sure your account is connected.'
                                        : 'No live channels found.'),
                            textAlign: TextAlign.center,
                            style: NeuType.bodySm(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                          ),
                        );
                      }

                      final itemCount = listToDisplay.length + (showAddPrompt ? 1 : 0);

                      return ListView.builder(
                        // Shadow room at the scroll extremes: a selected or
                        // hovered row raises, and selection is sticky - a
                        // selected first row showed a permanently truncated
                        // halo against the list's clip.
                        padding: const EdgeInsets.symmetric(
                            vertical: NeuSpace.s8),
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          if (showAddPrompt && index == 0) {
                            return Container(
                              margin: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s4),
                              decoration: BoxDecoration(
                                color: theme.primaryColor.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(NeuRadius.r12),
                                border: Border.all(
                                  color: theme.primaryColor.withValues(alpha: 0.25),
                                  width: 1,
                                ),
                              ),
                              // Transparent Material, because a ListTile paints
                              // its background and its ink splash on the
                              // NEAREST Material ancestor - which here is the
                              // Scaffold, behind this decorated Container. The
                              // splash was being drawn under an opaque box and
                              // was invisible. Flutter 3.44 asserts on the
                              // arrangement; 3.41, which this repo builds
                              // against locally, does not, so CI is the only
                              // thing that sees it.
                              child: Material(
                                type: MaterialType.transparency,
                                child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12),
                                leading: Icon(Icons.add_circle_outline, color: themeNotifier.accentInk, size: 20),
                                title: Text(
                                  "Add '$query' to Favorites",
                                  style: NeuType.headingSm(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                                ),
                                trailing: widget.isAdding
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: NeuProgressRing(size: NeuProgressRingSize.sm, semanticLabel: 'Loading'),
                                      )
                                     : Icon(Icons.chevron_right, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 18),
                                onTap: widget.isAdding ? null : () => widget.onAddChannel(query),
                              ),
                              ),
                            );
                          }

                          final channel = listToDisplay[showAddPrompt ? index - 1 : index];
                          final isSelected = widget.selectedChannel?.username == channel.username;
                          final cleanUsername = channel.username.toLowerCase().trim();
                          final isFavorite = widget.channels.any((c) => c.username == cleanUsername);

                          final row = _SidebarChannelRow(
                            // Keyed by identity so hover state survives the
                            // 60s poll rebuild (it previously lived in a
                            // per-item closure and reset on every poll).
                            key: ValueKey('row_$cleanUsername'),
                            channel: channel,
                            isSelected: isSelected,
                            isFavorite: isFavorite,
                            showFavoriteStarAlways: widget.sidebarTab == 0,
                            leading: _buildAvatarBorder(
                              channel: channel,
                              isSelected: isSelected,
                              theme: theme,
                              child: NeuAvatar(
                                url: channel.avatarUrl,
                                radius: 18,
                                isDark: themeNotifier.isDarkTheme,
                              ),
                            ),
                            pulseController: widget.pulseController,
                            onSelected: widget.onChannelSelected,
                            onDoubleTapped: widget.onChannelDoubleTapped,
                            onPlayPressed: widget.onChannelPlayPressed,
                            onToggleFavorite: widget.onToggleFavorite,
                          );

                          return channel.isLive
                              ? HoverOverlayMenu(
                                  trigger: row,
                                  menu: LivePreviewPopup(channel: channel),
                                )
                              : row;
                        },
                      );
                    },
                  ),
                ),
                
                // Settings bottom bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16, vertical: NeuSpace.s12),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme), width: 1)),
                  ),
                  child: Row(
                    children: [
                      NeuIconAction(
                        icon: Icons.settings,
                        tooltip: 'Settings',
                        onPressed: widget.onShowSettings,
                        style: NeuActionStyle.flat,
                      ),
                      const SizedBox(width: NeuSpace.s16),
                      NeuIconAction(
                        icon: Icons.video_library_outlined,
                        tooltip: 'Library (downloads & history)',
                        onPressed: widget.onShowLibrary,
                        style: NeuActionStyle.flat,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCollapsedSidebar(ThemeData theme) {
    final activeList = _getListToDisplay();
    
    return Column(
      children: [
        const SizedBox(height: NeuSpace.s12),
        Tooltip(
          message: 'Dashboard Hub (Return Home)',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: widget.onGoToDashboard,
              child: widget.authenticatedUserAvatar != null
                  ? NeuAvatar(
                      url: widget.authenticatedUserAvatar,
                      radius: NeuRadius.r16,
                      isDark: themeNotifier.isDarkTheme,
                    )
                  : Container(
                      padding: const EdgeInsets.all(NeuSpace.s6),
                      decoration: BoxDecoration(
                        color: theme.primaryColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(NeuRadius.r8),
                        border: Border.all(color: theme.primaryColor.withValues(alpha: 0.4), width: 1),
                      ),
                      child: Icon(Icons.dashboard_outlined, color: themeNotifier.accentInk, size: 18),
                    ),
            ),
          ),
        ),
        const SizedBox(height: NeuSpace.s8),
        IconButton(
          icon: Icon(Icons.keyboard_double_arrow_right, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 20),
          tooltip: 'Expand sidebar',
          onPressed: () => widget.onToggleCollapse(false),
          hoverColor: theme.primaryColor.withValues(alpha: 0.2),
          splashRadius: 20,
        ),
        const SizedBox(height: NeuSpace.s8),
        Divider(color: NeuTheme.border(themeNotifier.isDarkTheme), height: 1.5, thickness: 1.5),
        const SizedBox(height: NeuSpace.s12),
        
        // Three real buttons. This was a control that CYCLED through the
        // three tabs on click and revealed its purpose only by swapping to a
        // swap_horiz icon on hover - so it looked like a status indicator, and
        // a user had to discover that clicking a star produced a list of
        // followed channels. It also had no auth guard, unlike the expanded
        // segmented control, so a signed-out user could cycle onto Followed
        // and land on "make sure your account is connected".
        NavScope(
          current: NavScopeTab.byIndex[widget.sidebarTab] ?? NavScopeTab.favorites,
          onChanged: (tab) => widget.onTabChanged(tab.index),
          dense: true,
          isAuthenticated: widget.settings.twitchOauthToken.trim().isNotEmpty,
        ),
        
        const SizedBox(height: NeuSpace.s12),

        // Compact layouts previously had no way to search/add channels or to
        // reach the automation manager at all.
        _buildSearchPopoverTrigger(theme),
        const SizedBox(height: NeuSpace.s12),
        if (widget.sidebarTab == 0) ...[
          _PinnedFavoritesAutomationButton(
            onPressed: _openFavoritesAutomationDialog,
            enabled: widget.sidebarTab == 0,
          ),
          const SizedBox(height: NeuSpace.s12),
        ],

        Tooltip(
          message: widget.sidebarTab == 0
              ? 'Refresh Favorites'
              : (widget.sidebarTab == 1 ? 'Refresh Followed List' : 'Refresh Live'),
          child: IconButton(
            icon: widget.isGlobalLoading || widget.isLoadingFollowed
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: NeuProgressRing(size: NeuProgressRingSize.sm, semanticLabel: 'Loading'),
                  )
                : Icon(Icons.refresh, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 18),
            onPressed: widget.isGlobalLoading || widget.isLoadingFollowed ? null : widget.onRefresh,
            hoverColor: theme.primaryColor.withValues(alpha: 0.2),
            splashRadius: 20,
          ),
        ),
        
        const SizedBox(height: NeuSpace.s8),
        Divider(color: NeuTheme.border(themeNotifier.isDarkTheme), height: 1, thickness: 1),
        const SizedBox(height: NeuSpace.s12),
        
        Expanded(
          child: ListView.builder(
            itemCount: activeList.length,
            padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12),
            itemBuilder: (context, index) {
              final ch = activeList[index];
              final isSelected = widget.selectedChannel?.username == ch.username;
              
              final itemWidget = MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: NeuSpace.s8),
                  child: Tooltip(
                    message: '${ch.username} (${ch.isLive ? "LIVE: " + (ch.game ?? "Streaming") : "Offline"})',
                    child: GestureDetector(
                    onTap: () => widget.onChannelSelected(ch),
                    onDoubleTap: ch.isLive ? () => widget.onChannelDoubleTapped(ch) : null,
                    child: _buildAvatarBorder(
                      channel: ch,
                      isSelected: isSelected,
                      theme: theme,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          _AvatarWithPlay(
                            channel: ch,
                            onPlay: widget.onChannelPlayPressed,
                          ),
                          if (ch.isLive)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: NeuTheme.live,
                                  shape: BoxShape.circle,
                                  border: NeuTheme.statusRing(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );

              return ch.isLive
                  ? HoverOverlayMenu(
                      trigger: itemWidget,
                      menu: LivePreviewPopup(channel: ch),
                    )
                  : itemWidget;
            },
          ),
        ),
        
        Container(
          padding: const EdgeInsets.symmetric(vertical: NeuSpace.s12),
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme), width: 1)),
          ),
          child: Column(
            children: [
              NeuIconAction(
                        icon: Icons.video_library_outlined,
                        tooltip: 'Library (downloads & history)',
                        onPressed: widget.onShowLibrary,
                        style: NeuActionStyle.flat,
                      ),
              const SizedBox(height: NeuSpace.s12),
              NeuIconAction(
                        icon: Icons.settings,
                        tooltip: 'Settings',
                        onPressed: widget.onShowSettings,
                        style: NeuActionStyle.flat,
                      ),
            ],
          ),
        ),
      ],
    );
  }


  /// The current tab's full list, before search filtering.
  List<TwitchChannel> _getBaseList() {
    if (widget.sidebarTab == 0) return widget.channels;
    if (widget.sidebarTab == 1) return widget.followedChannels;
    
    final liveList = <TwitchChannel>[];
    final seenUsernames = <String>{};
    for (final c in widget.channels) {
      if (c.isLive) {
        final clean = c.username.toLowerCase().trim();
        if (!seenUsernames.contains(clean)) {
          seenUsernames.add(clean);
          liveList.add(c);
        }
      }
    }
    for (final c in widget.followedChannels) {
      if (c.isLive) {
        final clean = c.username.toLowerCase().trim();
        if (!seenUsernames.contains(clean)) {
          seenUsernames.add(clean);
          liveList.add(c);
        }
      }
    }
    liveList.sort((a, b) => a.username.toLowerCase().compareTo(b.username.toLowerCase()));
    return liveList;
  }

  /// What the list actually renders: the base list narrowed by the search box.
  /// All three layouts route through this, so filtering works everywhere.
  List<TwitchChannel> _getListToDisplay() {
    return filterChannels(_getBaseList(), widget.searchController.text);
  }

  /// Dispatches Enter in the search field. On Favorites an unmatched query
  /// falls back to adding; on Followed/Live it never adds (it used to,
  /// silently).
  void _handleSearchSubmit() {
    final action = resolveSearchSubmit(
      tab: widget.sidebarTab,
      query: widget.searchController.text,
      visible: _getBaseList(),
    );
    switch (action.type) {
      case SubmitActionType.launchLive:
        widget.onChannelSelected(action.channel!);
        widget.onChannelPlayPressed(action.channel!);
      case SubmitActionType.selectOnly:
        widget.onChannelSelected(action.channel!);
      case SubmitActionType.addFavorite:
        widget.onAddChannel(action.query);
      case SubmitActionType.none:
        break;
    }
  }

  /// Ctrl+F entry point. In the expanded layout it focuses the inline field;
  /// compact layouts have no inline field, so the caller opens the popover by
  /// clicking its trigger - here we just request focus when we can.
  void focusSearch() {
    widget.searchFocusNode?.requestFocus();
  }

  Widget _buildSearchPopoverTrigger(ThemeData theme, {double size = 36}) {
    return InteractivePopover(
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 6),
      popoverBuilder: (context, close) => SidebarSearchPopover(
        controller: widget.searchController,
        channels: _getBaseList(),
        tab: widget.sidebarTab,
        onSelect: widget.onChannelSelected,
        onPlay: widget.onChannelPlayPressed,
        onAdd: widget.onAddChannel,
        close: close,
      ),
      child: Tooltip(
        message: 'Search channels',
        child: Container(
          width: size,
          height: size,
          decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: NeuRadius.r8),
          child: Icon(Icons.search, size: size * 0.5, color: NeuTheme.text(themeNotifier.isDarkTheme)),
        ),
      ),
    );
  }

  /// One whole avatar in the rail: a 36px avatar plus its 6px margins.
  ///
  /// The floor under the avatar strip. Below it the strip renders nothing
  /// rather than a slice of a face; see the note at its LayoutBuilder.
  static const double _railAvatarItemWidth = 48.0;

  Widget _buildHorizontalTopBar(ThemeData theme) {
    final activeList = _getListToDisplay();

    return Container(
      height: 60,
      width: double.infinity,
      // The portrait branch, reached by the early return above. It is easy to
      // miss - the expanded sidebar and this rail are two separate roots - and
      // missing it would leave the top bar flat in every material.
      decoration: NeuTheme.panel(themeNotifier.isDarkTheme, radius: 0),
      // The rail overflowed by 48px at the enforced 380px minimum, live, in
      // the shipped build. Nothing saw it: the overflow sweep pumped a copy of
      // a card footer defined inside the test file, so the only surface it
      // could ever check was one the app does not use.
      //
      // Ten fixed controls plus two rules do not fit in 348 logical pixels, so
      // below 460 the row tightens: the two decorative rules go, the gaps
      // halve, and the three trailing IconButtons drop Material's 48px
      // minimum box for a 34px one. Nothing is removed and nothing moves -
      // every affordance is still there, still in the same order, and still
      // above the 24px hit target this app holds itself to. The 460 boundary
      // is the measured point where the untightened row stops fitting, not a
      // round number, and the inset halves with it - 16px of air on each side
      // is a luxury a row that does not fit cannot afford.
      child: LayoutBuilder(builder: (context, constraints) {
        final tight = constraints.maxWidth < 480;
        final gap = SizedBox(width: tight ? NeuSpace.s4 : NeuSpace.s8);
        final tightBox = tight
            ? const BoxConstraints.tightFor(width: 32, height: 32)
            : null;
        final tightPad = tight ? EdgeInsets.zero : null;
        return Padding(
          padding: EdgeInsets.symmetric(
              horizontal: tight ? NeuSpace.s8 : NeuSpace.s16),
          child: Row(
        children: [
          NavScopeRow(
                  current: NavScopeTab.byIndex[widget.sidebarTab] ?? NavScopeTab.favorites,
                  onChanged: (tab) => widget.onTabChanged(tab.index),
                  isAuthenticated: widget.settings.twitchOauthToken.trim().isNotEmpty,
                ),
          gap,
          _buildSearchPopoverTrigger(theme, size: 32),
          gap,
          Tooltip(
            message: widget.sidebarTab == 0
                ? 'Refresh Favorites'
                : (widget.sidebarTab == 1 ? 'Refresh Followed List' : 'Refresh Live'),
            child: IconButton(
              icon: widget.isGlobalLoading || widget.isLoadingFollowed
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: NeuProgressRing(size: NeuProgressRingSize.sm, semanticLabel: 'Loading'),
                    )
                  : Icon(Icons.refresh, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 18),
              onPressed: widget.isGlobalLoading || widget.isLoadingFollowed ? null : widget.onRefresh,
              hoverColor: theme.primaryColor.withValues(alpha: 0.2),
              splashRadius: 20,
              padding: tightPad,
              constraints: tightBox,
            ),
          ),
          if (!tight) ...[
            const SizedBox(width: NeuSpace.s8),
            Container(
                width: 1,
                height: 24,
                color: NeuTheme.border(themeNotifier.isDarkTheme)),
          ],
          gap,
          // Flexible with a floor, not Expanded.
          //
          // The avatar strip is the channel list - in this layout it IS the
          // primary navigation - so it gets whatever the fixed controls leave.
          // At the 380px minimum that is about thirty logical pixels, and a
          // horizontal ListView handed thirty pixels renders a vertical SLICE
          // of one avatar: a rectangular crop of somebody's face wedged
          // between two icons, with no circular mask visible. It reads as a
          // rendering fault rather than as a list that scrolls.
          //
          // Below one whole item (36px avatar + 12px of margins) the strip
          // renders nothing instead. `Flexible` rather than `Expanded` so the
          // Row reclaims the space when that happens, rather than leaving a
          // hole where the slice was.
          Flexible(
            child: LayoutBuilder(builder: (context, avatarBox) {
              if (avatarBox.maxWidth < _railAvatarItemWidth) {
                return const SizedBox.shrink();
              }
              return Listener(
              onPointerSignal: (pointerSignal) {
                if (pointerSignal is PointerScrollEvent) {
                  GestureBinding.instance.pointerSignalResolver.register(pointerSignal, (event) {
                    if (event is PointerScrollEvent && _horizontalScrollController.hasClients) {
                      final delta = event.scrollDelta.dy != 0.0
                          ? event.scrollDelta.dy
                          : event.scrollDelta.dx;
                      if (delta != 0.0) {
                        final newOffset = (_horizontalScrollController.offset + delta).clamp(
                          0.0,
                          _horizontalScrollController.position.maxScrollExtent,
                        );
                        _horizontalScrollController.jumpTo(newOffset);
                      }
                    }
                  });
                }
              },
              child: ListView.builder(
                controller: _horizontalScrollController,
                scrollDirection: Axis.horizontal,
                itemCount: activeList.length,
                itemBuilder: (context, index) {
                  final ch = activeList[index];
                  final isSelected = widget.selectedChannel?.username == ch.username;
                  
                  final itemWidget = MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s8),
                      child: Tooltip(
                        message: '${ch.username} (${ch.isLive ? "LIVE: " + (ch.game ?? "Streaming") : "Offline"})',
                        child: GestureDetector(
                          onTap: () => widget.onChannelSelected(ch),
                          onDoubleTap: ch.isLive ? () => widget.onChannelDoubleTapped(ch) : null,
                          child: _buildAvatarBorder(
                            channel: ch,
                            isSelected: isSelected,
                            theme: theme,
                            child: Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                NeuAvatar(
                                  url: ch.avatarUrl,
                                  radius: 18,
                                  isDark: themeNotifier.isDarkTheme,
                                ),
                                if (ch.isLive)
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: NeuTheme.live,
                                        shape: BoxShape.circle,
                                        border: NeuTheme.statusRing(),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );

                  return ch.isLive
                      ? HoverOverlayMenu(
                          trigger: itemWidget,
                          menu: LivePreviewPopup(channel: ch),
                        )
                      : itemWidget;
                },
              ),
            );
            }),
          ),
          if (widget.sidebarTab == 0) ...[
            const SizedBox(width: NeuSpace.s6),
            _PinnedFavoritesAutomationButton(
              onPressed: _openFavoritesAutomationDialog,
              enabled: widget.sidebarTab == 0,
            ),
          ],
          if (!tight) ...[
            const SizedBox(width: NeuSpace.s8),
            Container(
                width: 1,
                height: 24,
                color: NeuTheme.border(themeNotifier.isDarkTheme)),
          ],
          gap,
          IconButton(
            icon: Icon(Icons.video_library_outlined, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
            tooltip: 'Library (downloads & history)',
            onPressed: widget.onShowLibrary,
            hoverColor: theme.primaryColor.withValues(alpha: 0.2),
            splashRadius: 20,
            padding: tightPad,
            constraints: tightBox,
          ),
          const SizedBox(width: NeuSpace.s4),
          IconButton(
            icon: Icon(Icons.settings, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
            tooltip: 'Settings',
            onPressed: widget.onShowSettings,
            hoverColor: theme.primaryColor.withValues(alpha: 0.2),
            splashRadius: 20,
            padding: tightPad,
            constraints: tightBox,
          ),
        ],
        ),
        );
      }),
    );
  }
}

/// The entry point to the Auto Download & Play manager.
///
/// Was a button showing a play triangle with an amber star that swapped to a
/// gear ON HOVER - so at rest it looked like "play something", and the only
/// way to learn otherwise was to hover it. It was also hidden entirely unless
/// the Favorites tab was selected, which meant the two settings it owns
/// (vodWatchExclusionThreshold, autoPlayPreemptLowerPriority) lived behind a
/// control that was invisible most of the time and misleading the rest.
///
/// Now: one stable icon that means "automation", always visible, and disabled
/// with a reason rather than absent when it cannot be used.
class _PinnedFavoritesAutomationButton extends StatelessWidget {
  const _PinnedFavoritesAutomationButton({
    Key? key,
    required this.onPressed,
    this.enabled = true,
    this.expanded = false,
  }) : super(key: key);

  final VoidCallback onPressed;
  final bool enabled;

  /// Show a label beside the icon, where there is room for one.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    if (!expanded) {
      return NeuIconAction(
        icon: Icons.auto_mode,
        tooltip: 'Automation — auto-play and auto-download for favorites',
        onPressed: enabled ? onPressed : null,
        disabledReason: 'switch to Favorites to configure automation',
        size: NeuActionSize.sm,
      );
    }

    return NeuButton(
      onPressed: enabled ? onPressed : null,
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      tooltip: 'Auto-play and auto-download for favorite channels',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_mode,
              size: 15,
              color: enabled
                  ? NeuTheme.text(isDark)
                  : NeuTheme.disabledText(isDark)),
          const SizedBox(width: NeuSpace.s6),
          Text('Automation',
              style: NeuType.bodySm(isDark).copyWith(
                  color: enabled
                      ? NeuTheme.text(isDark)
                      : NeuTheme.disabledText(isDark))),
        ],
      ),
    );
  }
}

class _SidebarChannelRow extends StatefulWidget {
  const _SidebarChannelRow({
    Key? key,
    required this.channel,
    required this.isSelected,
    required this.isFavorite,
    required this.showFavoriteStarAlways,
    required this.leading,
    required this.pulseController,
    required this.onSelected,
    required this.onDoubleTapped,
    required this.onPlayPressed,
    required this.onToggleFavorite,
  }) : super(key: key);

  final TwitchChannel channel;
  final bool isSelected;
  final bool isFavorite;
  final bool showFavoriteStarAlways;
  final Widget leading;
  final AnimationController pulseController;
  final ValueChanged<TwitchChannel> onSelected;
  final ValueChanged<TwitchChannel> onDoubleTapped;
  final ValueChanged<TwitchChannel> onPlayPressed;
  final ValueChanged<TwitchChannel> onToggleFavorite;

  @override
  State<_SidebarChannelRow> createState() => _SidebarChannelRowState();
}

class _SidebarChannelRowState extends State<_SidebarChannelRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    final channel = widget.channel;

    // Fixed-width slot so the play button appearing on hover cannot shift the
    // row's layout.
    final Widget playSlot = SizedBox(
      width: 32,
      height: 32,
      child: (_hovered && channel.isLive)
          ? IconButton(
              icon: Icon(Icons.play_arrow, size: 20, color: themeNotifier.accentInk),
              tooltip: 'Watch now',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              splashRadius: 16,
              onPressed: () => widget.onPlayPressed(channel),
            )
          : null,
    );

    final Widget starSlot;
    if (widget.showFavoriteStarAlways || widget.isFavorite) {
      starSlot = IconButton(
        icon: Icon(Icons.star, color: NeuTheme.favoriteText(themeNotifier.isDarkTheme), size: 18),
        onPressed: () => widget.onToggleFavorite(channel),
        tooltip: 'Remove from Favorites',
        splashRadius: 18,
      );
    } else if (_hovered) {
      starSlot = HoverStarIcon(
        isFavorite: false,
        onTap: () => widget.onToggleFavorite(channel),
      );
    } else {
      starSlot = const SizedBox(width: NeuSpace.s40);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s4),
        decoration: widget.isSelected
            ? NeuTheme.raisedDecoration(
                isDark,
                radius: NeuRadius.r12,
                border: Border.all(color: themeNotifier.accentInk, width: 1.5),
              )
            : (_hovered
                ? NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r12)
                : BoxDecoration(
                    color: NeuTheme.surface(isDark),
                    borderRadius: BorderRadius.circular(NeuRadius.r12),
                  )),
        child: NeuContextMenu(
          // The app had no right-click menus at all, so every action lived in
          // a hover-reveal or nowhere. This is where a desktop user already
          // looks for them.
          items: [
            NeuMenuItem(
              label: 'Watch now',
              icon: Icons.play_arrow,
              enabled: channel.isLive,
              onSelected: () => widget.onPlayPressed(channel),
            ),
            NeuMenuItem(
              label: widget.isFavorite
                  ? 'Remove from favorites'
                  : 'Add to favorites',
              icon: widget.isFavorite ? Icons.star_border : Icons.star,
              onSelected: () => widget.onToggleFavorite(channel),
              isDestructive: widget.isFavorite,
            ),
          ],
          child: GestureDetector(
          onDoubleTap:
              channel.isLive ? () => widget.onDoubleTapped(channel) : null,
          // See the note on the other ListTile in this file: the splash paints
          // on the nearest Material ancestor, and the row's own decorated
          // Container sits between them.
          child: Material(
            type: MaterialType.transparency,
            child: ListTile(
            contentPadding: const EdgeInsets.only(left: NeuSpace.s12, right: NeuSpace.s4),
            leading: Stack(
              children: [
                widget.leading,
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: channel.isLive ? NeuTheme.live : NeuTheme.disabledText(themeNotifier.isDarkTheme),
                      shape: BoxShape.circle,
                      border: NeuTheme.statusRing(width: 1.5),
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
                    style: NeuType.headingSm(themeNotifier.isDarkTheme,
                            color: themeNotifier.textColor)
                        .copyWith(
                            fontWeight: widget.isSelected
                                ? FontWeight.w700
                                : FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (channel.isLive)
                  AnimatedBuilder(
                    animation: widget.pulseController,
                    builder: (context, child) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s6, vertical: NeuSpace.s2),
                        decoration: BoxDecoration(
                          color: NeuTheme.live
                              .withValues(alpha: 0.7 + 0.3 * widget.pulseController.value),
                          borderRadius: BorderRadius.circular(NeuRadius.r4),
                          boxShadow: [
                            BoxShadow(
                              color: NeuTheme.live
                                  .withValues(alpha: 0.4 * widget.pulseController.value),
                              blurRadius: 4,
                            )
                          ],
                        ),
                        child: child,
                      );
                    },
                    child: Text(
                      'LIVE',
                      style: TextStyle(
                        // Intentional: 8px. The rail's LIVE pill is 20px tall
                        // and cannot hold micro's 10px without clipping; the
                        // expanded sidebar uses the real badge.
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        // Computed ink on the solid mint pill.
                        color: NeuTheme.onAccent(NeuTheme.live),
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: channel.isLoading
                ? const Padding(
                    padding: EdgeInsets.only(top: NeuSpace.s4),
                    child: NeuProgressBar(size: NeuProgressSize.xs, semanticLabel: 'Loading'),
                  )
                : Text(
                    channel.isLive ? (channel.game ?? 'Playing...') : 'Offline',
                    style: NeuType.caption(isDark),
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [playSlot, starSlot],
            ),
            onTap: () => widget.onSelected(channel),
          ),
          ),
        ),
        ),
      ),
    );
  }
}

/// A rail/bar avatar that reveals a play control on hover.
///
/// The expanded row gained a hover play button because double-click alone was,
/// in the codebase's own words, undiscoverable. The rail and horizontal bar
/// never got the same treatment, so in those layouts double-click remained the
/// ONLY way to launch a stream.
class _AvatarWithPlay extends StatefulWidget {
  const _AvatarWithPlay({required this.channel, required this.onPlay});

  final TwitchChannel channel;
  final ValueChanged<TwitchChannel> onPlay;

  @override
  State<_AvatarWithPlay> createState() => _AvatarWithPlayState();
}

class _AvatarWithPlayState extends State<_AvatarWithPlay> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final avatar = NeuAvatar(
      url: widget.channel.avatarUrl,
      radius: 18,
      isDark: themeNotifier.isDarkTheme,
    );

    if (!widget.channel.isLive) return avatar;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        alignment: Alignment.center,
        children: [
          avatar,
          if (_hovered)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: 'Watch ${widget.channel.username}',
                  icon: const Icon(Icons.play_arrow,
                      size: 18, color: Colors.white),
                  onPressed: () => widget.onPlay(widget.channel),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
