import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
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
///
/// Each base appears twice: once flat, and once at the darkest point its
/// gradient reaches. That second entry is the one that matters and the one
/// this file used to omit.
///
/// WCAG technique F83 is explicit that contrast over a non-uniform background
/// is judged against the worst pixel behind the letter - "the area of the
/// image that is darkest (for dark text) or lightest (for light text)" - not
/// against an average and not against the declared base colour. Because
/// `NeuTheme.raised()` paints `[base, fillFloor(base)]`, no text in this app
/// has ever actually sat on a flat token.
///
/// Checking only the bases hid seven real failures, all in the light theme,
/// where darkening the fill costs dark ink contrast. The dark theme is immune
/// for the same reason inverted: darkening the fill *helps* light ink. That
/// asymmetry is why the light palette has so much less gradient headroom.
List<({String name, Color color})> groundsFor(
  bool isDark, {
  AppMaterial? material,
}) {
  final p = NeuTheme.palette(isDark, material: material);
  final seen = <int>{};
  final out = <({String name, Color color})>[];
  void add(String name, Color c) {
    if (seen.add(c.toARGB32())) out.add((name: name, color: c));
  }

  // Every role's ground, and the worst point that role's fill reaches. `screen`
  // is excluded: it is dark in both brightnesses, so it is not a ground the
  // ordinary inks are ever asked to survive - it has its own derivation.
  for (final role in SurfaceRole.values) {
    if (RoleModifier.of(role).fill == Ground.screen) continue;
    final base = p.groundFor(RoleModifier.of(role).fill);
    add(role.name, base);
    add('${role.name} worst stop', p.worstGround(role));
  }
  return out;
}

/// The materials the matrix runs over.
///
/// Read through `MaterialSpec.available` rather than `AppMaterial.values`, so
/// the suite covers what actually exists and grows on its own as materials
/// land.
List<AppMaterial> get materialsUnderTest =>
    MaterialSpec.available.map((s) => s.id).toList();

/// Every accent the picker offers.
const Map<String, Color> kAccentPresets = <String, Color>{
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

/// The screen's own grounds - flat, and the worst point its fill reaches.
///
/// Kept apart from [groundsFor] on purpose. A screen is dark in **both**
/// brightnesses, so it is not a ground the ordinary inks are ever asked to
/// survive, and folding it in would make every light palette unsatisfiable. It
/// is the ground for exactly one family of inks, and this is that family's
/// matrix.
List<({String name, Color color})> screenGroundsFor(
  bool isDark, {
  AppMaterial? material,
}) {
  final p = NeuTheme.palette(isDark, material: material);
  final worst = p.worstGround(SurfaceRole.screen);
  return [
    (name: 'screen', color: p.screen),
    if (worst.toARGB32() != p.screen.toARGB32())
      (name: 'screen worst stop', color: worst),
  ];
}

void expectInkOnScreen(
  String label,
  Color ink,
  bool isDark, {
  double min = kTextAA,
  AppMaterial? material,
}) {
  for (final ground in screenGroundsFor(isDark, material: material)) {
    final ratio = NeuTheme.contrastRatio(ink, ground.color);
    expect(
      ratio,
      greaterThanOrEqualTo(min),
      reason:
          '$label on ${ground.name} '
          '(${material?.key ?? 'active'}, ${isDark ? 'dark' : 'light'}) '
          'measured ${ratio.toStringAsFixed(2)}:1, needs $min:1',
    );
  }
}

void expectInk(
  String label,
  Color ink,
  bool isDark, {
  double min = kTextAA,
  AppMaterial? material,
}) {
  for (final ground in groundsFor(isDark, material: material)) {
    final ratio = NeuTheme.contrastRatio(ink, ground.color);
    expect(
      ratio,
      greaterThanOrEqualTo(min),
      reason:
          '$label on ${ground.name} '
          '(${material?.key ?? 'active'}, ${isDark ? 'dark' : 'light'}) '
          'measured ${ratio.toStringAsFixed(2)}:1, needs $min:1',
    );
  }
}

void main() {
  group('text inks clear AA on every ground', () {
    // The material axis, added because a suite that only ever exercised the
    // default would report green for every other material. Selected by
    // parameter rather than by mutating the notifier in a loop: the accessors
    // are still the real ones, so this certifies colours the app actually
    // paints.
    for (final m in materialsUnderTest) {
      for (final isDark in [false, true]) {
        final mode = '${m.key} ${isDark ? 'dark' : 'light'}';

        test('primary text — $mode', () {
          expectInk(
            'text',
            NeuTheme.text(isDark, material: m),
            isDark,
            material: m,
          );
        });

        test('subtext — $mode', () {
          // The regression that mattered most: this is subtextStyle's default
          // ink at 11px, the most-used size in the app, and it measured 3.40:1.
          expectInk(
            'subtext',
            NeuTheme.subtext(isDark, material: m),
            isDark,
            material: m,
          );
        });

        test('semantic status inks — $mode', () {
          expectInk(
            'liveText',
            NeuTheme.liveText(isDark, material: m),
            isDark,
            material: m,
          );
          expectInk(
            'dangerText',
            NeuTheme.dangerText(isDark, material: m),
            isDark,
            material: m,
          );
          expectInk(
            'warningText',
            NeuTheme.warningText(isDark, material: m),
            isDark,
            material: m,
          );
        });

        test('non-text inks clear the 3:1 bar — $mode', () {
          // Disabled labels and the favourite star are never body copy, so they
          // are held to the graphics bar rather than the text bar.
          expectInk(
            'disabledText',
            NeuTheme.disabledText(isDark, material: m),
            isDark,
            min: kNonTextAA,
            material: m,
          );
          expectInk(
            'favoriteText',
            NeuTheme.favoriteText(isDark, material: m),
            isDark,
            min: kNonTextAA,
            material: m,
          );
        });
      }
    }
  });

  group('the gradient floor is the real ground', () {
    test(
      'a fill floor is darker than its base, and by the declared amount',
      () {
        // If this ever inverts, groundsFor is checking the wrong extreme and
        // every assertion above becomes decorative.
        for (final isDark in [false, true]) {
          for (final base in [
            NeuTheme.canvas(isDark),
            NeuTheme.surface(isDark),
            NeuTheme.wellSurface(isDark),
          ]) {
            final floor = NeuTheme.fillFloor(base);
            expect(
              floor.computeLuminance(),
              lessThan(base.computeLuminance()),
              reason:
                  'fillFloor must darken; the worst case for dark ink is '
                  'the darkest point of the fill',
            );
          }
        }
      },
    );

    test('light inks survive the floor, which is where they used to fail', () {
      // Named individually because these five are the ones that regressed:
      // each cleared its bar against the flat token and missed it against the
      // floor by between 0.05 and 0.25.
      final worst = NeuTheme.fillFloor(NeuTheme.wellSurface(false));
      for (final ink in <(String, Color, double)>[
        ('liveText', NeuTheme.liveText(false), kTextAA),
        ('dangerText', NeuTheme.dangerText(false), kTextAA),
        ('warningText', NeuTheme.warningText(false), kTextAA),
        ('disabledText', NeuTheme.disabledText(false), kNonTextAA),
        ('favoriteText', NeuTheme.favoriteText(false), kNonTextAA),
      ]) {
        final ratio = NeuTheme.contrastRatio(ink.$2, worst);
        expect(
          ratio,
          greaterThanOrEqualTo(ink.$3),
          reason:
              '${ink.$1} measured ${ratio.toStringAsFixed(2)}:1 against '
              'the well fill floor, needs ${ink.$3}:1',
        );
      }
    });
  });

  group('surfaces are distinguishable from the page', () {
    test('the canvas is not the surface', () {
      // They were the same hex in light mode (1.000:1), so a raised card was
      // visible only by its shadow.
      for (final isDark in [false, true]) {
        final ratio = NeuTheme.contrastRatio(
          NeuTheme.canvas(isDark),
          NeuTheme.surface(isDark),
        );
        expect(
          ratio,
          greaterThan(1.02),
          reason:
              '${isDark ? 'dark' : 'light'} canvas/surface separation is '
              'only ${ratio.toStringAsFixed(3)}:1',
        );
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
          const Color(0xFF000000),
          const Color(0xFFFFFFFF),
        ),
        closeTo(21.0, 0.01),
      );
      expect(
        NeuTheme.contrastRatio(
          const Color(0xFFFFFFFF),
          const Color(0xFFFFFFFF),
        ),
        closeTo(1.0, 0.001),
      );
    });

    test('is symmetric', () {
      const a = Color(0xFF4F5F75);
      const b = Color(0xFFE1E4EA);
      expect(
        NeuTheme.contrastRatio(a, b),
        closeTo(NeuTheme.contrastRatio(b, a), 1e-9),
      );
    });
  });
  group('accentInk', () {
    test('every preset becomes readable on every ground', () {
      // Raw, several of these are unusable as a foreground: Cyan measures
      // 1.04:1 against the light well, and even the default Soft Pink 2.12:1.
      //
      // Run per material, not once. Without the parameter this derived the ink
      // against the ACTIVE material and then measured it against that same
      // material's grounds, so every other material reported green whatever it
      // declared - the matrix was decorative for four fifths of its axis.
      for (final m in materialsUnderTest) {
        for (final isDark in [false, true]) {
          kAccentPresets.forEach((name, accent) {
            expectInk(
              'accentInk($name)',
              NeuTheme.accentInk(accent, isDark, material: m),
              isDark,
              material: m,
            );
          });
        }
      }
    });

    test('an accent that is already readable is returned untouched', () {
      // Derivation must not restyle what does not need it: an accent that
      // already clears the bar has to come back byte-identical, or the user's
      // choice is being altered for no gain.
      //
      // Stated as the invariant rather than as two example colours. It USED to
      // name Cyan and Gold, on the note that five of the eleven presets passed
      // as-is in dark mode - and Gold stopped passing the moment the gloss
      // layer was folded into `worstGround`, because the ground it is measured
      // against genuinely got about twelve levels lighter. The old form would
      // have to be re-picked every time a palette moves; this one cannot go
      // stale, and it covers all eleven presets on every material.
      for (final m in materialsUnderTest) {
        for (final isDark in [false, true]) {
          final ground = NeuTheme.palette(isDark, material: m).inkGround;
          kAccentPresets.forEach((name, accent) {
            if (NeuTheme.contrastRatio(accent, ground) < kTextAA) return;
            expect(
              NeuTheme.accentInk(accent, isDark, material: m),
              accent,
              reason: '$name already cleared the bar on ${m.key} '
                  '${isDark ? 'dark' : 'light'} and was restyled anyway',
            );
          });
        }
      }
    });

    test('the untouched case is not vacuous', () {
      // A guard for the guard above: if no preset ever cleared the bar, that
      // loop would pass by never running a single assertion. Dark grounds have
      // the headroom, so at least one must.
      var untouched = 0;
      for (final m in materialsUnderTest) {
        final ground = NeuTheme.palette(true, material: m).inkGround;
        for (final accent in kAccentPresets.values) {
          if (NeuTheme.contrastRatio(accent, ground) >= kTextAA) untouched++;
        }
      }
      expect(untouched, greaterThan(0),
          reason: 'no preset is readable as-is on any dark material, so the '
              'untouched-accent test is asserting nothing at all');
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
        Color(0xFFFFFFFF),
        Color(0xFF000000),
        Color(0xFF7F7F7F),
        Color(0xFFEBECF0),
        Color(0xFFD8E0EB),
        Color(0xFF222632),
      ];
      for (final isDark in [false, true]) {
        for (final accent in hostile) {
          final ink = NeuTheme.accentInk(accent, isDark);
          final ground = isDark
              ? NeuTheme.surface(true)
              : NeuTheme.wellSurface(false);
          expect(
            NeuTheme.contrastRatio(ink, ground),
            greaterThanOrEqualTo(kTextAA),
            reason:
                '$accent (${isDark ? 'dark' : 'light'}) produced an '
                'unreadable ink',
          );
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
      expect(
        (derived - original).abs(),
        lessThan(12.0),
        reason: 'hue drifted from $original to $derived',
      );
    });
  });
  group('screen inks clear AA on the screen', () {
    // The hole this closes was live and total. A log pane paints on the
    // material's `screen`, which stays dark in a lit room because a lit
    // readout does - so in a LIGHT material both `text` and `screen` are dark,
    // and the plain log lines measured 1.08:1. Nothing saw it: `groundsFor`
    // deliberately excludes the screen, so the ordinary matrix could not, and
    // no other assertion in the suite looked at this ground at all.
    //
    // The colours below are the sources the log pane walks FROM, not the inks
    // themselves. Asserting a walk's output against the ground it walked
    // toward can only ever pass; what is asserted here is that the walk
    // actually clears the bar for every source the app feeds it.
    const logSources = <String, Color>{
      'error': NeuTheme.danger,
      'download': NeuTheme.live,
      'system dark': Color(0xFF38BDF8),
      'system light': Color(0xFF0369A1),
      'cliInfo dark': Color(0xFF10B981),
      'cliInfo light': Color(0xFF047857),
    };

    for (final m in materialsUnderTest) {
      for (final isDark in [false, true]) {
        final mode = '${m.key} ${isDark ? 'dark' : 'light'}';

        test('screenText and screenSubtext - $mode', () {
          expectInkOnScreen('screenText',
              NeuTheme.screenText(isDark, material: m), isDark, material: m);
          expectInkOnScreen('screenSubtext',
              NeuTheme.screenSubtext(isDark, material: m), isDark,
              material: m);
        });

        test('every log-line source survives the walk - $mode', () {
          logSources.forEach((name, source) {
            expectInkOnScreen(
              'inkOnScreen($name)',
              NeuTheme.inkOnScreen(source, isDark, material: m),
              isDark,
              material: m,
            );
          });
        });

        test('every accent preset survives the walk - $mode', () {
          kAccentPresets.forEach((name, accent) {
            expectInkOnScreen(
              'accentInkOnScreen($name)',
              NeuTheme.accentInkOnScreen(accent, isDark, material: m),
              isDark,
              material: m,
            );
          });
        });
      }
    }

    test('the screen ink is not interchangeable with the surface ink', () {
      // The assertion that would have caught the 1.08:1 bug before it shipped,
      // stated as the rule rather than as a number: on any material whose
      // screen does not track the theme, `text` on it is a failure. If some
      // future material makes the two safely identical this goes green by
      // being true, not by being weakened - the reason string says how to tell
      // the difference.
      for (final m in materialsUnderTest) {
        final p = NeuTheme.palette(false, material: m);
        if (!p.screenIsEmissive) continue;
        expect(
          NeuTheme.contrastRatio(NeuTheme.text(false, material: m), p.screen),
          lessThan(kTextAA),
          reason: '${m.key} light: `text` happens to be readable on the '
              'screen, so this guard proves nothing - check whether the '
              'screen is still emissive',
        );
      }
    });
  });

}
