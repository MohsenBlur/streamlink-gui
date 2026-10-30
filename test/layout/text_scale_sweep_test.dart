import 'package:flutter/widgets.dart';

import 'overflow_sweep_test.dart' show sweepSizes;
import 'real_surface_sweep_test.dart' show sweepRealSurfaces;

/// The real-surface sweep with Windows' Text size turned up.
///
/// Settings > Accessibility > Text size reaches the app as MediaQuery's text
/// scale, and nothing swept it: every sweep ran at 100%, while several
/// layouts pick their form from pixel budgets measured at 100%. At 125% the
/// selection bar chose its full layout in a 1280x800 window and its count
/// overflowed into the actions; at 150% the channel toolbar, the expired-
/// token banner and the title bar overran the 380px minimum.
///
/// 125% and 150%, the steps most people pick, at every sweep size and the
/// 1280x800 window those first reports came from. In a file of its own so it
/// runs beside the 100% sweep rather than after it.
///
/// Not 175% and up, yet: there a Continue-watching card's text outgrows its
/// fixed 135px card, and a dialog outgrows a 380x500 window. The title bar
/// is held at 125% by design, and the sidebar is checked at 175% on its own
/// (text_scale_chrome_test).
void main() {
  const sizes = [...sweepSizes, Size(1280, 800)];
  sweepRealSurfaces(textScale: 1.25, sizes: sizes);
  sweepRealSurfaces(textScale: 1.5, sizes: sizes);
}
