import 'package:flutter/material.dart';
import 'neu_container.dart';

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
  }) : super(key: key);

  @override
  State<NeuTextField> createState() => _NeuTextFieldState();
}

class _NeuTextFieldState extends State<NeuTextField> {
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
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
        color: isDark ? const Color(0xFF13151A) : const Color(0xFFD8E0EB),
        border: Border.all(
          color: _isFocused
              ? primaryColor.withOpacity(0.9)
              : (isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.08)),
          width: _isFocused ? 1.8 : 1.0,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            if (widget.prefixIcon != null) ...[
              Icon(
                widget.prefixIcon,
                size: 18,
                color: _isFocused
                    ? primaryColor
                    : (isDark ? Colors.white38 : Colors.black38),
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
                  color: isDark ? const Color(0xFFF0F4F8) : const Color(0xFF2D3748),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(
                    color: isDark ? Colors.white38 : Colors.black38,
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
              GestureDetector(
                onTap: () {
                  widget.controller?.clear();
                  widget.onClear?.call();
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Icon(
                    Icons.cancel,
                    size: 16,
                    color: isDark ? Colors.white38 : Colors.black38,
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
