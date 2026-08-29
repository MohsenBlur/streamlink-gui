import 'package:flutter/widgets.dart';

import '../../theme/material/app_material.dart';
import '../../theme/material/chassis_furniture.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import 'app_layout.dart';

/// The window's own body: the material behind everything, and the ornament
/// over everything.
///
/// One `Container` with both a `decoration` and a `foregroundDecoration`. Not
/// a `Stack` and not a `CustomPaint`: `foregroundDecoration` paints after the
/// child and `RenderDecoratedBox.hitTestSelf` is false, so the ornament sits
/// over the whole app with no `IgnorePointer` and no extra hit-test layer.
///
/// The screws have to be foreground. As a background they would be covered by
/// the title bar and the sidebar, and the only way to expose them from behind
/// is to inset the content — which moves the layout this effort is committed
/// to leaving where it is.
///
/// ## Why the ornament is suppressed on a rail
///
/// Not because it looks bad small — because the window is out of room. The
/// groove and the screws claim 26 logical pixels of every edge, and at the
/// enforced 380x500 minimum the layout has already dropped the sidebar for a
/// rail and halved its own insets to fit what is there. Ornament that pushes
/// content is not ornament, it is a layout change with a decorative excuse.
///
/// The predicate is `isRail`, not `size < LayoutSize.medium`. `compactMax` is
/// 700, and a 900x1200 portrait window is medium — and cramped, which is what
/// `isRail` exists to say. Using the band would put screws in the one window
/// shape that most needs the space.
///
/// **The material itself does not thin.** Only ornament goes: the grain, the
/// fill, the bevels and the light direction are identical at 380 and at 2560.
/// Half a logical pixel at DPR 1.0 is a smear that reads as a fault, so
/// nothing here scales a hairline down to fit.
class AppChassis extends StatelessWidget {
  const AppChassis({super.key, required this.child});

  final Widget child;

  /// Whether this material's ornament is being drawn in this window.
  ///
  /// Public because the title bar has to answer the same question to know how
  /// far to hold its content off the edge, and two copies of the predicate is
  /// how a screw ends up on a close button in one layout and not another.
  static bool showsFurniture(BuildContext context) {
    final layout = AppLayout.maybeOf(context);
    final f = MaterialSpec.of(NeuTheme.activeMaterial).furniture;
    return f.hasChassisOrnament && !layout.isRail;
  }

  /// How far the title bar must hold its content off the window's sides.
  ///
  /// Per material now, because the ornament is: the walnut case needs 14px,
  /// the rail and the vent live on the bottom edge and need none, and legacy
  /// screw/seam ornament keeps its historic clearance. Zero whenever the
  /// ornament is suppressed, so a rail layout loses the inset with the
  /// frame - the pair can never disagree.
  static double edgeClearance(BuildContext context) {
    if (!showsFurniture(context)) return 0;
    final f = MaterialSpec.of(NeuTheme.activeMaterial).furniture;
    final chassis = f.chassis;
    if (chassis != null) return chassis.edgeClearance;
    return f.screws || f.seams ? ChassisFurniture.edgeClearance : 0;
  }

  @override
  Widget build(BuildContext context) {
    // `maybeOf`, never `of`. This widget wraps the app body, so an `AppLayout`
    // is always above it there — but the moment anything reuses it under a
    // dialog's route, which lives on the root navigator outside the layout,
    // `of` would throw. That exact crash is documented in main.dart.
    final isDark = themeNotifier.isDarkTheme;
    final spec = MaterialSpec.of(NeuTheme.activeMaterial);
    final showOrnament = showsFurniture(context);

    // DecoratedBox, not Container, and that is not a style preference.
    //
    // `Container` folds `decoration.padding` into layout, and
    // `SkeuoDecoration.padding` is `EdgeInsets.all(bevelWidth)` - correct for a
    // control, which really does inset its content by its own edge, and wrong
    // for the window, which has no content to inset. It cost the app body two
    // logical pixels: 378 inside a 380 window, so the portrait rail overflowed
    // its Row by exactly 2.0px at the enforced minimum, in every material,
    // independent of any data. Debug drew the striped banner; release clips
    // nothing and simply painted the trailing control past the window edge.
    //
    // The real-surface sweep never mounted this widget, so it measured 380
    // where the app had 378.
    // Two nested DecoratedBoxes rather than one Container: `DecoratedBox` has
    // no `foregroundDecoration`, and `position: DecorationPosition.foreground`
    // is the same thing spelled as a parameter.
    final ornament = showOrnament
        ? ChassisFurniture(
            furniture: spec.furniture,
            palette: NeuTheme.palette(isDark),
          )
        : null;

    Widget body = child;
    if (ornament != null) {
      body = DecoratedBox(
        decoration: ornament,
        position: DecorationPosition.foreground,
        child: body,
      );
    }

    return DecoratedBox(
      decoration:
          NeuTheme.panel(isDark, radius: 0, base: NeuTheme.canvas(isDark)),
      child: body,
    );
  }
}
