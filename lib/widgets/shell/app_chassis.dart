import 'package:flutter/widgets.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// The window's own body: the surface behind everything.
///
/// A panel in the canvas colour, edge to edge, so the bevel and the fill ramp
/// that every surface in the app carries reach the window itself.
class AppChassis extends StatelessWidget {
  const AppChassis({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    // DecoratedBox, not Container, and that is not a style preference.
    //
    // `Container` folds `decoration.padding` into layout, and
    // `SkeuoDecoration.padding` is `EdgeInsets.all(bevelWidth)` - correct for a
    // control, which really does inset its content by its own edge, and wrong
    // for the window, which has no content to inset. It cost the app body two
    // logical pixels: 378 inside a 380 window, so the portrait rail overflowed
    // its Row by exactly 2.0px at the enforced minimum, independent of any
    // data. Debug drew the striped banner; release clips nothing and simply
    // painted the trailing control past the window edge.
    //
    // The real-surface sweep never mounted this widget, so it measured 380
    // where the app had 378.
    return DecoratedBox(
      decoration:
          NeuTheme.panel(isDark, radius: 0, base: NeuTheme.canvas(isDark)),
      child: child,
    );
  }
}
