import 'package:flutter/material.dart';

class HoverOverlayMenu extends StatefulWidget {
  final Widget trigger;
  final Widget menu;
  
  const HoverOverlayMenu({
    Key? key,
    required this.trigger,
    required this.menu,
  }) : super(key: key);

  @override
  State<HoverOverlayMenu> createState() => _HoverOverlayMenuState();
}

class _HoverOverlayMenuState extends State<HoverOverlayMenu> {
  OverlayEntry? _entry;
  Offset _mousePos = Offset.zero;

  void _showMenu() {
    if (_entry != null) return;
    
    _entry = OverlayEntry(
      builder: (context) {
        final size = MediaQuery.of(context).size;
        double left = _mousePos.dx + 16;
        double top = _mousePos.dy + 16;
        
        // Menu width is 260, height is approx 220
        if (left + 260 > size.width) {
          left = _mousePos.dx - 260 - 16;
        }
        if (top + 220 > size.height) {
          top = _mousePos.dy - 220 - 16;
        }
        if (left < 0) left = 0;
        if (top < 0) top = 0;
        
        return Positioned(
          left: left,
          top: top,
          child: IgnorePointer(
            ignoring: true,
            child: Theme(
              data: Theme.of(context),
              child: Material(
                color: Colors.transparent,
                child: widget.menu,
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_entry!);
  }

  void _updatePosition(Offset pos) {
    _mousePos = pos;
    _entry?.markNeedsBuild();
  }

  void _hideMenu() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (event) {
        _mousePos = event.position;
        _showMenu();
      },
      onHover: (event) {
        _updatePosition(event.position);
      },
      onExit: (_) {
        _hideMenu();
      },
      child: widget.trigger,
    );
  }
}

class HoverStarIcon extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onTap;
  
  const HoverStarIcon({
    Key? key,
    required this.isFavorite,
    required this.onTap,
  }) : super(key: key);

  @override
  State<HoverStarIcon> createState() => _HoverStarIconState();
}

class _HoverStarIconState extends State<HoverStarIcon> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final useGold = widget.isFavorite || _isHovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: IconButton(
        icon: Icon(
          useGold ? Icons.star : Icons.star_border,
          color: useGold ? Colors.amber : Colors.white30,
          size: 18,
        ),
        onPressed: widget.onTap,
        tooltip: widget.isFavorite ? 'Remove from Favorites' : 'Add to Favorites',
        splashRadius: 18,
      ),
    );
  }
}
