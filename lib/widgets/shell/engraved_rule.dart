import 'package:flutter/widgets.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// A machined groove, where a flat UI would draw a grey line.
///
/// The reference hardware never separates regions with a line - it engraves.
/// With the light from above, a groove cut into the plate reads as a dark
/// hairline (the far wall, in shadow) with a bright hairline immediately
/// below it (the near wall, catching the light). The chassis's own window
/// groove is painted with exactly this pair; this widget brings the same cut
/// to every in-panel separator, replacing seven different single-line rules
/// in three weights.
///
/// The vertical variant puts the lit wall on the right, consistent with the
/// same overhead light striking a vertical cut.
class EngravedRule extends StatelessWidget {
  const EngravedRule({
    super.key,
    this.vertical = false,
    this.indent = 0,
  });

  final bool vertical;

  /// Distance held back from both ends. A groove milled to the very edge of
  /// a plate reads as a saw cut, not a groove.
  final double indent;

  @override
  Widget build(BuildContext context) {
    final p = NeuTheme.palette(themeNotifier.isDarkTheme);
    final shade = ColoredBox(color: p.bevelShade);
    final light = ColoredBox(color: p.bevelLight);

    if (vertical) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: indent),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: NeuSpace.s1, height: double.infinity, child: shade),
            SizedBox(width: NeuSpace.s1, height: double.infinity, child: light),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: indent),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: NeuSpace.s1, width: double.infinity, child: shade),
          SizedBox(height: NeuSpace.s1, width: double.infinity, child: light),
        ],
      ),
    );
  }
}
