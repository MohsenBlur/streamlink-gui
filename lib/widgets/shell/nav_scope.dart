import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../neumorphic/neu_icon_action.dart';
import '../neumorphic/neu_segmented_control.dart';

/// Which list the sidebar is showing.
enum NavScopeTab {
  favorites,
  followed,
  live;

  static const Map<int, NavScopeTab> byIndex = {
    0: NavScopeTab.favorites,
    1: NavScopeTab.followed,
    2: NavScopeTab.live,
  };

  String get label => switch (this) {
        NavScopeTab.favorites => 'Favorites',
        NavScopeTab.followed => 'Followed',
        NavScopeTab.live => 'Live',
      };

  IconData get icon => switch (this) {
        NavScopeTab.favorites => Icons.star,
        NavScopeTab.followed => Icons.people,
        NavScopeTab.live => Icons.live_tv,
      };

  /// What the tab actually contains, for the tooltip. "Live" in particular is
  /// not self-explanatory: it is a synthesised union of favourites and
  /// followed channels that happen to be live, and nothing said so.
  String get description => switch (this) {
        NavScopeTab.favorites => 'Channels you have starred',
        NavScopeTab.followed => 'Channels you follow on Twitch',
        NavScopeTab.live => 'Everyone live right now, starred or followed',
      };
}

/// The Favorites / Followed / Live selector.
///
/// Replaces a control that cycled through the three tabs on click and revealed
/// its purpose only by swapping to a swap_horiz icon ON HOVER. That is
/// unguessable: the icon showed the CURRENT tab, so it looked like a status
/// indicator rather than a button, and a user had to discover that clicking a
/// star turned it into a list of followed channels.
///
/// It also had no authentication guard, unlike the expanded segmented control,
/// so a signed-out user could cycle onto Followed and land on "make sure your
/// account is connected".
class NavScope extends StatelessWidget {
  const NavScope({
    Key? key,
    required this.current,
    required this.onChanged,
    required this.dense,
    this.isAuthenticated = true,
  }) : super(key: key);

  final NavScopeTab current;
  final ValueChanged<NavScopeTab> onChanged;

  /// Rail and horizontal-bar layouts: icons instead of labels.
  final bool dense;

  /// Followed and Live need a Twitch token. Without one they render disabled
  /// and say why, rather than being silently reachable and then empty.
  final bool isAuthenticated;

  bool _enabled(NavScopeTab tab) =>
      isAuthenticated || tab == NavScopeTab.favorites;

  @override
  Widget build(BuildContext context) {
    if (!dense) {
      if (!isAuthenticated) return const SizedBox.shrink();
      return NeuSegmentedControl<int>(
        selectedValue: current.index,
        children: const {
          0: Text('Favorites'),
          1: Text('Followed'),
          2: Text('Live'),
        },
        onValueChanged: (v) => onChanged(NavScopeTab.byIndex[v]!),
      );
    }

    // Three real buttons: the selected one is visibly selected, and each says
    // what it is. Same mental model as the segmented control above.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final tab in NavScopeTab.values) ...[
          NeuIconAction(
            icon: tab.icon,
            tooltip: '${tab.label} — ${tab.description}',
            onPressed: _enabled(tab) ? () => onChanged(tab) : null,
            disabledReason: 'connect your Twitch account first',
            isSelected: tab == current,
            size: NeuActionSize.sm,
          ),
          if (tab != NavScopeTab.values.last) const SizedBox(height: 2),
        ],
      ],
    );
  }
}

/// The horizontal-bar variant, for a portrait window.
class NavScopeRow extends StatelessWidget {
  const NavScopeRow({
    Key? key,
    required this.current,
    required this.onChanged,
    this.isAuthenticated = true,
  }) : super(key: key);

  final NavScopeTab current;
  final ValueChanged<NavScopeTab> onChanged;
  final bool isAuthenticated;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final tab in NavScopeTab.values)
          NeuIconAction(
            icon: tab.icon,
            tooltip: '${tab.label} — ${tab.description}',
            onPressed: (isAuthenticated || tab == NavScopeTab.favorites)
                ? () => onChanged(tab)
                : null,
            disabledReason: 'connect your Twitch account first',
            isSelected: tab == current,
            size: NeuActionSize.sm,
          ),
      ],
    );
  }
}

/// Shared empty-list copy, so the three layouts cannot drift.
String navEmptyMessage(NavScopeTab tab, String query) {
  if (query.isNotEmpty) return 'No channels match "$query".';
  return switch (tab) {
    NavScopeTab.favorites => 'No favorites yet.\nSearch above to add one.',
    NavScopeTab.followed =>
      'No followed channels found.\nCheck that your account is connected.',
    NavScopeTab.live => 'Nobody you follow is live right now.',
  };
}

/// Ink for a nav label at the given selection state.
Color navLabelColor(bool selected, bool isDark) =>
    selected ? themeNotifier.accentInk : NeuTheme.subtext(isDark);
