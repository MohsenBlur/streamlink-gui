import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// The contract every material palette must satisfy, and the proof that `Soft`
/// reproduces the recipe the app shipped through v1.6.0.
///
/// `Soft` is not a nostalgia option — it is the gate. If the engine cannot
/// express the old material *from data*, the abstraction is a rack-gear special
/// case wearing a coat of paint and every material built on it inherits that.
/// So these assertions run against the live `NeuTheme.raised()` / `sunken()`
/// output rather than against numbers copied into the test, which would only
/// prove that two transcriptions agree.
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
          // Asymmetric on purpose: a fill that darkens hurts dark ink and
          // helps light ink. Getting this backwards would make every contrast
          // assertion in the app measure the friendly end.
          for (final role in SurfaceRole.values) {
            final worst = p.worstGround(role);
            final base = p.groundFor(RoleModifier.of(role).fill);
            final stops = [base, for (final s in p.fill) p.shadeStop(base, s)];
            final lum = stops.map((c) => c.computeLuminance()).toList()..sort();
            expect(worst.computeLuminance(),
                closeTo(p.isLight ? lum.first : lum.last, 1e-9),
                reason: '$label $role picked the wrong extreme');
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

      test('grounds and inks are the live tokens — $mode', () {
        expect(p.canvas, NeuTheme.canvas(isDark));
        expect(p.surface, NeuTheme.surface(isDark));
        expect(p.well, NeuTheme.wellSurface(isDark));
        expect(p.text, NeuTheme.text(isDark));
        expect(p.subtext, NeuTheme.subtext(isDark));
        expect(p.border, NeuTheme.border(isDark));
        expect(p.highlight, NeuTheme.highlight(isDark));
        expect(p.shadow, NeuTheme.shadow(isDark));
        expect(p.disabledText, NeuTheme.disabledText(isDark));
      });

      test('the fill is the shipped two-stop gradient — $mode', () {
        // raised() paints [base, fillFloor(base)]. Two stops, and the second
        // is exactly one fillSpread down.
        expect(p.fill, hasLength(2));
        expect(p.fill.last.dl, -NeuTheme.fillSpread);
        expect(p.fill.last.dh, 0.0);
        expect(p.fill.last.ds, 0.0);

        final shipped = NeuTheme.raised(isDark).gradient as LinearGradient;
        expect(shipped.colors.first, p.surface);
        expect(shipped.colors.last, NeuTheme.fillFloor(p.surface));
      });

      for (final depth in depths) {
        test('the contact stack matches raised(depth: $depth) — $mode', () {
          final shipped = NeuTheme.raised(isDark, depth: depth).boxShadow!;
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
          final shipped = NeuTheme.sunken(isDark, depth: depth).boxShadow!;
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
        expect(p.well, NeuTheme.wellSurface(isDark));
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
