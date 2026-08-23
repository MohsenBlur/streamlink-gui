import 'package:flutter/material.dart';

import '../models/twitch_channel.dart';
import '../state/channel_search.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_avatar.dart';
import '../theme/theme_notifier.dart';
import 'neumorphic/neu_text_field.dart';

/// Search panel for layouts where the inline search field has no room: the
/// collapsed sidebar rail and the narrow horizontal top bar. Those layouts
/// previously had no way to search or add channels at all.
class SidebarSearchPopover extends StatefulWidget {
  const SidebarSearchPopover({
    Key? key,
    required this.controller,
    required this.channels,
    required this.tab,
    required this.onSelect,
    required this.onPlay,
    required this.onAdd,
    required this.close,
  }) : super(key: key);

  /// The shared sidebar search controller, so this panel and the expanded
  /// field always show the same query.
  final TextEditingController controller;

  /// The current tab's full (unfiltered) channel list.
  final List<TwitchChannel> channels;

  /// 0 = Favorites, 1 = Followed, 2 = Live.
  final int tab;

  final ValueChanged<TwitchChannel> onSelect;
  final ValueChanged<TwitchChannel> onPlay;
  final ValueChanged<String> onAdd;
  final VoidCallback close;

  @override
  State<SidebarSearchPopover> createState() => _SidebarSearchPopoverState();
}

class _SidebarSearchPopoverState extends State<SidebarSearchPopover> {
  static const int _maxResults = 8;

  void _submit() {
    final action = resolveSearchSubmit(
      tab: widget.tab,
      query: widget.controller.text,
      visible: widget.channels,
    );
    switch (action.type) {
      case SubmitActionType.launchLive:
        widget.onSelect(action.channel!);
        widget.onPlay(action.channel!);
        widget.close();
      case SubmitActionType.selectOnly:
        widget.onSelect(action.channel!);
        widget.close();
      case SubmitActionType.addFavorite:
        widget.onAdd(action.query);
        widget.close();
      case SubmitActionType.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    final theme = Theme.of(context);
    final query = widget.controller.text.trim();
    final results = filterChannels(widget.channels, query);
    final hasExactMatch =
        widget.channels.any((c) => c.username.toLowerCase() == query.toLowerCase());
    final showAddRow = widget.tab == 0 && query.isNotEmpty && !hasExactMatch;

    return Container(
      width: 300,
      constraints: const BoxConstraints(maxHeight: 380),
      padding: const EdgeInsets.all(NeuSpace.s12),
      decoration: NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NeuTextField(
            controller: widget.controller,
            hintText: widget.tab == 0
                ? 'Search or add username...'
                : 'Search channels...',
            prefixIcon: Icons.search,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            onClear: () => setState(() {}),
          ),
          const SizedBox(height: NeuSpace.s8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                if (showAddRow)
                  _row(
                    leading: Icon(Icons.add_circle_outline,
                        color: themeNotifier.accentInk, size: 18),
                    title: "Add '$query' to Favorites",
                    titleColor: theme.primaryColor,
                    onTap: () {
                      widget.onAdd(query);
                      widget.close();
                    },
                  ),
                if (results.isEmpty && !showAddRow)
                  Padding(
                    padding: const EdgeInsets.all(NeuSpace.s12),
                    child: Text(
                      query.isEmpty
                          ? 'Type to search this tab.'
                          : "No channels match '$query'.",
                      style: NeuType.bodySm(isDark, color: NeuTheme.subtext(isDark)),
                    ),
                  ),
                ...results.take(_maxResults).map((channel) {
                  return _row(
                    leading: Stack(
                      children: [
                        NeuAvatar(
                          url: channel.avatarUrl,
                          radius: NeuRadius.r12,
                          isDark: isDark,
                        ),
                        if (channel.isLive)
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: NeuTheme.live,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: NeuTheme.surface(isDark), width: 1),
                              ),
                            ),
                          ),
                      ],
                    ),
                    title: channel.username,
                    trailing: channel.isLive
                        ? IconButton(
                            icon: Icon(Icons.play_arrow,
                                size: 18, color: themeNotifier.accentInk),
                            tooltip: 'Watch now',
                            splashRadius: 16,
                            onPressed: () {
                              widget.onPlay(channel);
                              widget.close();
                            },
                          )
                        : null,
                    onTap: () {
                      widget.onSelect(channel);
                      widget.close();
                    },
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row({
    required Widget leading,
    required String title,
    Color? titleColor,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    final isDark = themeNotifier.isDarkTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s6),
        child: Row(
          children: [
            leading,
            const SizedBox(width: NeuSpace.s8),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: NeuType.bodyStrong(isDark, color: titleColor ?? NeuTheme.text(isDark)),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
