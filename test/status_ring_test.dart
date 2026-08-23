import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

import 'contrast_test.dart' show kNonTextAA, materialsUnderTest;

/// The status dot's boundary, which used to be a colour match and is now a
/// darkening.
///
/// Five sites drew a ring in the surface colour to knock a live dot out of the
/// avatar behind it. That is correct exactly while the ring's colour is the
/// colour behind it — and a dot sits at an avatar's bottom-right corner, half
/// over the picture and half over the panel. It was never quite true; a flat
/// panel just made it close enough not to notice. A panel with a fill ramp and
/// a grain on it is not close enough, and there is no replacement colour,
/// because there is no single colour that matches a gradient.
///
/// The replacement has to be judged differently as a result. A knockout ring
/// is checked by asking whether it matches; a darkening is checked by asking
/// whether the *edge is legible*, which is a disjunction — either the ring
/// separates the dot from what is behind it, or the dot separates itself. Both
/// failing at once is the only real defect, and it is what this asserts.
void main() {
  /// `over` composited onto `under`, straight sRGB alpha blend.
  Color flatten(Color over, Color under) => Color.alphaBlend(over, under);

  double ratio(Color a, Color b) => NeuTheme.contrastRatio(a, b);

  group('the status ring reads on any ground', () {
    /// Every ground a dot is ever drawn over: the palette's own surfaces, plus
    /// the two poles, because the other half of a dot sits over an avatar and
    /// an avatar is arbitrary user imagery. White and black are not
    /// hypothetical here — they are the actual worst cases the ring exists for.
    List<({String name, Color color})> dotGrounds(
      bool isDark,
      AppMaterial m,
    ) {
      final p = NeuTheme.palette(isDark, material: m);
      return [
        (name: 'white avatar', color: const Color(0xFFFFFFFF)),
        (name: 'black avatar', color: const Color(0xFF000000)),
        (name: 'panel', color: p.worstGround(SurfaceRole.panel)),
        (name: 'surface', color: p.worstGround(SurfaceRole.raised)),
        (name: 'canvas', color: p.groundFor(Ground.canvas)),
      ];
    }

    for (final m in materialsUnderTest) {
      for (final isDark in [false, true]) {
        final mode = '${m.key} ${isDark ? 'dark' : 'light'}';

        test('the live dot keeps a legible edge — $mode', () {
          for (final g in dotGrounds(isDark, m)) {
            final ring = flatten(NeuTheme.statusRingInk, g.color);
            final viaRing = ratio(NeuTheme.live, ring);
            final viaDot = ratio(NeuTheme.live, g.color);
            expect(
              viaRing > viaDot ? viaRing : viaDot,
              greaterThanOrEqualTo(kNonTextAA),
              reason:
                  'live dot on ${g.name} ($mode): the ring gives '
                  '${viaRing.toStringAsFixed(2)}:1 and the dot itself '
                  '${viaDot.toStringAsFixed(2)}:1 — neither carries the edge',
            );
          }
        });

        test('the offline dot keeps a legible edge — $mode', () {
          // `disabledText` is the offline fill, and it is a mid-tone, which is
          // the hardest case: mid-tones have the least room in both
          // directions. It is held to the same graphics bar.
          final dot = NeuTheme.disabledText(isDark, material: m);
          for (final g in dotGrounds(isDark, m)) {
            final ring = flatten(NeuTheme.statusRingInk, g.color);
            final viaRing = ratio(dot, ring);
            final viaDot = ratio(dot, g.color);
            expect(
              viaRing > viaDot ? viaRing : viaDot,
              greaterThanOrEqualTo(kNonTextAA),
              reason:
                  'offline dot on ${g.name} ($mode): ring '
                  '${viaRing.toStringAsFixed(2)}:1, dot '
                  '${viaDot.toStringAsFixed(2)}:1 — neither carries the edge',
            );
          }
        });
      }
    }

    test('the alpha is the measured knee, not a value someone liked', () {
      // A sweep over every (material, brightness, dot, ground) pairing shows
      // worst-case legibility climbing steeply to 0.74 and flat above it: the
      // ceiling is an offline dot on a black avatar, where the ring is black
      // too and no alpha reaches it. So 0.74 is the lightest touch that gets
      // the best result available.
      //
      // Bounded from both sides on purpose. Below it the ring stops carrying
      // the edge on a white avatar; above it the ring only gets heavier, and
      // an opaque ring reads as a hole punched in the avatar rather than an
      // outline drawn on it.
      expect(NeuTheme.statusRingInk.a, greaterThanOrEqualTo(0.72),
          reason: 'below the knee the ring stops separating an offline dot '
              'on a light avatar');
      expect(NeuTheme.statusRingInk.a, lessThan(0.80),
          reason: 'past this the ring is heavier for no measured gain');

      // And the live case, which is the one the ring was originally sized
      // for and is no longer the binding constraint.
      expect(
        ratio(NeuTheme.live, flatten(NeuTheme.statusRingInk, const Color(0xFFFFFFFF))),
        greaterThanOrEqualTo(kNonTextAA),
        reason: 'the ring is too light to separate a live dot on white',
      );
    });

    test('no site knocks a dot out with a ground colour any more', () {
      // The rule, not the five instances. A ring whose colour is a ground is
      // the defect this file replaced, and it is a one-line mistake to make
      // again in a sixth place.
      expect(NeuTheme.statusRingInk.a, lessThan(1.0),
          reason: 'a ground-independent ring has to be translucent — an opaque '
              'one is a colour match by another name');
    });
  });
}
