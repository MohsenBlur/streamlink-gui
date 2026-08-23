import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'neu_container.dart';
import 'neu_button.dart';
import '../../theme/neu_theme.dart';
import 'neu_badge.dart';

class NeuTitleBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final bool isDarkTheme;
  final ValueChanged<bool> onThemeToggle;
  final Widget? leading;
  final List<Widget>? actions;

  /// Number of favorite channels currently live. The badge renders only when
  /// this is greater than zero — it previously showed a permanent, decorative
  /// "LIVE" chip unrelated to any actual stream state.
  final int liveCount;

  /// Extra horizontal room held back at both ends, for the chassis screws that
  /// sit in the window's top corners.
  ///
  /// Zero unless the active material draws ornament, so the classic look does
  /// not pay for a screw it never shows. The value belongs to the furniture
  /// rather than to this widget: see `ChassisFurniture.edgeClearance`.
  final double edgeInset;

  const NeuTitleBar({
    Key? key,
    this.title = 'TWITCH STREAMLINK GUI',
    required this.isDarkTheme,
    required this.onThemeToggle,
    this.leading,
    this.actions,
    this.liveCount = 0,
    this.edgeInset = 0,
  }) : super(key: key);

  @override
  Size get preferredSize => const Size.fromHeight(40.0);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40.0,
      // The device's top edge. It takes the panel treatment rather than a flat
      // canvas fill, and keeps its hairline: the seam where the faceplate meets
      // the chassis is a real edge, not a decoration.
      decoration: NeuTheme.panel(
        isDarkTheme,
        radius: 0,
        base: NeuTheme.canvas(isDarkTheme),
        border: Border(
          bottom: BorderSide(
            color: NeuTheme.shadow(isDarkTheme).withValues(alpha: 0.3),
            width: 1.0,
          ),
        ),
      ),
      child: Padding(
        // Clearance for the chassis screws, which sit in the two top corners
        // and would otherwise land on the live badge at one end and the close
        // button at the other. Zero on any material that draws no ornament, so
        // this is not a cost the classic look pays.
        padding: EdgeInsets.symmetric(horizontal: edgeInset),
        child: Row(
        children: [
          // Drag handle region for title bar
          Expanded(
            child: GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              onDoubleTap: () async {
                final isMax = await windowManager.isMaximized();
                if (isMax) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s16),
                child: Row(
                  children: [
                    ?leading,
                    const SizedBox(width: NeuSpace.s8),
                    if (liveCount > 0) ...[
                      Tooltip(
                        message:
                            '$liveCount favorite channel${liveCount == 1 ? '' : 's'} live',
                        child: LiveBadge(
                          variant: LiveVariant.count,
                          count: liveCount,
                        ),
                      ),
                      const SizedBox(width: NeuSpace.s8),
                    ],
                    // Flexible + ellipsis: at the 380px minimum window width
                    // the title, the live badge and an activity pill together
                    // exceed the drag region, and an unwrapped Text would
                    // overflow rather than yield.
                    Flexible(
                      child: Text(
                        title.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: NeuType.label(isDarkTheme, color: NeuTheme.text(isDarkTheme)).copyWith(letterSpacing: 1.1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Custom Actions
          ...?actions,

          // Theme Toggle Button
          NeuIconButton(
            icon: isDarkTheme ? Icons.wb_sunny_rounded : Icons.nightlight_round,
            iconColor:
                isDarkTheme ? const Color(0xFFFFB74D) : const Color(0xFF5C6BC0),
            size: 28,
            iconSize: 14,
            tooltip: isDarkTheme
                ? 'Switch to Light Neumorphic'
                : 'Switch to Dark Neumorphic',
            onPressed: () => onThemeToggle(!isDarkTheme),
          ),
          const SizedBox(width: NeuSpace.s12),

          // Frameless Window Controls
          const _WindowControls(),
        ],
        ),
      ),
    );
  }
}

/// Minimize / maximize / close, with the maximize button tracking the actual
/// window state (its icon and tooltip previously never changed).
class _WindowControls extends StatefulWidget {
  const _WindowControls();

  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => _isMaximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WindowControlButton(
          icon: Icons.remove_rounded,
          tooltip: 'Minimize',
          onPressed: () => windowManager.minimize(),
        ),
        const SizedBox(width: NeuSpace.s6),
        _WindowControlButton(
          icon: _isMaximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          tooltip: _isMaximized ? 'Restore' : 'Maximize',
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              windowManager.unmaximize();
            } else {
              windowManager.maximize();
            }
          },
        ),
        const SizedBox(width: NeuSpace.s6),
        _WindowControlButton(
          icon: Icons.close_rounded,
          tooltip: 'Close',
          isClose: true,
          onPressed: () => windowManager.close(),
        ),
        const SizedBox(width: NeuSpace.s8),
      ],
    );
  }
}

class _WindowControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool isClose;

  const _WindowControlButton({
    Key? key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.isClose = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // The socket needs breathing room around the button or its recessed ring
    // is entirely covered by the button surface.
    return NeuContainer(
      width: 26,
      height: 26,
      isCircle: true,
      style: NeuStyle.well,
      padding: const EdgeInsets.all(NeuSpace.s4),
      child: NeuIconButton(
        icon: icon,
        size: 20,
        iconSize: 11,
        iconColor: isClose ? NeuTheme.danger : NeuTheme.text(isDark),
        activeColor: isClose ? NeuTheme.danger : null,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}
