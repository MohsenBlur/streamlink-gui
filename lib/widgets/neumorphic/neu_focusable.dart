import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';

/// Keyboard and screen-reader access for the custom neumorphic controls.
///
/// The neumorphic widgets are GestureDetector-based, which makes them
/// invisible to Tab traversal and mute to assistive tech. This wrapper adds
/// focus, Enter/Space activation and a semantics role, and is
/// layout-transparent: the focus ring paints as a foregroundDecoration, so
/// wrapping a control never moves pixels.
class NeuFocusable extends StatefulWidget {
  const NeuFocusable({
    Key? key,
    required this.child,
    this.onActivate,
    this.semanticLabel,
    this.toggled,
    this.focusRadius = 12,
    this.enabled = true,
  }) : super(key: key);

  final Widget child;
  final VoidCallback? onActivate;
  final String? semanticLabel;

  /// Non-null gives switch/checkbox semantics instead of a button role.
  final bool? toggled;
  final double focusRadius;
  final bool enabled;

  @override
  State<NeuFocusable> createState() => _NeuFocusableState();
}

class _NeuFocusableState extends State<NeuFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.enabled && widget.onActivate != null;

    return FocusableActionDetector(
      enabled: enabled,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: widget.toggled == null,
        toggled: widget.toggled,
        label: widget.semanticLabel,
        enabled: enabled,
        child: Container(
          foregroundDecoration: _focused
              ? NeuTheme.focusRing(
                  theme.brightness == Brightness.dark,
                  theme.primaryColor,
                  radius: widget.focusRadius,
                )
              : null,
          child: widget.child,
        ),
      ),
    );
  }
}
