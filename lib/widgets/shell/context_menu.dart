import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
                // Flexible: a popup menu caps its width (256px of content),
                // and a bare Text in this Row overflowed it rather than
                // ellipsizing once a label ran long.
                Flexible(
                  child: Text(
                    items[i].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: NeuType.bodySm(isDark).copyWith(
                      color: !items[i].enabled
                          ? NeuTheme.disabledText(isDark)
                          : items[i].isDestructive
                              ? NeuTheme.dangerText(isDark)
                              : NeuTheme.text(isDark),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (selected != null) items[selected].onSelected();
  }

  /// Who a long press opens the menu for: touch and pen, which have no
  /// right button. A mouse has one, and while the long press accepted it
  /// too, a slow click - held past the 500ms timeout - on a VOD card or a
  /// sidebar row opened the menu instead of playing or selecting.
  static const Set<PointerDeviceKind> longPressDevices = {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };

  /// The Menu key, or Shift+F10 - the Windows keyboard routes to a context
  /// menu.
  static bool isMenuKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.contextMenu) return true;
    return event.logicalKey == LogicalKeyboardKey.f10 &&
        HardwareKeyboard.instance.isShiftPressed;
  }

  @override
  Widget build(BuildContext context) {
    // Keyboard as well as pointer. A right-click menu that only a pointer can
    // open is one more set of actions a keyboard user never reaches, which
    // is the gap this widget was added to close. This Focus takes no focus
    // and no Tab stop of its own; it hears the menu key from whichever
    // control inside it has focus, and opens the menu over this widget.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (!isMenuKey(event) || items.isEmpty) return KeyEventResult.ignored;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return KeyEventResult.ignored;
        _show(context, box.localToGlobal(box.size.center(Offset.zero)));
        return KeyEventResult.handled;
      },
      // With no items the recognizers stand down rather than open nothing:
      // a long-press recognizer in the arena wins any press held past the
      // long-press timeout, so a VOD card in multi-select (a checkbox whose
      // menu is empty) lost every slow click or touch-and-hold to a menu that
      // never opened. The detector itself stays, so toggling between empty
      // and non-empty never changes the shape of the tree under it.
      //
      // A RawGestureDetector, because GestureDetector's supportedDevices
      // applies to every recognizer it builds, the right-click included.
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        gestures: items.isEmpty
            ? const <Type, GestureRecognizerFactory>{}
            : <Type, GestureRecognizerFactory>{
                TapGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(debugOwner: this),
                  (recognizer) => recognizer.onSecondaryTapUp =
                      (details) => _show(context, details.globalPosition),
                ),
                // Long-press as well, so a touch or pen user can reach the
                // same actions - and only they (see longPressDevices).
                LongPressGestureRecognizer: GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer>(
                  () => LongPressGestureRecognizer(
                      debugOwner: this, supportedDevices: longPressDevices),
                  (recognizer) => recognizer.onLongPressStart =
                      (details) => _show(context, details.globalPosition),
                ),
              },
        child: child,
      ),
    );
  }
}
