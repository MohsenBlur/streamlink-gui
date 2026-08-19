import 'package:flutter/material.dart';
import 'neu_container.dart';
import 'neu_focusable.dart';
import '../../theme/theme_notifier.dart';
import '../../theme/neu_theme.dart';

class NeuButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;
  final bool isCircle;
  final bool isSelected;
  final Color? activeColor;
  final Color? baseColor;
  final String? tooltip;
  final double depth;

  const NeuButton({
    Key? key,
    required this.child,
    this.onPressed,
    this.width,
    this.height,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.borderRadius,
    this.isCircle = false,
    this.isSelected = false,
    this.activeColor,
    this.baseColor,
    this.tooltip,
    this.depth = 5.0,
  }) : super(key: key);

  @override
  State<NeuButton> createState() => _NeuButtonState();
}

class _NeuButtonState extends State<NeuButton> {
  bool _isPressed = false;
  bool _isHovered = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = widget.activeColor ?? theme.primaryColor;

    final effectiveStyle = (widget.isSelected || _isPressed)
        ? NeuStyle.sunken
        : NeuStyle.raised;

    // A disabled button gives no interaction feedback: it previously showed
    // the pressed/sunken state on tap-down even with onPressed == null.
    final double scale = !_enabled
        ? 1.0
        : _isPressed
            ? 0.96
            : (_isHovered ? 1.025 : 1.0);

    Widget content = DefaultTextStyle(
      style: TextStyle(
        color: !_enabled
            ? NeuTheme.disabledText(themeNotifier.isDarkTheme)
            : widget.isSelected
                ? accentColor
                : themeNotifier.textColor,
        fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w600,
      ),
      child: widget.child,
    );
    if (!_enabled) {
      content = Opacity(opacity: 0.45, child: content);
    }

    Widget buttonCore = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: _enabled ? (_) => setState(() => _isPressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _isPressed = false) : null,
        onTapCancel: _enabled ? () => setState(() => _isPressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          // Without this the transform origin is the top-left corner, so every
          // button in the app grew down-right on hover and collapsed toward
          // its corner on press instead of scaling in place.
          transformAlignment: Alignment.center,
          transform: Matrix4.identity()..scale(scale),
          child: NeuContainer(
            width: widget.width,
            height: widget.height,
            padding: widget.padding,
            borderRadius: widget.borderRadius ?? BorderRadius.circular(20),
            isCircle: widget.isCircle,
            style: effectiveStyle,
            color: widget.isSelected
                ? accentColor.withValues(alpha: 0.15)
                : widget.baseColor,
            depth: !_enabled
                ? widget.depth
                : _isPressed
                    ? (widget.depth * 0.35).clamp(1.0, 3.0)
                    : (_isHovered ? widget.depth + 2.0 : widget.depth),
            border: widget.isSelected
                ? Border.all(color: accentColor.withValues(alpha: 0.8), width: 1.5)
                : null,
            child: Center(
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: content,
            ),
          ),
        ),
      ),
    );

    buttonCore = NeuFocusable(
      onActivate: widget.onPressed,
      semanticLabel: widget.tooltip,
      focusRadius:
          widget.isCircle ? 100 : (widget.borderRadius?.topLeft.x ?? 20),
      child: buttonCore,
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      return Tooltip(
        message: widget.tooltip!,
        child: buttonCore,
      );
    }

    return buttonCore;
  }
}

class NeuIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? iconColor;
  final Color? activeColor;
  final bool isSelected;
  final String? tooltip;

  const NeuIconButton({
    Key? key,
    required this.icon,
    this.onPressed,
    this.size = 40.0,
    this.iconSize = 20.0,
    this.iconColor,
    this.activeColor,
    this.isSelected = false,
    this.tooltip,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveIconColor = isSelected
        ? (activeColor ?? theme.primaryColor)
        : (iconColor ?? themeNotifier.textColor);

    return NeuButton(
      width: size,
      height: size,
      padding: EdgeInsets.zero,
      isCircle: true,
      isSelected: isSelected,
      activeColor: activeColor,
      onPressed: onPressed,
      tooltip: tooltip,
      child: Icon(
        icon,
        size: iconSize,
        color: effectiveIconColor,
      ),
    );
  }
}
