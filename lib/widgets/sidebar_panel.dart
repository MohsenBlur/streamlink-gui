import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../state/channel_search.dart';
import 'hover_overlay_menu.dart';
import 'live_rainbow_border.dart';
import 'favorites_automation_dialog.dart';
import 'interactive_popover.dart';
import 'live_preview_popup.dart';
import 'sidebar_search_popover.dart';
import 'neumorphic/neu_button.dart';
import 'neumorphic/neu_text_field.dart';
import 'neumorphic/neu_segmented_control.dart';
import 'package:flutter/gestures.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_avatar.dart';
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
    showDialog(
      context: context,
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
      color: themeNotifier.surfaceColor,
      child: widget.sidebarCollapsed
          ? _buildCollapsedSidebar(theme)
          : Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
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
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                                child: Row(
                                  children: [
                                    widget.authenticatedUserAvatar != null
                                         ? NeuAvatar(
                                             url: widget.authenticatedUserAvatar,
                                             radius: 18,
                                             isDark: themeNotifier.isDarkTheme,
                                           )
                                        : Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: theme.primaryColor.withValues(alpha: 0.15),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: theme.primaryColor.withValues(alpha: 0.4), width: 1),
                                            ),
                                            child: Icon(Icons.dashboard_outlined, color: theme.primaryColor, size: 20),
                                          ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Streamlink GUI',
                                            style: NeuTheme.titleStyle(themeNotifier.isDarkTheme, fontSize: 15),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 2),
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
                                              const SizedBox(width: 4),
                                              Expanded(
                                                child: Text(
                                                  widget.authenticatedUserLogin != null
                                                      ? '@${widget.authenticatedUserLogin}'
                                                      : 'Guest Mode',
                                                  style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 11),
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                      const SizedBox(width: 8),
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
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
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
                  const SizedBox(height: 8),
                ],

                // Global Actions Toolbar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          depth: 3.0,
                          onPressed: widget.isGlobalLoading || widget.isLoadingFollowed ? null : widget.onRefresh,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (widget.isGlobalLoading || widget.isLoadingFollowed)
                                 SizedBox(
                                   width: 14,
                                   height: 14,
                                   child: CircularProgressIndicator(strokeWidth: 1.8, color: theme.primaryColor),
                                 )
                              else
                                const Icon(Icons.refresh, size: 14),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  widget.sidebarTab == 0
                                      ? 'Refresh Favorites'
                                      : (widget.sidebarTab == 1 ? 'Refresh Follows' : 'Refresh Live'),
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (widget.sidebarTab == 0) ...[
                        const SizedBox(width: 8),
                        _PinnedFavoritesAutomationButton(
                          theme: theme,
                          onPressed: _openFavoritesAutomationDialog,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),

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
                        return const Center(child: CircularProgressIndicator());
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
                            style: NeuTheme.subtextStyle(themeNotifier.isDarkTheme, fontSize: 12),
                          ),
                        );
                      }

                      final itemCount = listToDisplay.length + (showAddPrompt ? 1 : 0);

                      return ListView.builder(
                        itemCount: itemCount,
                        itemBuilder: (context, index) {
                          if (showAddPrompt && index == 0) {
                            return Container(
                              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: theme.primaryColor.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: theme.primaryColor.withValues(alpha: 0.25),
                                  width: 1,
                                ),
                              ),
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                                leading: Icon(Icons.add_circle_outline, color: theme.primaryColor, size: 20),
                                title: Text(
                                  "Add '$query' to Favorites",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: theme.primaryColor,
                                    fontSize: 13,
                                  ),
                                ),
                                trailing: widget.isAdding
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: theme.primaryColor),
                                      )
                                     : Icon(Icons.chevron_right, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 18),
                                onTap: widget.isAdding ? null : () => widget.onAddChannel(query),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme), width: 1)),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.settings, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                        tooltip: 'Settings',
                        onPressed: widget.onShowSettings,
                        hoverColor: theme.primaryColor.withValues(alpha: 0.2),
                        splashRadius: 20,
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: Icon(Icons.video_library_outlined, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                        tooltip: 'Library (downloads & history)',
                        onPressed: widget.onShowLibrary,
                        hoverColor: theme.primaryColor.withValues(alpha: 0.2),
                        splashRadius: 20,
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
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
        const SizedBox(height: 12),
        Tooltip(
          message: 'Dashboard Hub (Return Home)',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: widget.onGoToDashboard,
              child: widget.authenticatedUserAvatar != null
                  ? NeuAvatar(
                      url: widget.authenticatedUserAvatar,
                      radius: 16,
                      isDark: themeNotifier.isDarkTheme,
                    )
                  : Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: theme.primaryColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: theme.primaryColor.withValues(alpha: 0.4), width: 1),
                      ),
                      child: Icon(Icons.dashboard_outlined, color: theme.primaryColor, size: 18),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        IconButton(
          icon: Icon(Icons.keyboard_double_arrow_right, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 20),
          tooltip: 'Expand sidebar',
          onPressed: () => widget.onToggleCollapse(false),
          hoverColor: theme.primaryColor.withValues(alpha: 0.2),
          splashRadius: 20,
        ),
        const SizedBox(height: 10),
        Divider(color: NeuTheme.border(themeNotifier.isDarkTheme), height: 1.5, thickness: 1.5),
        const SizedBox(height: 12),
        
        // Collapsed Tab Toggle
        (() {
          bool isHovered = false;
          return StatefulBuilder(
            builder: (context, setHoverState) {
              return MouseRegion(
                onEnter: (_) => setHoverState(() => isHovered = true),
                onExit: (_) => setHoverState(() => isHovered = false),
                child: Tooltip(
                  message: widget.sidebarTab == 0
                      ? "Favorites\nSwitch to Followed"
                      : (widget.sidebarTab == 1 ? "Followed List\nSwitch to Live" : "Live Channels\nSwitch to Favorites"),
                  waitDuration: Duration.zero,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        widget.onTabChanged((widget.sidebarTab + 1) % 3);
                      },
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: theme.primaryColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.primaryColor, width: 1.5),
                        ),
                        child: Icon(
                          isHovered
                              ? Icons.swap_horiz
                              : (widget.sidebarTab == 0
                                  ? Icons.star
                                  : (widget.sidebarTab == 1 ? Icons.people : Icons.live_tv)),
                          color: theme.primaryColor,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        })(),
        
        const SizedBox(height: 12),

        // Compact layouts previously had no way to search/add channels or to
        // reach the automation manager at all.
        _buildSearchPopoverTrigger(theme),
        const SizedBox(height: 12),
        if (widget.sidebarTab == 0) ...[
          _PinnedFavoritesAutomationButton(
            theme: theme,
            onPressed: _openFavoritesAutomationDialog,
          ),
          const SizedBox(height: 12),
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
                    child: CircularProgressIndicator(strokeWidth: 2, color: theme.primaryColor),
                  )
                : Icon(Icons.refresh, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 18),
            onPressed: widget.isGlobalLoading || widget.isLoadingFollowed ? null : widget.onRefresh,
            hoverColor: theme.primaryColor.withValues(alpha: 0.2),
            splashRadius: 20,
          ),
        ),
        
        const SizedBox(height: 10),
        Divider(color: NeuTheme.border(themeNotifier.isDarkTheme), height: 1, thickness: 1),
        const SizedBox(height: 12),
        
        Expanded(
          child: ListView.builder(
            itemCount: activeList.length,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemBuilder: (context, index) {
              final ch = activeList[index];
              final isSelected = widget.selectedChannel?.username == ch.username;
              
              final itemWidget = MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
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
                                  border: Border.all(color: themeNotifier.surfaceColor, width: 1),
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
          padding: const EdgeInsets.symmetric(vertical: 12),
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: NeuTheme.border(themeNotifier.isDarkTheme), width: 1)),
          ),
          child: Column(
            children: [
              IconButton(
                icon: Icon(Icons.video_library_outlined, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                tooltip: 'Library (downloads & history)',
                onPressed: widget.onShowLibrary,
                hoverColor: theme.primaryColor.withValues(alpha: 0.2),
                splashRadius: 20,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(height: 14),
              IconButton(
                icon: Icon(Icons.settings, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
                tooltip: 'Settings',
                onPressed: widget.onShowSettings,
                hoverColor: theme.primaryColor.withValues(alpha: 0.2),
                splashRadius: 20,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
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
          decoration: NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 8),
          child: Icon(Icons.search, size: size * 0.5, color: NeuTheme.text(themeNotifier.isDarkTheme)),
        ),
      ),
    );
  }

  Widget _buildHorizontalTopBar(ThemeData theme) {
    final activeList = _getListToDisplay();

    return Container(
      height: 60,
      width: double.infinity,
      color: themeNotifier.surfaceColor,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          (() {
            bool isHovered = false;
            return StatefulBuilder(
              builder: (context, setHoverState) {
                return MouseRegion(
                  onEnter: (_) => setHoverState(() => isHovered = true),
                  onExit: (_) => setHoverState(() => isHovered = false),
                  child: Tooltip(
                    message: widget.sidebarTab == 0
                        ? "Favorites\nSwitch to Followed"
                        : (widget.sidebarTab == 1 ? "Followed List\nSwitch to Live" : "Live Channels\nSwitch to Favorites"),
                    waitDuration: Duration.zero,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          widget.onTabChanged((widget.sidebarTab + 1) % 3);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: theme.primaryColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: theme.primaryColor, width: 1.5),
                          ),
                          child: Icon(
                            isHovered
                                ? Icons.swap_horiz
                                : (widget.sidebarTab == 0
                                    ? Icons.star
                                    : (widget.sidebarTab == 1 ? Icons.people : Icons.live_tv)),
                            color: theme.primaryColor,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          })(),
          const SizedBox(width: 8),
          _buildSearchPopoverTrigger(theme, size: 32),
          const SizedBox(width: 8),
          Tooltip(
            message: widget.sidebarTab == 0
                ? 'Refresh Favorites'
                : (widget.sidebarTab == 1 ? 'Refresh Followed List' : 'Refresh Live'),
            child: IconButton(
              icon: widget.isGlobalLoading || widget.isLoadingFollowed
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: theme.primaryColor),
                    )
                  : Icon(Icons.refresh, color: NeuTheme.text(themeNotifier.isDarkTheme), size: 18),
              onPressed: widget.isGlobalLoading || widget.isLoadingFollowed ? null : widget.onRefresh,
              hoverColor: theme.primaryColor.withValues(alpha: 0.2),
              splashRadius: 20,
            ),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 24, color: NeuTheme.border(themeNotifier.isDarkTheme)),
          const SizedBox(width: 8),
          Expanded(
            child: Listener(
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
                      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
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
                                        border: Border.all(color: themeNotifier.surfaceColor, width: 1),
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
          ),
          if (widget.sidebarTab == 0) ...[
            const SizedBox(width: 6),
            _PinnedFavoritesAutomationButton(
              theme: theme,
              onPressed: _openFavoritesAutomationDialog,
            ),
          ],
          const SizedBox(width: 8),
          Container(width: 1, height: 24, color: NeuTheme.border(themeNotifier.isDarkTheme)),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.video_library_outlined, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
            tooltip: 'Library (downloads & history)',
            onPressed: widget.onShowLibrary,
            hoverColor: theme.primaryColor.withValues(alpha: 0.2),
            splashRadius: 20,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(Icons.settings, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 20),
            tooltip: 'Settings',
            onPressed: widget.onShowSettings,
            hoverColor: theme.primaryColor.withValues(alpha: 0.2),
            splashRadius: 20,
          ),
        ],
      ),
    );
  }
}

class _PinnedFavoritesAutomationButton extends StatefulWidget {
  final ThemeData theme;
  final VoidCallback onPressed;

  const _PinnedFavoritesAutomationButton({
    Key? key,
    required this.theme,
    required this.onPressed,
  }) : super(key: key);

  @override
  State<_PinnedFavoritesAutomationButton> createState() => _PinnedFavoritesAutomationButtonState();
}

class _PinnedFavoritesAutomationButtonState extends State<_PinnedFavoritesAutomationButton> {
  bool isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: 'Auto Download & Play',
        waitDuration: Duration.zero,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(7),
            decoration: isHovered
                ? NeuTheme.raisedDecoration(
                    themeNotifier.isDarkTheme,
                    radius: 8,
                    border: Border.all(color: widget.theme.primaryColor, width: 1.5),
                  )
                : NeuTheme.raisedDecoration(themeNotifier.isDarkTheme, radius: 8),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  isHovered ? Icons.settings : Icons.play_arrow,
                  color: isHovered ? widget.theme.primaryColor : NeuTheme.text(themeNotifier.isDarkTheme),
                  size: 16,
                ),
                Positioned(
                  right: -5,
                  bottom: -5,
                  child: Container(
                    padding: const EdgeInsets.all(0.5),
                    decoration: BoxDecoration(
                      color: NeuTheme.surface(themeNotifier.isDarkTheme),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.star,
                      color: NeuTheme.favoriteText(themeNotifier.isDarkTheme),
                      size: 9,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// One channel row in the expanded sidebar list.
///
/// A real StatefulWidget keyed by channel: the hover state previously lived in
/// a per-item closure + StatefulBuilder, so every 60-second poll rebuild
/// destroyed it mid-hover. Also hosts the hover play affordance - the row's
/// only launch gesture used to be an undiscoverable double-click.
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
    final theme = Theme.of(context);
    final isDark = themeNotifier.isDarkTheme;
    final channel = widget.channel;

    // Fixed-width slot so the play button appearing on hover cannot shift the
    // row's layout.
    final Widget playSlot = SizedBox(
      width: 32,
      height: 32,
      child: (_hovered && channel.isLive)
          ? IconButton(
              icon: Icon(Icons.play_arrow, size: 20, color: theme.primaryColor),
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
      starSlot = const SizedBox(width: 40);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: widget.isSelected
            ? NeuTheme.raisedDecoration(
                isDark,
                radius: 10,
                border: Border.all(color: theme.primaryColor, width: 1.5),
              )
            : (_hovered
                ? NeuTheme.raisedDecoration(isDark, radius: 10)
                : BoxDecoration(
                    color: NeuTheme.surface(isDark),
                    borderRadius: BorderRadius.circular(10),
                  )),
        child: GestureDetector(
          onDoubleTap:
              channel.isLive ? () => widget.onDoubleTapped(channel) : null,
          child: ListTile(
            contentPadding: const EdgeInsets.only(left: 12, right: 4),
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
                      border: Border.all(color: themeNotifier.surfaceColor, width: 1.5),
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
                    style: TextStyle(
                      fontWeight:
                          widget.isSelected ? FontWeight.bold : FontWeight.w600,
                      color: themeNotifier.textColor,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (channel.isLive)
                  AnimatedBuilder(
                    animation: widget.pulseController,
                    builder: (context, child) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: NeuTheme.live
                              .withValues(alpha: 0.7 + 0.3 * widget.pulseController.value),
                          borderRadius: BorderRadius.circular(4),
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
                    padding: EdgeInsets.only(top: 4),
                    child: LinearProgressIndicator(minHeight: 1.5),
                  )
                : Text(
                    channel.isLive ? (channel.game ?? 'Playing...') : 'Offline',
                    style: NeuTheme.subtextStyle(isDark, fontSize: 11),
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
    );
  }
}
