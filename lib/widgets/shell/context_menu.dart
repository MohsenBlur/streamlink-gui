import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// One entry in a right-click menu.
class NeuMenuItem {
  const NeuMenuItem({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.isDestructive = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool isDestructive;
  final bool enabled;
}

/// Wraps [child] with a right-click menu.
///
/// The app had NO context menus at all - a repo-wide search for
/// onSecondaryTap, onLongPress, PopupMenuButton and MenuAnchor returned
/// nothing. Every action was a click target or a hover-reveal, which is why so
/// many of them ended up invisible until the pointer happened to pass over
/// them.
///
/// A right-click menu is the cheapest way to make actions discoverable without
/// spending layout on them: it is where a desktop user already looks.
class NeuContextMenu extends StatelessWidget {
  const NeuContextMenu({
    Key? key,
    required this.items,
    required this.child,
  }) : super(key: key);

  final List<NeuMenuItem> items;
  final Widget child;

  Future<void> _show(BuildContext context, Offset globalPosition) async {
    if (items.isEmpty) return;
    final isDark = themeNotifier.isDarkTheme;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final selected = await showMenu<int>(
      context: context,
      color: NeuTheme.surface(isDark),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NeuRadius.r8),
        side: BorderSide(color: NeuTheme.border(isDark), width: 1),
      ),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            enabled: items[i].enabled,
            height: 36,
            child: Row(
              children: [
                Icon(
                  items[i].icon,
                  size: 15,
                  color: !items[i].enabled
                      ? NeuTheme.disabledText(isDark)
                      : items[i].isDestructive
                          ? NeuTheme.dangerText(isDark)
                          : NeuTheme.text(isDark),
                ),
                const SizedBox(width: NeuSpace.s8),
                Text(
                  items[i].label,
                  style: NeuType.bodySm(isDark).copyWith(
                    color: !items[i].enabled
                        ? NeuTheme.disabledText(isDark)
                        : items[i].isDestructive
                            ? NeuTheme.dangerText(isDark)
                            : NeuTheme.text(isDark),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (selected != null) items[selected].onSelected();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (details) => _show(context, details.globalPosition),
      // Long-press as well, so a touch or pen user can reach the same actions.
      onLongPressStart: (details) => _show(context, details.globalPosition),
      child: child,
    );
  }
}
