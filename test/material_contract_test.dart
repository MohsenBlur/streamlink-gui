import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

import 'support/legacy_recipe.dart';

/// The contract every material palette must satisfy, and the proof that `Soft`
/// reproduces the recipe the app shipped through v1.6.0.
///
/// `Soft` is not a nostalgia option — it is the gate. If the engine cannot
/// express the old material *from data*, the abstraction is a rack-gear special
/// case wearing a coat of paint and every material built on it inherits that.
/// So these assertions run against a **frozen copy** of the v1.6.0 recipe
/// (`test/support/legacy_recipe.dart`) rather than against numbers typed into
/// this file, which would only prove that two transcriptions agree — and
/// rather than against the live `NeuTheme.raised()`, which now *is* the engine
/// and would compare it against itself.
void main() {
  group('every palette satisfies the schema contract', () {
    // These were asserts in the constructor until a const constructor turned
    // out to be unable to read `.length` off a list. Here they can also check
    // ordering, which an assert could not do cheaply.
    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final label = '${spec.id.key} ${isDark ? 'dark' : 'light'}';
        final p = spec.palette(isDark);

        test('$label — the fill is a real ramp', () {
          expect(p.fill.length, greaterThanOrEqualTo(2),
              reason: 'a fill needs at least two stops');
          expect(p.fill.first.at, 0.0);
          expect(p.fill.last.at, 1.0);
          for (var i = 1; i < p.fill.length; i++) {
            expect(p.fill[i].at, greaterThan(p.fill[i - 1].at),
                reason: 'stop positions must ascend');
          }
        });

        test('$label — no stop resolves to pure white or black', () {
          // The failure this catches is silent and one-directional: clamping
          // lightness at 1.0 yields chroma 0, so a stop can collapse to
          // #FFFFFF — which violates the material rule *and* is invisible to a
          // contrast check, because white improves every dark ink.
          for (final ground in Ground.values) {
            for (final stop in p.fill) {
              final c = p.shadeStop(p.groundFor(ground), stop);
              expect(c, isNot(const Color(0xFFFFFFFF)),
                  reason: '$label $ground stop at ${stop.at} hit pure white');
              expect(c, isNot(const Color(0xFF000000)),
                  reason: '$label $ground stop at ${stop.at} hit pure black');
            }
          }
        });

        test('$label — worstGround picks the extreme that actually hurts', () {
          // Asymmetric twice over, and both directions matter.
          //
          // A fill that darkens hurts dark ink and helps light ink, so the
          // worst stop is the darkest where the ink is dark and the lightest
          // where it is light. Getting that backwards would make every
          // contrast assertion in the app measure the friendly end.
          //
          // The polarity is the INK's, not the palette's, and the two part
          // company on exactly one role: an emissive screen stays dark inside
          // a light material, so it carries light ink while every other
          // surface in that palette carries dark. Asking `p.isLight` here
          // returned the darkest screen stop — the friendliest ground there
          // is — and the log pane's contrast matrix passed on the worst stop
          // while failing on the flat token.
          //
          // The grain is asymmetric the same way: it only lightens, so it
          // pushes a light-ink worst case further and moves a dark-ink one
          // away from its worst case entirely.
          for (final role in SurfaceRole.values) {
            final worst = p.worstGround(role).computeLuminance();
            final base = p.groundFor(RoleModifier.of(role).fill);
            final stops = [base, for (final s in p.fill) p.shadeStop(base, s)];
            final lum = stops.map((c) => c.computeLuminance()).toList()..sort();
            final amp = p.texture?.amplitudeFor(role) ?? 0;
            final gloss = p.gloss * RoleModifier.of(role).glossScale;
            final inkIsDark = p.inkIsDarkOn(role);
            // Both lighteners, and the branch has to name both. An earlier
            // version keyed only on the grain, which happened to pass because
            // no role in the shipped materials carries gloss without also
            // carrying grain - a coincidence, not a rule, and the first
            // material that broke it would have failed here for the wrong
            // reason.
            final lightened = amp > 0 || gloss > 0;

            if (inkIsDark) {
              expect(worst, closeTo(lum.first, 1e-9),
                  reason: '$label $role picked the wrong extreme');
            } else if (!lightened) {
              expect(worst, closeTo(lum.last, 1e-9),
                  reason: '$label $role picked the wrong extreme');
            } else {
              expect(worst, greaterThan(lum.last),
                  reason: '$label $role must include the layers that composite '
                      'OVER the fill - the grain and the gloss are the '
                      'lightest things the surface ever shows, and both peak '
                      'at the same corner the lightest stop is at');
            }
          }
        });

        test('$label — the screen is the role that breaks with the palette',
            () {
          // Guards the rule rather than the value. An emissive screen does not
          // track the theme, so in a light palette its ink polarity is
          // inverted relative to every other role — and that inversion is what
          // `worstGround` and `inkOnScreen` both key off. If a material ever
          // makes them agree, this says so out loud instead of quietly
          // deleting the distinction.
          expect(p.inkIsDarkOn(SurfaceRole.panel), p.isLight,
              reason: 'a surface role must follow the palette');
          if (p.screenIsEmissive && p.isLight) {
            expect(p.inkIsDarkOn(SurfaceRole.screen), isFalse,
                reason: '$label declares an emissive screen, so it must be '
                    'dark enough to carry light ink even in a light material');
          }
        });
      }
    }
  });

  group('Soft reproduces the v1.6.0 recipe', () {
    // Depths deliberately spanning the scale: if the layers were transcribed
    // as pixels rather than as multiples of depth, only one of these passes.
    const depths = [NeuElevation.d1, NeuElevation.d2, NeuElevation.d3,
                    NeuElevation.d4, NeuElevation.d5];

    for (final isDark in [false, true]) {
      final mode = isDark ? 'dark' : 'light';
      final p = softSpec.palette(isDark);

      test('grounds and inks are the raw v1.6.0 tokens — $mode', () {
        // The `raw*` tokens, not the public accessors: those resolve through
        // the active material, which is Rack. Asserting against them would
        // compare Soft to whatever is currently selected.
        expect(p.canvas, NeuTheme.rawCanvas(isDark));
        expect(p.surface, NeuTheme.rawSurface(isDark));
        expect(p.well, NeuTheme.rawWellSurface(isDark));
        expect(p.text, NeuTheme.rawText(isDark));
        expect(p.subtext, NeuTheme.rawSubtext(isDark));
        expect(p.border, NeuTheme.rawBorder(isDark));
        expect(p.highlight, NeuTheme.rawHighlight(isDark));
        expect(p.shadow, NeuTheme.rawShadow(isDark));
        expect(p.disabledText, NeuTheme.rawDisabledText(isDark));
      });

      test('the fill is the shipped two-stop gradient — $mode', () {
        // raised() paints [base, fillFloor(base)]. Two stops, and the second
        // is exactly one fillSpread down.
        expect(p.fill, hasLength(2));
        expect(p.fill.last.dl, -NeuTheme.fillSpread);
        expect(p.fill.last.dh, 0.0);
        expect(p.fill.last.ds, 0.0);

        final shipped = legacyRaised(isDark).gradient! as LinearGradient;
        expect(shipped.colors.first, p.surface);
        expect(shipped.colors.last, NeuTheme.fillFloor(p.surface));
      });

      for (final depth in depths) {
        test('the contact stack matches raised(depth: $depth) — $mode', () {
          final shipped = legacyRaised(isDark, depth: depth).boxShadow!;
          expect(p.contact, hasLength(shipped.length));

          for (var i = 0; i < shipped.length; i++) {
            final s = shipped[i];
            final l = p.contact[i];
            expect(Offset(l.dx * depth, l.dy * depth), s.offset,
                reason: 'layer $i offset at depth $depth');
            expect(l.blur * depth, s.blurRadius,
                reason: 'layer $i blur at depth $depth');
            expect(l.spread * depth, s.spreadRadius,
                reason: 'layer $i spread at depth $depth');
            expect(l.color, s.color, reason: 'layer $i colour');
          }
        });

        test('the recess stack matches sunken(depth: $depth) — $mode', () {
          final shipped = legacySunken(isDark, depth: depth).boxShadow!;
          expect(p.inset, hasLength(shipped.length));

          for (var i = 0; i < shipped.length; i++) {
            final s = shipped[i];
            final l = p.inset[i];
            expect(Offset(l.dx * depth, l.dy * depth), s.offset,
                reason: 'layer $i offset at depth $depth');
            expect(l.blur * depth, s.blurRadius,
                reason: 'layer $i blur at depth $depth');
            expect(l.spread * depth, s.spreadRadius,
                reason: 'layer $i spread at depth $depth — sunken carries '
                    'spreadRadius -depth/2 and losing it is visible');
            expect(l.color, s.color, reason: 'layer $i colour');
          }
        });
      }

      test('Soft declares itself soft — $mode', () {
        // The CI half of the fidelity gate. A palette that quietly grew a
        // texture or a gloss would still paint *something* reasonable, and
        // nothing else would notice.
        expect(p.texture, isNull, reason: 'Soft has no texture');
        expect(p.gloss, 0, reason: 'Soft has no gloss');
        expect(p.bevelUniform, isTrue,
            reason: "Soft's bevel is a uniform ring, not a swept envelope");
        expect(p.contact, hasLength(2));
        expect(p.recessStyle, RecessStyle.outerFake,
            reason: "Soft's recess is an outer shadow pair with negative "
                'spread, not a true inset — that is what it looked like');
        expect(p.diagonalCompensation, isFalse,
            reason: 'Soft\'s Offset(d, d) really does travel 1.414 * d');
        expect(softSpec.furniture.isNone, isTrue);
        expect(softSpec.overlayBlur, isNull);
      });
    }

    test('the well is genuinely recessed relative to the surface', () {
      // The assertion neu_tokens_test currently makes about sunken().color,
      // restated against the palette so the guard survives the widening. It
      // caught NeuSwitch shipping an off-track that was invisible in light
      // mode, and it has no other successor.
      for (final isDark in [false, true]) {
        final p = softSpec.palette(isDark);
        expect(p.well, isNot(p.surface),
            reason: 'a well that equals its surface is not a well');
        expect(p.well, NeuTheme.rawWellSurface(isDark));
      }
    });
  });

  group('the material key survives a round trip', () {
    test('known keys resolve, unknown ones do not', () {
      for (final m in AppMaterial.values) {
        expect(AppMaterial.fromKey(m.key), m);
      }
      expect(AppMaterial.fromKey('not-a-material'), isNull);
      expect(AppMaterial.fromKey(null), isNull);
      // Guards the case that actually bites: a v1.8.0 config met by a v1.7.0
      // build. `fromKey` returning null is what lets the caller fall back
      // instead of clamping and destroying the choice on the next save.
      expect(AppMaterial.fromKey('deck'), AppMaterial.deck);
    });

    test('only implemented materials are offered', () {
      for (final spec in MaterialSpec.available) {
        expect(MaterialSpec.isImplemented(spec.id), isTrue);
        expect(MaterialSpec.of(spec.id), same(spec));
      }
    });
  });
}
