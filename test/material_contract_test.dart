import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

import 'support/legacy_recipe.dart';

/// The contract the palette must satisfy, and the proof that `Soft`
/// reproduces the recipe the app shipped through v1.6.0.
///
/// These assertions run against a **frozen copy** of the v1.6.0 recipe
/// (`test/support/legacy_recipe.dart`) rather than against numbers typed into
/// this file, which would only prove that two transcriptions agree — and
/// rather than against the live `NeuTheme.raised()`, which now *is* the engine
/// and would compare it against itself.
void main() {
  group('the palette satisfies the schema contract', () {
    // These were asserts in the constructor until a const constructor turned
    // out to be unable to read `.length` off a list. Here they can also check
    // ordering, which an assert could not do cheaply.
    for (final isDark in [false, true]) {
      final label = isDark ? 'dark' : 'light';
      final p = softSpec.palette(isDark);

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
        // A fill that darkens hurts dark ink and helps light ink, so the
        // worst stop is the darkest where the ink is dark and the lightest
        // where it is light. Getting that backwards would make every
        // contrast assertion in the app measure the friendly end.
        for (final role in SurfaceRole.values) {
          final worst = p.worstGround(role).computeLuminance();
          final base = p.groundFor(RoleModifier.of(role).fill);
          final stops = [base, for (final s in p.fill) p.shadeStop(base, s)];
          final lum = stops.map((c) => c.computeLuminance()).toList()..sort();
          expect(worst, closeTo(p.inkIsDarkOn(role) ? lum.first : lum.last, 1e-9),
              reason: '$label $role picked the wrong extreme');
        }
      });

      test('$label — the surface roles follow the palette', () {
        // `worstGround` and `inkOnScreen` key off the ink's polarity per
        // role; every role whose ground is part of the surface family must
        // carry the palette's own.
        for (final role in SurfaceRole.values) {
          if (RoleModifier.of(role).fill == Ground.screen) continue;
          expect(p.inkIsDarkOn(role), p.isLight,
              reason: '$label $role must follow the palette');
        }
      });
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
        // this very palette, and asserting against them would compare Soft
        // with itself.
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

        // Depth 0, because this assertion is about the STOPS, not the casts.
        final shipped =
            legacyRaised(isDark, depth: 0).gradient! as LinearGradient;
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
        // The CI half of the fidelity gate: the declarations a tidy-up would
        // most likely "correct".
        expect(p.contact, hasLength(2));
        expect(p.diagonalCompensation, isFalse,
            reason: 'Soft\'s Offset(d, d) really does travel 1.414 * d');
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
}
