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
  group('accentInk', () {
    // Every accent the picker offers.
    const presets = <String, Color>{
      'Soft Pink': Color(0xFFFF6584),
      'Twitch Purple': Color(0xFF7C3AED),
      'Cyan': Color(0xFF00F2FE),
      'Emerald': Color(0xFF10B981),
      'Orange': Color(0xFFFF7A00),
      'Rose': Color(0xFFF43F5E),
      'Vibrant Red': Color(0xFFFF3B30),
      'Electric Purple': Color(0xFF8B5CF6),
      'Sky Blue': Color(0xFF38BDF8),
      'Magenta': Color(0xFFFF2A85),
      'Gold': Color(0xFFF59E0B),
    };

    test('every preset becomes readable on every ground', () {
      // Raw, several of these are unusable as a foreground: Cyan measures
      // 1.04:1 against the light well, and even the default Soft Pink 2.12:1.
      for (final isDark in [false, true]) {
        presets.forEach((name, accent) {
          expectInk('accentInk($name)', NeuTheme.accentInk(accent, isDark), isDark);
        });
      }
    });

    test('an accent that is already readable is returned untouched', () {
      // Derivation must not restyle what does not need it - 5 of the 11
      // presets pass as-is in dark mode and should keep the exact hue chosen.
      expect(NeuTheme.accentInk(const Color(0xFF00F2FE), true),
          const Color(0xFF00F2FE));
      expect(NeuTheme.accentInk(const Color(0xFFF59E0B), true),
          const Color(0xFFF59E0B));
    });

    test('the stored accent is never mutated', () {
      // The whole reason for deriving instead of restricting the palette:
      // fills, tints and glows must keep exactly what the user picked.
      const chosen = Color(0xFF00F2FE);
      NeuTheme.accentInk(chosen, false);
      expect(chosen, const Color(0xFF00F2FE));
    });

    test('survives values a hand-edited config could contain', () {
      const hostile = <Color>[
        Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFF7F7F7F),
        Color(0xFFEBECF0), Color(0xFFD8E0EB), Color(0xFF222632),
      ];
      for (final isDark in [false, true]) {
        for (final accent in hostile) {
          final ink = NeuTheme.accentInk(accent, isDark);
          final ground =
              isDark ? NeuTheme.surface(true) : NeuTheme.wellSurface(false);
          expect(NeuTheme.contrastRatio(ink, ground),
              greaterThanOrEqualTo(kTextAA),
              reason: '$accent (${isDark ? 'dark' : 'light'}) produced an '
                  'unreadable ink');
        }
      }
    });

    test('keeps the hue recognisable', () {
      // A darkened cyan must still read as cyan, or the accent has stopped
      // being the user's choice in any meaningful sense.
      const cyan = Color(0xFF00F2FE);
      final ink = NeuTheme.accentInk(cyan, false);
      final original = HSLColor.fromColor(cyan).hue;
      final derived = HSLColor.fromColor(ink).hue;
      expect((derived - original).abs(), lessThan(12.0),
          reason: 'hue drifted from $original to $derived');
    });
  });
}
