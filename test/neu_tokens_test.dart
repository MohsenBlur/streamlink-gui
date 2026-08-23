import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

void main() {
  group('NeuElevation', () {
    test('blur is always twice the depth', () {
      // Every well-behaved surface already used this ratio (6/12, 5/10, 2/4).
      // The two that did not - NeuTextField at 4/12 and one sidebar container
      // at 3/12 - read visibly mushier than everything around them.
      for (final depth in NeuElevation.steps) {
        expect(NeuElevation.blurFor(depth), depth * 2);
      }
    });

    test('raise and lower land on real steps, never between them', () {
      // The old code did `(depth * 0.35).clamp(1.0, 3.0)` for pressed and
      // `depth + 2` for hover, which produced values off the scale - which is
      // why a pressed button and a sunken panel never quite matched.
      for (final depth in NeuElevation.steps) {
        expect(NeuElevation.steps, contains(NeuElevation.raise(depth)));
        expect(NeuElevation.steps, contains(NeuElevation.lower(depth)));
      }
    });

    test('raise goes up, lower goes down', () {
      expect(NeuElevation.raise(NeuElevation.d3), NeuElevation.d4);
      expect(NeuElevation.lower(NeuElevation.d3), NeuElevation.d2);
      expect(NeuElevation.raise(NeuElevation.d0), NeuElevation.d1);
    });

    test('the ends of the scale are stable', () {
      // A hover on the topmost surface must not walk off the scale.
      expect(NeuElevation.raise(NeuElevation.d5), NeuElevation.d5);
      expect(NeuElevation.lower(NeuElevation.d0), NeuElevation.d0);
    });
  });

  group('NeuRadius.inner', () {
    test('a flush child matches its parent exactly', () {
      // inset 0 means the child's edge IS the parent's edge.
      expect(NeuRadius.inner(NeuRadius.r16, 0), NeuRadius.r16);
    });

    test('a 1px border costs exactly 1px of radius', () {
      // The VOD card: 16px card, 1px border, thumbnail flush inside. It was
      // clipped at 11, leaving a visible crescent of card colour in each
      // corner. The concentric answer is 15.
      expect(NeuRadius.inner(NeuRadius.r16, 1), 15);
    });

    test('the case that was already right stays right', () {
      // The dashboard tile: 12px container, 1px border -> 11. Someone got this
      // one correct by eye, and the rule must not "fix" it.
      expect(NeuRadius.inner(NeuRadius.r12, 1), 11);
    });

    test('never goes negative', () {
      expect(NeuRadius.inner(NeuRadius.r4, 10), 0);
    });

    test('a pill stays a pill', () {
      // A fully-round shape's inner is also fully round, not 999 minus the
      // inset - which would be a nearly-square corner.
      expect(NeuRadius.inner(NeuRadius.pill, 8), NeuRadius.pill);
    });
  });

  group('the one neumorphic recipe', () {
    test('raised and sunken agree on their geometry inputs', () {
      // Two recipes existed and a comment claimed they matched; they differed
      // on three of five properties.
      final raised = NeuTheme.raised(true, radius: NeuRadius.r12);
      final sunken = NeuTheme.sunken(true, radius: NeuRadius.r12);
      expect(raised.borderRadius, BorderRadius.circular(NeuRadius.r12));
      expect(sunken.borderRadius, BorderRadius.circular(NeuRadius.r12));
    });

    test('raised paints a gradient, not a flat fill', () {
      // The gradient is what makes a surface read as extruded material rather
      // than a card with a drop shadow.
      final d = NeuTheme.raised(true);
      expect(d.gradient, isNotNull);
      expect(d.color, isNull, reason: 'the gradient owns the fill');
    });

    test('depth drives the shadow offsets', () {
      final shallow = NeuTheme.raised(true, depth: NeuElevation.d1);
      final deep = NeuTheme.raised(true, depth: NeuElevation.d5);
      expect(deep.boxShadow!.first.offset.dx.abs(),
          greaterThan(shallow.boxShadow!.first.offset.dx.abs()));
      expect(deep.boxShadow!.first.blurRadius,
          greaterThan(shallow.boxShadow!.first.blurRadius));
    });

    test('zero depth means no shadow at all', () {
      // The disabled treatment: flat, not merely shallow.
      expect(NeuTheme.raised(true, depth: NeuElevation.d0).boxShadow, isEmpty);
      expect(NeuTheme.sunken(true, depth: NeuElevation.d0).boxShadow, isEmpty);
    });

    test('sunken defaults to the well, not the surface', () {
      // NeuSwitch's off-track defaulted to the surface colour, which is the
      // exact colour of the panel behind it - so the off state was invisible
      // in light mode.
      for (final isDark in [true, false]) {
        expect(NeuTheme.sunken(isDark).color, NeuTheme.wellSurface(isDark));
        expect(NeuTheme.sunken(isDark).color,
            isNot(NeuTheme.surface(isDark)));
      }
    });

    test('the legacy names still work and still produce a gradient', () {
      // ~36 call sites use raisedDecoration and were not edited; they must
      // keep compiling AND pick up the unified recipe.
      final legacy = NeuTheme.raisedDecoration(true);
      expect(legacy.gradient, isNotNull);
    });
  });
}
