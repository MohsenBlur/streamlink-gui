import 'package:flutter/widgets.dart';

/// Fades a scroller's own edges to transparent, rather than painting a strip
/// of ground colour over them.
///
/// The distinction is the whole point of this widget. The shipped version was
/// a `Positioned` strip carrying a gradient from `backgroundColor` to the same
/// colour at alpha 0 — which is a perfect fade only while the thing behind it
/// is that exact flat colour. It never was quite: the strip sat over a panel,
/// not the canvas. It was close enough not to notice.
///
/// A material makes it impossible to not notice. A panel carries a grain and a
/// fill ramp, so a rectangle of flat ground colour over it is a visible band —
/// brighter or duller than its surroundings, with two hard vertical edges — and
/// no colour swap fixes it, because there is no single colour that matches a
/// gradient with a texture on it.
///
/// So the fade moves from the *cover* to the *content*: `BlendMode.dstIn`
/// multiplies the child's alpha by the shader's, so the chips themselves fade
/// out and whatever is behind them shows through untouched, grain and all.
///
/// Costs a `saveLayer`. Worth it here — this wraps a 38px strip — and not a
/// pattern to spread to large scrolling surfaces.
class EdgeFade extends StatelessWidget {
  const EdgeFade({
    super.key,
    required this.child,
    this.left = false,
    this.right = false,
    this.extent = 32,
  });

  final Widget child;

  /// Which edges fade. Both default to off so the caller states its intent,
  /// and both are usually driven by scroll-position flags — a fade at an edge
  /// with nothing past it advertises content that is not there.
  final bool left, right;

  /// Fade width in logical pixels.
  final double extent;

  @override
  Widget build(BuildContext context) {
    if (!left && !right) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) {
        // Guard the degenerate case: a zero-width bounds would divide by zero,
        // and a strip narrower than two fades would produce descending stops,
        // which `LinearGradient` asserts on.
        final width = bounds.width;
        if (width <= 0) {
          return const LinearGradient(
            colors: [Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
          ).createShader(bounds);
        }
        final f = (extent / width).clamp(0.0, left && right ? 0.5 : 1.0);
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            if (left) const Color(0x00FFFFFF),
            const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            if (right) const Color(0x00FFFFFF),
          ],
          stops: <double>[
            if (left) 0.0,
            left ? f : 0.0,
            right ? 1.0 - f : 1.0,
            if (right) 1.0,
          ],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}
