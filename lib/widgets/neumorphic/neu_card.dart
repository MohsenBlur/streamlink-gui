import 'package:flutter/material.dart';
import 'neu_container.dart';
import 'neu_focusable.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

class NeuCard extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;
  final bool isSelected;
  final bool isLive;
  final Color? baseColor;
  final double depth;

  const NeuCard({
    Key? key,
    required this.child,
    this.width,
    this.height,
    this.padding = const EdgeInsets.all(NeuSpace.s16),
    this.margin = EdgeInsets.zero,
    this.borderRadius,
    this.onTap,
    this.isSelected = false,
    this.isLive = false,
    this.baseColor,
    this.depth = 6.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;

    Border? cardBorder;
    if (isSelected) {
      cardBorder = Border.all(color: primary, width: 2.0);
    } else if (isLive) {
      cardBorder = Border.all(
        color: NeuTheme.live.withValues(alpha: 0.6),
        width: 1.5,
      );
    }

    Widget cardCore = NeuContainer(
      width: width,
      height: height,
      padding: padding,
      margin: margin,
      borderRadius: borderRadius ?? BorderRadius.circular(NeuRadius.r20),
      style: NeuStyle.raised,
      depth: depth,
      color: baseColor ?? themeNotifier.surfaceColor,
      border: cardBorder,
      child: child,
    );

    if (onTap != null) {
      return NeuFocusable(
        onActivate: onTap,
        focusRadius: (borderRadius ?? BorderRadius.circular(NeuRadius.r20)).topLeft.x,
        child: GestureDetector(
          onTap: onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: cardCore,
          ),
        ),
      );
    }

    return cardCore;
  }
}
