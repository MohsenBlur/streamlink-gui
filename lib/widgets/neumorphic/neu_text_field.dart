import 'package:flutter/material.dart';
import 'neu_container.dart';
import '../../theme/neu_theme.dart';
import '../shell/motion.dart';
import '../../theme/theme_notifier.dart';
import 'neu_focusable.dart';

/// Field size. Height, text, hint and icon scale together.
enum NeuFieldSize {
  /// 32px — inline toolbars, where a 44px field would dominate the row.
  sm,

  /// 40px — dialogs and popovers.
  md,

  /// 44px — the sidebar's primary search.
  lg,
}

extension NeuFieldSizeMetrics on NeuFieldSize {
  double get height => switch (this) {
        NeuFieldSize.sm => 32,
        NeuFieldSize.md => 40,
        NeuFieldSize.lg => 44,
      };

  /// Named steps rather than literals. lg was 14, which is not on the scale;
  /// it is 13 now, the same as md, and the two still differ by their height.
  TextStyle text(bool isDark) => switch (this) {
        NeuFieldSize.sm => NeuType.bodySm(isDark),
        NeuFieldSize.md => NeuType.body(isDark),
        NeuFieldSize.lg => NeuType.body(isDark),
      };

  TextStyle hint(bool isDark) => switch (this) {
        NeuFieldSize.sm => NeuType.bodySm(isDark, color: NeuTheme.subtext(isDark)),
        NeuFieldSize.md => NeuType.bodySm(isDark, color: NeuTheme.subtext(isDark)),
        NeuFieldSize.lg => NeuType.body(isDark, color: NeuTheme.subtext(isDark)),
      };

  double get iconSize => switch (this) {
        NeuFieldSize.sm => 14,
        NeuFieldSize.md => 16,
        NeuFieldSize.lg => 18,
      };
}

class NeuTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final bool autofocus;
  final bool isPassword;
  /// Overrides [size]'s height when set. Prefer [size].
  final double? height;
  final VoidCallback? onClear;

  /// Externally owned focus node, so the app can focus this field (e.g. the
  /// Ctrl+F shortcut targeting the sidebar search). When omitted the field
  /// owns and disposes its own node.
  final FocusNode? focusNode;

  /// Overall size. Height, text size, hint size and icon size move together;
  /// they used to be fixed at 44/14/13/18 while callers overrode only the
  /// height, so a short field rendered 14px text in a 28px box.
  final NeuFieldSize size;

  const NeuTextField({
    Key? key,
    this.controller,
    this.hintText,
    this.onChanged,
    this.onSubmitted,
    this.prefixIcon,
    this.suffixIcon,
    this.autofocus = false,
    this.isPassword = false,
    this.height,
    this.onClear,
    this.focusNode,
    this.size = NeuFieldSize.lg,
  }) : super(key: key);

  @override
  State<NeuTextField> createState() => _NeuTextFieldState();
}

class _NeuTextFieldState extends State<NeuTextField> {
  FocusNode? _ownedFocusNode;
  bool _isFocused = false;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
    // The clear button's visibility depends on the text; listen directly so it
    // updates even when the parent never rebuilds (it previously worked only
    // because some parents happened to call setState from onChanged).
    widget.controller?.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(NeuTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onTextChanged);
      widget.controller?.addListener(_onTextChanged);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocusNode)?.removeListener(_onFocusChanged);
      _focusNode.addListener(_onFocusChanged);
    }
  }

  void _onFocusChanged() {
    if (mounted) setState(() => _isFocused = _focusNode.hasFocus);
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedContainer(
      duration: NeuMotion.duration(context, NeuMotion.fast),
      curve: NeuMotion.curve,
      height: widget.height ?? widget.size.height,
      child: NeuContainer(
        style: NeuStyle.sunken,
        // Pill: at the previous fixed height of 44 this rendered identically
        // to the hardcoded 22, and it stays a pill when the height changes.
        borderRadius: BorderRadius.circular(widget.size.height / 2),
        depth: 4.0,
        color: NeuTheme.wellSurface(isDark),
        border: Border.all(
          color: _isFocused
              ? themeNotifier.accentInk
              : NeuTheme.border(isDark),
          width: _isFocused ? 1.8 : 1.0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            if (widget.prefixIcon != null) ...[
              Icon(
                widget.prefixIcon,
                size: widget.size.iconSize,
                // accentInk, not the raw accent: at 90% alpha this reads as a
                // foreground stroke, and a light-mode Cyan accent measured
                // 1.04:1 against the well behind it.
                color: _isFocused ? themeNotifier.accentInk : NeuTheme.subtext(isDark),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                autofocus: widget.autofocus,
                obscureText: widget.isPassword,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                style: widget.size.text(isDark),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: widget.size.hint(isDark),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
              ),
            ),
            if (widget.controller != null &&
                widget.controller!.text.isNotEmpty &&
                widget.onClear != null)
              NeuFocusable(
                onActivate: () {
                  widget.controller?.clear();
                  widget.onClear?.call();
                },
                semanticLabel: 'Clear text',
                focusRadius: 10,
                child: GestureDetector(
                  onTap: () {
                    widget.controller?.clear();
                    widget.onClear?.call();
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Icon(
                      Icons.cancel,
                      size: 16,
                      color: NeuTheme.subtext(isDark),
                    ),
                  ),
                ),
              ),
            if (widget.suffixIcon != null) ...[
              const SizedBox(width: 6),
              widget.suffixIcon!,
            ],
          ],
        ),
      ),
    );
  }
}
