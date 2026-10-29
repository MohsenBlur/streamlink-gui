import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/twitch_channel.dart';
import '../../models/twitch_video.dart';
import '../../state/activity_state.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../horizontal_mouse_scrollable.dart';
import '../hover_overlay_menu.dart';
import '../live_preview_popup.dart';
import '../neumorphic/neu_avatar.dart';
import '../neumorphic/neu_button.dart';
import '../neumorphic/neu_focusable.dart';
import '../neumorphic/neu_progress.dart';
import 'double_click_listener.dart';
import 'edge_fade.dart';
import 'empty_state.dart';
import 'section_header.dart';

/// Home: what is live among the favourites, what to continue watching, the
/// downloads running and the quick actions - the screen shown when no
/// channel is open.
///
/// Moved out of `_MainScreenState.build` as it was. The "Continue watching"
/// strip's scroll position and edge fades are the screen's, handed in, so
/// they outlive this view the way they always did: coming back to Home finds
/// the strip where it was left.
class HomeView extends StatelessWidget {
  const HomeView({
    super.key,
    required this.channels,
    required this.recentVods,
    required this.runningDownloads,
    required this.downloadedCount,
    required this.accountLogin,
    required this.recentScroll,
    required this.fadeLeft,
    required this.fadeRight,
    required this.onRecentScrolled,
    required this.onAddChannel,
    required this.onSelectChannel,
    required this.onLaunchLive,
    required this.onPlayRecent,
    required this.onOpenLibrary,
    required this.onOpenSettings,
    required this.onConnectAccount,
  });

  /// The favourites, in order.
  final List<TwitchChannel> channels;
  final List<TwitchVideo> recentVods;
  final List<ActivityItem> runningDownloads;
  final int downloadedCount;

  /// The connected account's login, or null when none is connected.
  final String? accountLogin;

  final ScrollController recentScroll;
  final bool fadeLeft;
  final bool fadeRight;

  /// The recents strip scrolled; its fades may need to change.
  final VoidCallback onRecentScrolled;

  /// "Add a channel": the sidebar's search takes it from there.
  final VoidCallback onAddChannel;
  final void Function(TwitchChannel channel) onSelectChannel;

  /// A live card double-tapped.
  final void Function(TwitchChannel channel) onLaunchLive;
  final void Function(TwitchVideo video) onPlayRecent;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenSettings;
  final VoidCallback onConnectAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final liveFavorites = channels.where((c) => c.isLive).toList();

    return SingleChildScrollView(
            padding: const EdgeInsets.all(NeuSpace.s32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title Header
                Row(
                  children: [
                    Icon(Icons.home_outlined, size: 26, color: themeNotifier.accentInk),
                    const SizedBox(width: NeuSpace.s12),
                    Text(
                      'Home',
                      style: NeuType.display(themeNotifier.isDarkTheme),
                    ),
                  ],
                ),
                const SizedBox(height: NeuSpace.s6),
                Text(
                  'Pick a channel from the sidebar, or jump back into something below.',
                  style: NeuType.body(themeNotifier.isDarkTheme, color: NeuTheme.subtext(themeNotifier.isDarkTheme)),
                ),
                const SizedBox(height: NeuSpace.s24),

          // Order matters here. This screen used to lead with the
          // downloader and put live channels third, which is the priority
          // order of a download manager rather than of a Twitch client.
          // What is live is the most perishable thing on the page, so it
          // goes first; downloads are long-running and can wait.
          // Live Channels Section
          SectionHeader(
            title: 'Live now',
            count: liveFavorites.isEmpty ? null : liveFavorites.length,
          ),
          const SizedBox(height: NeuSpace.s12),
          if (liveFavorites.isEmpty)
            Container(
              width: double.infinity,
              decoration: NeuTheme.sunkenDecoration(
                  themeNotifier.isDarkTheme,
                  radius: NeuRadius.r12),
              child: channels.isEmpty
                  // Two different situations that shared one sentence. With no
                  // channels at all the answer is an action, not information.
                  ? EmptyState(
                      icon: Icons.person_add_alt,
                      title: 'No channels yet',
                      message: 'Add a streamer to see when they go live and to '
                          'browse their past broadcasts.',
                      compact: true,
                      action: NeuButton(
                        onPressed: onAddChannel,
                        padding: const EdgeInsets.symmetric(
                            horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                        borderRadius: BorderRadius.circular(NeuRadius.r8),
                        child: const Text('Add a channel',
                            style: NeuType.bodySmMetrics),
                      ),
                    )
                  : EmptyState(
                      icon: Icons.bedtime_outlined,
                      title: 'Nobody is live',
                      message: 'None of your favorite channels are streaming '
                          'right now.',
                      compact: true,
                    ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              // A shrink-wrapped, never-scrolling grid's clip does no work -
              // except amputating the boundary tiles' cast shadows exactly at
              // the grid's edge. Clip.none lets them land in the page's own
              // scroll padding, which is sitting right there.
              clipBehavior: Clip.none,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                mainAxisExtent: 130,
              ),
              itemCount: liveFavorites.length,
              itemBuilder: (context, index) {
                final channel = liveFavorites[index];
                // A Tab stop that Enter opens, as a VOD card and a sidebar
                // row are: Home's two strips were mouse-only.
                final itemCard = NeuFocusable(
                  onActivate: () => onSelectChannel(channel),
                  semanticLabel: '${channel.username}, live: '
                      '${channel.streamTitle ?? 'No Stream Title'}',
                  focusRadius: NeuRadius.r12,
                  // A click opens the channel at once, a double-click also
                  // plays it. GestureDetector(onDoubleTap:) held every single
                  // click for the double-tap timeout, as it did the
                  // sidebar's live rows (see DoubleClickListener). The click
                  // takes Home away, so its second click is held for it.
                  child: DoubleClickListener(
                  tapLeaves: true,
                  onTap: () => onSelectChannel(channel),
                  onDoubleTap: () => onLaunchLive(channel),
                  builder: (onTap) => GestureDetector(
                  onTap: onTap,
                  child: Container(
                    padding: const EdgeInsets.all(NeuSpace.s12),
                    decoration: NeuTheme.raisedDecoration(
                      themeNotifier.isDarkTheme,
                      radius: NeuRadius.r12,
                      border: Border.all(color: theme.primaryColor.withValues(alpha: 0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            NeuAvatar(
                              url: channel.avatarUrl,
                              radius: 18,
                              isDark: themeNotifier.isDarkTheme,
                              // This one sits on a coloured card, so it keeps
                              // its transparent ground and brighter icon.
                              backgroundColor: Colors.transparent,
                              iconColor: NeuTheme.text(themeNotifier.isDarkTheme),
                            ),
                            const SizedBox(width: NeuSpace.s8),
                            Expanded(
                              child: Text(
                                channel.username,
                                style: NeuType.headingSm(themeNotifier.isDarkTheme),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: NeuSpace.s8),
                        Expanded(
                          child: Text(
                            channel.streamTitle ?? 'No Stream Title',
                            style: NeuType.caption(themeNotifier.isDarkTheme),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: NeuSpace.s4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Expanded, not a bare Text. `overflow: ellipsis`
                            // can only engage when the Text is given a bounded
                            // width; in an unconstrained Row it reports its
                            // full intrinsic width instead and the ROW
                            // overflows. These tiles are maxCrossAxisExtent
                            // 220 and the window minimum is 380 wide, so a
                            // long game name overflowed in the normal case,
                            // not an exotic one.
                            Expanded(
                              child: Text(
                                channel.game ?? 'Unknown Game',
                                style: NeuType.plate(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: NeuSpace.s8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.remove_red_eye, size: 10, color: NeuTheme.liveText(themeNotifier.isDarkTheme)),
                                const SizedBox(width: NeuSpace.s4),
                                Text(
                                  channel.viewerCount != null ? '${channel.viewerCount}' : '0',
                                  style: NeuType.caption(themeNotifier.isDarkTheme),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  ),
                  ),
                );

                return HoverOverlayMenu(
                  trigger: itemCard,
                  menu: LivePreviewPopup(channel: channel),
                );
              },
            ),
          const SizedBox(height: NeuSpace.s32),

          // Recently Watched VODs (Conditional)
          if (recentVods.isNotEmpty) ...[
            SectionHeader(title: 'Continue watching'),
            const SizedBox(height: NeuSpace.s12),
            SizedBox(
              height: 135 + NeuShadowRoom.above + NeuShadowRoom.below,
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) {
                  onRecentScrolled();
                  return false;
                },
                child: EdgeFade(
                  left: fadeLeft,
                  right: fadeRight,
                  child: HorizontalMouseScrollable(
                controller: recentScroll,
                // Shadow clearance comes from the scroller itself now -
                // NeuShadowRoom.strip, one definition for every strip.
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: List.generate(recentVods.length, (index) {
                    final video = recentVods[index];
                    final w = 240;
                    final h = 135;
                    final thumbUrl = video.thumbnailUrl.isNotEmpty
                        ? video.thumbnailUrl.replaceAll('%{width}', w.toString()).replaceAll('%{height}', h.toString())
                        : null;

                    bool isHovered = false;

                    final progressPct = ((video.watchProgress ?? 0.0) * 100).toInt();

                    return StatefulBuilder(
                      builder: (context, setHoverState) {
                        // The gap to the next card sits outside it, so the
                        // focus ring below is drawn round the card alone.
                        return Padding(
                          padding: const EdgeInsets.only(right: NeuSpace.s12),
                          child: MouseRegion(
                          onEnter: (_) => setHoverState(() => isHovered = true),
                          onExit: (_) => setHoverState(() => isHovered = false),
                          cursor: SystemMouseCursors.click,
                          child: Tooltip(
                            message: '${video.title}\nResume at $progressPct% (${video.duration})',
                            // Tab and Enter resume it too, as they play a
                            // VOD card in the grid.
                            child: NeuFocusable(
                              onActivate: () => onPlayRecent(video),
                              semanticLabel:
                                  '${video.title}, resume at $progressPct%',
                              focusRadius: NeuRadius.r12,
                              child: GestureDetector(
                              onTap: () => onPlayRecent(video),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                child: Container(
                                  width: w.toDouble(),
                                  height: h.toDouble(),
                                  // A caller border REPLACES the material's
                                  // edge, so a transparent width-0 border at
                                  // rest deleted the bevel and zeroed the
                                  // decoration padding - and the hover flip
                                  // to 1.5px shifted the card's contents.
                                  decoration: NeuTheme.raisedDecoration(
                                    themeNotifier.isDarkTheme,
                                    radius: NeuRadius.r12,
                                    border: isHovered
                                        ? Border.all(
                                            color: theme.primaryColor,
                                            width: 1.5)
                                        : null,
                                  ),
                                  child: ClipRRect(
                                    // Concentric: inner = outer - inset, and
                                    // the inset is the material's 1px edge.
                                    borderRadius: BorderRadius.circular(NeuRadius.inner(NeuRadius.r12, 1)),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Stack(
                                            children: [
                                              Positioned.fill(
                                                child: thumbUrl != null
                                                    ? Image.network(
                                                        thumbUrl,
                                                        fit: BoxFit.cover,
                                                        // A missing-artwork
                                                        // slot is a recessed
                                                        // screen; the raised
                                                        // token put the
                                                        // lightest ground
                                                        // where the darkest
                                                        // belongs. Matches
                                                        // the Library's
                                                        // fallback.
                                                        errorBuilder: (context, error, stackTrace) => Container(
                                                          color: NeuTheme.wellSurface(themeNotifier.isDarkTheme),
                                                          child: Icon(Icons.movie, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 36),
                                                        ),
                                                      )
                                                    : Container(
                                                        color: NeuTheme.wellSurface(themeNotifier.isDarkTheme),
                                                        child: Icon(Icons.movie, color: NeuTheme.subtext(themeNotifier.isDarkTheme), size: 36),
                                                      ),
                                              ),
                                              if (isHovered)
                                                Positioned.fill(
                                                  child: Container(
                                                    // Intentional: scrim over video artwork, theme-independent.
                                                    color: Colors.black45,
                                                    child: Center(
                                                      child: Container(
                                                        padding: const EdgeInsets.all(NeuSpace.s8),
                                                        decoration: BoxDecoration(
                                                          color: theme.primaryColor,
                                                          shape: BoxShape.circle,
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: theme.primaryColor.withValues(alpha: 0.5),
                                                              blurRadius: 10,
                                                            )
                                                          ],
                                                        ),
                                                        child: Icon(Icons.play_arrow, color: themeNotifier.onPrimaryColor, size: 24),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              Positioned(
                                                bottom: 4,
                                                right: 6,
                                                // Intentional: white-on-black pill over video artwork, theme-independent.
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s4, vertical: NeuSpace.s2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.75),
                                                    borderRadius: BorderRadius.circular(NeuRadius.r4),
                                                  ),
                                                  child: Text(
                                                    video.duration,
                                                    style: NeuType.plate(themeNotifier.isDarkTheme, color: Colors.white),
                                                  ),
                                                ),
                                              ),
                                              if (video.watchProgress != null && video.watchProgress! > 0.0)
                                                Positioned(
                                                  bottom: 0,
                                                  left: 0,
                                                  right: 0,
                                                  child: Container(
                                                    height: 3,
                                                    // Intentional: track scrim over video artwork.
                                                    color: Colors.black45,
                                                    child: Align(
                                                      alignment: Alignment.centerLeft,
                                                      child: FractionallySizedBox(
                                                        widthFactor: (video.watchProgress ?? 0.0).clamp(0.0, 1.0),
                                                        child: Container(
                                                          color: theme.primaryColor,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        Container(
                                          // No fill: the card's own lit
                                          // surface shows behind the title.
                                          // With the thumbnail above and a
                                          // flat strip below, zero pixels of
                                          // the card's material were visible
                                          // - a picture of a card, not a
                                          // machined part.
                                          padding: const EdgeInsets.all(NeuSpace.s8),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                video.title,
                                                style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: NeuTheme.text(themeNotifier.isDarkTheme)),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: NeuSpace.s2),
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                children: [
                                                  Text(
                                                    video.publishedAt.toLocal().toString().substring(0, 10),
                                                    style: NeuType.caption(themeNotifier.isDarkTheme),
                                                  ),
                                                  if (progressPct > 0)
                                                    Text(
                                                      '$progressPct%',
                                                      style: NeuType.plate(themeNotifier.isDarkTheme, color: themeNotifier.accentInk),
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
                          ),
                          ),
                        );
                      },
                    );
                  }),
                ),
              ),
                ),
              ),
            ),
            const SizedBox(height: NeuSpace.s24),
          ],

          // Active Downloads card (Conditional)
          if (runningDownloads.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(NeuSpace.s16),
              // Through the engine, not around it: this was the only card on
              // Home with a hand-rolled BoxDecoration - accent gradient wash,
              // outline, glow - so it had no bevel, no grain and no cast
              // shadow agreeing with the light, and read as a web promo
              // banner taped onto the rack. The accent identity survives as
              // a tinted base plus ring; the material does the rest.
              decoration: NeuTheme.raised(
                themeNotifier.isDarkTheme,
                radius: NeuRadius.r12,
                base: Color.alphaBlend(
                    theme.primaryColor.withValues(alpha: 0.12),
                    themeNotifier.surfaceColor),
                border: Border.all(
                    color: theme.primaryColor.withValues(alpha: 0.3),
                    width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(builder: (context, header) => Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // The title gives way to the button: at the 380px
                      // minimum the two needed 42px more than the card had.
                      Flexible(
                        child: Row(
                          children: [
                            Icon(Icons.downloading, color: themeNotifier.accentInk, size: 20),
                            const SizedBox(width: NeuSpace.s8),
                            Flexible(
                              child: Text(
                                'Active Downloads Running',
                                style: NeuType.headingSm(themeNotifier.isDarkTheme),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ...but never past the title's icon: at 150% text in
                      // that window the button's label alone left the icon
                      // no room. Held to what is left, the label ellipsizes.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth: math.max(0, header.maxWidth - 28)),
                        child: TextButton.icon(
                          onPressed: onOpenLibrary,
                          icon: const Icon(Icons.open_in_new, size: 14),
                          label: const Text('Open Library',
                              style: NeuType.labelMetrics,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                  )),
                  const SizedBox(height: NeuSpace.s12),
                  ...runningDownloads.take(2).map((item) {
                    final progress = item.progress ?? 0.0;
                    final taskText = item.status ?? 'Downloading...';
                    final title = item.label;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: NeuSpace.s8),
                      child: LayoutBuilder(builder: (context, row) => Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: NeuType.bodySm(themeNotifier.isDarkTheme),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: NeuSpace.s4),
                                NeuProgressBar(
                                  value: progress,
                                  size: NeuProgressSize.sm,
                                  semanticLabel: 'Download progress',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: NeuSpace.s16),
                          // At most 40% of the row, whatever its 25 characters
                          // measure: the title and its bar keep the rest.
                          ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: row.maxWidth * 0.4),
                            child: Text(
                              taskText.length > 25 ? '${taskText.substring(0, 22)}...' : taskText,
                              style: NeuType.caption(themeNotifier.isDarkTheme),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      )),
                    );
                  }).toList(),
                ],
              ),
            ),
            const SizedBox(height: NeuSpace.s24),
          ],

          // Quick Action Cards
          SectionHeader(title: 'Quick actions'),
          const SizedBox(height: NeuSpace.s12),
          GridView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            // Same reasoning as the Live-now grid: the clip only ever cuts
            // the bottom row's shadow - the last thing on the Home page.
            clipBehavior: Clip.none,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              mainAxisExtent: 90,
            ),
            children: [
              QuickActionCard(
                icon: Icons.settings,
                title: 'Open Settings',
                subtitle: 'Configure Players & Themes',
                onTap: onOpenSettings,
              ),
              QuickActionCard(
                icon: Icons.video_library,
                title: 'Library',
                subtitle:
                    '$downloadedCount downloaded VOD${downloadedCount == 1 ? '' : 's'} & history',
                onTap: onOpenLibrary,
              ),
              QuickActionCard(
                icon: Icons.account_circle,
                title: 'Twitch Account',
                subtitle: accountLogin != null ? 'Logged in as $accountLogin' : 'Connect Account',
                onTap: () {
                  if (accountLogin == null) {
                    onConnectAccount();
                  } else {
                    onOpenSettings();
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One of Home's quick actions: a raised card that lifts on hover.
class QuickActionCard extends StatelessWidget {
  const QuickActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    bool isHovered = false;
    return StatefulBuilder(
      builder: (context, setHoverState) {
        return MouseRegion(
          onEnter: (_) => setHoverState(() => isHovered = true),
          onExit: (_) => setHoverState(() => isHovered = false),
          cursor: SystemMouseCursors.click,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(NeuRadius.r12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              transform: Matrix4.translationValues(0, isHovered ? -2 : 0, 0),
              padding: const EdgeInsets.all(NeuSpace.s12),
              decoration: NeuTheme.raisedDecoration(
                themeNotifier.isDarkTheme,
                radius: NeuRadius.r12,
                // Border only when it exists - see the strip cards.
                // The card hover grammar, same as the VOD cards: -2px lift
                // with a 0.6-alpha ring. Full alpha here made near-identical
                // cards light up at two different strengths in one window.
                border: isHovered
                    ? Border.all(
                        color: theme.primaryColor.withValues(alpha: 0.6),
                        width: 1.5)
                    : null,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(NeuSpace.s8),
                    // A pocket cut into the card, not a sticker on it - the
                    // dashboard header does this same job with sunken chips,
                    // and the two screens should speak one language.
                    decoration: NeuTheme.sunken(
                      themeNotifier.isDarkTheme,
                      radius: NeuRadius.r8,
                      depth: NeuElevation.d1,
                      base: Color.alphaBlend(
                          theme.primaryColor.withValues(alpha: 0.12),
                          NeuTheme.wellSurface(themeNotifier.isDarkTheme)),
                    ),
                    child: Icon(icon, size: 20, color: themeNotifier.accentInk),
                  ),
                  const SizedBox(width: NeuSpace.s12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: NeuType.headingSm(themeNotifier.isDarkTheme),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: NeuSpace.s2),
                        Text(
                          subtitle,
                          style: NeuType.caption(themeNotifier.isDarkTheme),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
