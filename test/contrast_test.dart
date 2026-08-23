import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// Contrast is the one visual property that is objectively checkable, and the
/// app had four failing tokens plus an accent that could render text at 1.09:1
/// while every test passed. These assert ratios rather than colours, so a
/// future palette change is free to move a hex but not free to make it
/// unreadable.
///
/// AA thresholds: 4.5:1 for body text, 3:1 for large text and for meaningful
/// non-text graphics (WCAG 1.4.11).
const double kTextAA = 4.5;
const double kNonTextAA = 3.0;

/// Every ground an ink can land on, per theme. An ink must clear its bar
/// against the *worst* of these, not just the one it was designed against.
List<({String name, Color color})> groundsFor(bool isDark) => [
      (name: 'canvas', color: NeuTheme.canvas(isDark)),
      (name: 'surface', color: NeuTheme.surface(isDark)),
      (name: 'well', color: NeuTheme.wellSurface(isDark)),
    ];

void expectInk(
  String label,
  Color ink,
  bool isDark, {
  double min = kTextAA,
}) {
  for (final ground in groundsFor(isDark)) {
    final ratio = NeuTheme.contrastRatio(ink, ground.color);
    expect(ratio, greaterThanOrEqualTo(min),
        reason: '$label on ${ground.name} '
            '(${isDark ? 'dark' : 'light'}) measured '
            '${ratio.toStringAsFixed(2)}:1, needs $min:1');
  }
}

void main() {
  group('text inks clear AA on every ground', () {
    for (final isDark in [false, true]) {
      final mode = isDark ? 'dark' : 'light';

      test('primary text — $mode', () {
        expectInk('text', NeuTheme.text(isDark), isDark);
      });

      test('subtext — $mode', () {
        // The regression that mattered most: this is subtextStyle's default
        // ink at 11px, the most-used size in the app, and it measured 3.40:1.
        expectInk('subtext', NeuTheme.subtext(isDark), isDark);
      });

      test('semantic status inks — $mode', () {
        expectInk('liveText', NeuTheme.liveText(isDark), isDark);
        expectInk('dangerText', NeuTheme.dangerText(isDark), isDark);
        expectInk('warningText', NeuTheme.warningText(isDark), isDark);
      });

      test('non-text inks clear the 3:1 bar — $mode', () {
        // Disabled labels and the favourite star are never body copy, so they
        // are held to the graphics bar rather than the text bar.
        expectInk('disabledText', NeuTheme.disabledText(isDark), isDark,
            min: kNonTextAA);
        expectInk('favoriteText', NeuTheme.favoriteText(isDark), isDark,
            min: kNonTextAA);
      });
    }
  });

  group('surfaces are distinguishable from the page', () {
    test('the canvas is not the surface', () {
      // They were the same hex in light mode (1.000:1), so a raised card was
      // visible only by its shadow.
      for (final isDark in [false, true]) {
        final ratio = NeuTheme.contrastRatio(
            NeuTheme.canvas(isDark), NeuTheme.surface(isDark));
        expect(ratio, greaterThan(1.02),
            reason: '${isDark ? 'dark' : 'light'} canvas/surface separation is '
                'only ${ratio.toStringAsFixed(3)}:1');
      }
    });

    test('background is an alias of canvas', () {
      for (final isDark in [false, true]) {
        expect(NeuTheme.background(isDark), NeuTheme.canvas(isDark));
      }
    });
  });

  group('contrastRatio', () {
    test('matches known WCAG values', () {
      expect(
          NeuTheme.contrastRatio(
              const Color(0xFF000000), const Color(0xFFFFFFFF)),
          closeTo(21.0, 0.01));
      expect(
          NeuTheme.contrastRatio(
              const Color(0xFFFFFFFF), const Color(0xFFFFFFFF)),
          closeTo(1.0, 0.001));
    });

    test('is symmetric', () {
      const a = Color(0xFF4F5F75);
      const b = Color(0xFFE1E4EA);
      expect(NeuTheme.contrastRatio(a, b),
          closeTo(NeuTheme.contrastRatio(b, a), 1e-9));
    });
  });
}
