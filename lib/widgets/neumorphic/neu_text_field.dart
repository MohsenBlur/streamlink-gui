import 'package:flutter/material.dart';
import 'neu_container.dart';
import '../../theme/neu_theme.dart';
import 'neu_focusable.dart';

class NeuTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final bool autofocus;
  final bool isPassword;
  final double height;
  final VoidCallback? onClear;

  /// Externally owned focus node, so the app can focus this field (e.g. the
  /// Ctrl+F shortcut targeting the sidebar search). When omitted the field
  /// owns and disposes its own node.
  final FocusNode? focusNode;

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
    this.height = 44.0,
    this.onClear,
    this.focusNode,
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
    final primaryColor = theme.primaryColor;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: widget.height,
      child: NeuContainer(
        style: NeuStyle.sunken,
        borderRadius: BorderRadius.circular(22),
        depth: 4.0,
        color: NeuTheme.wellSurface(isDark),
        border: Border.all(
          color: _isFocused
              ? primaryColor.withValues(alpha: 0.9)
              : NeuTheme.border(isDark),
          width: _isFocused ? 1.8 : 1.0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            if (widget.prefixIcon != null) ...[
              Icon(
                widget.prefixIcon,
                size: 18,
                color: _isFocused ? primaryColor : NeuTheme.subtext(isDark),
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
                style: TextStyle(
                  color: NeuTheme.text(isDark),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    color: NeuTheme.subtext(isDark),
                    fontSize: 13,
                  ),
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
