import 'package:flutter/material.dart';
import 'neu_container.dart';
import '../../main.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = widget.activeColor ?? theme.primaryColor;

    final effectiveStyle = (widget.isSelected || _isPressed)
        ? NeuStyle.sunken
        : NeuStyle.raised;

    Widget buttonCore = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onPressed != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          transform: Matrix4.identity()
            ..scale(_isPressed ? 0.97 : (_isHovered ? 1.02 : 1.0)),
          child: NeuContainer(
            width: widget.width,
            height: widget.height,
            padding: widget.padding,
            borderRadius: widget.borderRadius ?? BorderRadius.circular(20),
            isCircle: widget.isCircle,
            style: effectiveStyle,
            color: widget.isSelected
                ? accentColor.withOpacity(0.15)
                : widget.baseColor,
            depth: _isHovered ? widget.depth + 2 : widget.depth,
            border: widget.isSelected
                ? Border.all(color: accentColor.withOpacity(0.8), width: 1.5)
                : null,
            child: Center(
              widthFactor: 1.0,
              heightFactor: 1.0,
              child: DefaultTextStyle(
                style: TextStyle(
                  color: widget.isSelected
                      ? accentColor
                      : themeNotifier.textColor,
                  fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w600,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
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
  final bool inWell;

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
    this.inWell = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveIconColor = isSelected
        ? (activeColor ?? theme.primaryColor)
        : (iconColor ?? themeNotifier.textColor);

    Widget btn = NeuButton(
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

    if (inWell) {
      return NeuContainer(
        width: size + 8,
        height: size + 8,
        padding: const EdgeInsets.all(4),
        isCircle: true,
        style: NeuStyle.well,
        child: btn,
      );
    }

    return btn;
  }
}
