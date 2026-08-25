/// Geometry and depth scales.
///
/// Re-exported by `neu_theme.dart`, so every file that already imports the
/// theme gets these with no new import line. That matters: `NeuTheme.` appears
/// in ~30 files, and a scale nobody can reach without editing an import is a
/// scale nobody uses.
library;

import 'package:flutter/painting.dart';

/// Spacing.
///
/// A 4pt base with a 2pt sub-grid below 8. NOT a strict 4pt grid: `6` appears
/// 57 times in `SizedBox` alone, and rounding all of those to 4 or 8 would
/// destroy a micro-rhythm the app already has. 4/6/8/12/16 already cover about
/// 70% of the 313 spacers in the codebase, so this is mostly ratification.
///
/// Numeric names rather than t-shirt sizes, because the migration is then
/// mechanical (`8` becomes `NeuSpace.s8`) and a value off the scale is a
/// compile error rather than a judgement call.
abstract final class NeuSpace {
  /// Hairline: icon to its own glyph, badge insets.
  /// Hairline. Exists for widget-layer furniture - an engraved groove is two
  /// 1px walls, and the scrubber is right to ask where a bare 1 came from.
  static const double s1 = 1;


  static const double s2 = 2;

  /// Intra-control.
  static const double s4 = 4;

  /// Icon to label.
  static const double s6 = 6;

  /// A tight group.
  static const double s8 = 8;

  /// Related items; control padding.
  static const double s12 = 12;

  /// Section padding; grid gutter.
  static const double s16 = 16;

  /// Panel padding.
  static const double s20 = 20;

  /// Dialog padding; a section break.
  static const double s24 = 24;

  /// A major section break.
  static const double s32 = 32;

  /// Page top and bottom.
  static const double s40 = 40;

  /// Breathing room around an empty state.
  static const double s64 = 64;
}

/// Corner radii.
///
/// The literals in use were 8x26, 16x21, 6x14, 4x10, 12x5, plus 22, 20, 18, 11,
/// 10 and 2 - and the component defaults disagreed with each other:
/// NeuContainer 16, NeuButton 20, NeuCard 20, NeuTextField 22, NeuFocusable 12.
abstract final class NeuRadius {
  /// Progress fills, hairline chips.
  static const double r2 = 2;

  /// Scrim pills over artwork.
  static const double r4 = 4;

  /// Tooltips, tiny inline chips.
  static const double r6 = 6;

  /// Inputs inside rows, small buttons, badges.
  static const double r8 = 8;

  /// The default: containers, list rows, popovers.
  static const double r12 = 12;

  /// Cards, dialogs, panels.
  static const double r16 = 16;

  /// Large hero surfaces.
  static const double r20 = 20;

  /// Fully round: chips, switches, segmented controls, search fields.
  static const double pill = 999;

  /// The radius an element nested inside a rounded parent should use.
  ///
  /// Concentric-radius rule: `inner = outer - inset`, where inset is the gap
  /// between the parent's outer edge and the child's edge (its padding plus its
  /// border width). Two rounded rectangles only stay parallel at this value;
  /// eyeballing it is why a thumbnail clipped at 11 inside a 16px card with a
  /// 1px border left a visible crescent in each corner - it should be 15.
  ///
  /// [pill] stays [pill]: a fully-round shape's inner is also fully round, not
  /// 999 minus the inset.
  static double inner(double outer, double inset) {
    if (outer >= pill) return pill;
    final value = outer - inset;
    return value < 0 ? 0 : value;
  }
}

/// Neumorphic depth.
///
/// Depth and blur are not independent: every well-behaved surface in the app
/// already used `blur = 2 x depth` (6/12, 5/10, 2/4). The two that did not -
/// NeuTextField at 4/12 and one sidebar container at 3/12 - visibly read
/// mushier than everything around them. The scale enforces the ratio so that
/// cannot recur.
abstract final class NeuElevation {
  /// Flat. Disabled controls and inert fills - no shadow at all.
  static const double d0 = 0;

  /// Switch knobs, LED bezels, inline chips.
  static const double d1 = 2;

  /// Text fields, segmented thumbs, list rows.
  static const double d2 = 3;

  /// The default raised surface: buttons, chips, header tiles.
  static const double d3 = 5;

  /// Cards, panels, grid tiles.
  static const double d4 = 8;

  /// Popovers and menus floating over app surfaces.
  ///
  /// Dialogs used to be excluded from this on the grounds that they sit on a
  /// scrim, and neumorphism's premise is extrusion from the surface behind —
  /// so a white bevel bleeding onto a black scrim was an artefact rather than
  /// depth. That reasoning was specific to neumorphism. A material is not
  /// extruded from anything; it is an object, and a panel in front of another
  /// panel is what a dialog is. They take `d4` now.
  static const double d5 = 12;

  /// Blur is always twice the depth.
  static double blurFor(double depth) => depth * 2;

  static const List<double> steps = [d0, d1, d2, d3, d4, d5];

  /// The next step up, for hover. Clamped, so the top of the scale is stable.
  static double raise(double depth) {
    for (final step in steps) {
      if (step > depth) return step;
    }
    return steps.last;
  }

  /// The next step down, for pressed and selected states.
  ///
  /// Scale-relative rather than arithmetic (the old code did
  /// `(depth * 0.35).clamp(1.0, 3.0)`), so a state always lands on a real step
  /// instead of somewhere between two.
  static double lower(double depth) {
    double previous = steps.first;
    for (final step in steps) {
      if (step >= depth) return previous;
      previous = step;
    }
    return previous;
  }
}

/// The room a lit surface's shadow needs inside any clipping ancestor.
///
/// One definition, derived from the shadow geometry the painter actually
/// uses (cast reach = dy + blur at the common depths, ambient halo above,
/// lateral occlusion beside), so a strip cannot re-tune it by hand and get
/// the top right while cutting the bottom - which is exactly how the filter
/// chips lost the halo above them while gaining room below.
abstract final class NeuShadowRoom {
  /// Sized for the WORST material, which is the second lesson this class
  /// carries. The first values were derived from Rack - vertical light,
  /// small ambient halo, so `above: 6` - and Soft promptly proved them
  /// wrong: its light-side cast travels UP-LEFT at Offset(-d, -d) with a
  /// blur of 2d, reaching offset + blur = 3d = 15px above and beside a
  /// surface at the default raised depth. The user saw the chips' top glow
  /// sliced flat within the hour. Clearance that only fits the material it
  /// was measured on is the same per-site hand-tuning this class exists to
  /// end, one level up.
  static const double above = 16;

  /// The downward/down-right cast: offset plus blur plus occlusion tail.
  static const double below = 20;

  static const double side = 16;

  /// The full clearance, for a horizontal strip's interior padding.
  static const EdgeInsets strip = EdgeInsets.fromLTRB(side, above, side, below);

  /// For a VERTICAL list's interior padding: glow room at the top extreme,
  /// cast room at the bottom one. Lateral room in a list comes from the
  /// rows' own margins.
  static const EdgeInsets list = EdgeInsets.only(top: above, bottom: below);
}
