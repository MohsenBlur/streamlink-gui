import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'neu_container.dart';
import 'neu_button.dart';
import '../../theme/neu_theme.dart';

class NeuTitleBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final bool isDarkTheme;
  final ValueChanged<bool> onThemeToggle;
  final Widget? leading;
  final List<Widget>? actions;

  const NeuTitleBar({
    Key? key,
    this.title = 'TWITCH STREAMLINK GUI',
    required this.isDarkTheme,
    required this.onThemeToggle,
    this.leading,
    this.actions,
  }) : super(key: key);

  @override
  Size get preferredSize => const Size.fromHeight(40.0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 40.0,
      decoration: BoxDecoration(
        color: NeuTheme.background(isDarkTheme),
        border: Border(
          bottom: BorderSide(
            color: NeuTheme.shadow(isDarkTheme).withOpacity(0.3),
            width: 1.0,
          ),
        ),
      ),
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
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    if (leading != null) leading!,
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.primaryColor.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: theme.primaryColor.withOpacity(0.4),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        'LIVE',
                        style: TextStyle(
                          color: theme.primaryColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        color: NeuTheme.text(isDarkTheme),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Custom Actions
          if (actions != null) ...actions!,

          // Theme Toggle Button
          NeuIconButton(
            icon: isDarkTheme ? Icons.wb_sunny_rounded : Icons.nightlight_round,
            iconColor: isDarkTheme ? const Color(0xFFFFB74D) : const Color(0xFF5C6BC0),
            size: 28,
            iconSize: 14,
            tooltip: isDarkTheme ? 'Switch to Light Neumorphic' : 'Switch to Dark Neumorphic',
            onPressed: () => onThemeToggle(!isDarkTheme),
          ),
          const SizedBox(width: 12),

          // Frameless Window Controls
          Row(
            children: [
              _WindowControlButton(
                icon: Icons.remove_rounded,
                tooltip: 'Minimize',
                onPressed: () => windowManager.minimize(),
              ),
              const SizedBox(width: 6),
              _WindowControlButton(
                icon: Icons.crop_square_rounded,
                tooltip: 'Maximize',
                onPressed: () async {
                  if (await windowManager.isMaximized()) {
                    windowManager.unmaximize();
                  } else {
                    windowManager.maximize();
                  }
                },
              ),
              const SizedBox(width: 6),
              _WindowControlButton(
                icon: Icons.close_rounded,
                tooltip: 'Close',
                isClose: true,
                onPressed: () => windowManager.close(),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ],
      ),
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

    return NeuContainer(
      width: 26,
      height: 26,
      isCircle: true,
      style: NeuStyle.well,
      child: NeuIconButton(
        icon: icon,
        size: 22,
        iconSize: 12,
        iconColor: isClose
            ? const Color(0xFFFF4565)
            : NeuTheme.text(isDark),
        activeColor: isClose ? const Color(0xFFFF4565) : null,
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}
