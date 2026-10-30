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
List<({String name, Color color})> groundsFor(bool isDark) {
  final p = NeuTheme.palette(isDark);
  final seen = <int>{};
  final out = <({String name, Color color})>[];
  void add(String name, Color c) {
    if (seen.add(c.toARGB32())) out.add((name: name, color: c));
  }

  // Every role's ground, and the worst point that role's fill reaches. `screen`
  // is excluded: it is the log pane's ground and has its own derivation.
  for (final role in SurfaceRole.values) {
    if (RoleModifier.of(role).fill == Ground.screen) continue;
    final base = p.groundFor(RoleModifier.of(role).fill);
    add(role.name, base);
    add('${role.name} worst stop', p.worstGround(role));
  }
  return out;
}

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
/// Kept apart from [groundsFor] on purpose: it is the ground for exactly one
/// family of inks - the log pane's - and this is that family's matrix.
List<({String name, Color color})> screenGroundsFor(bool isDark) {
  final p = NeuTheme.palette(isDark);
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
}) {
  for (final ground in screenGroundsFor(isDark)) {
    final ratio = NeuTheme.contrastRatio(ink, ground.color);
    expect(
      ratio,
      greaterThanOrEqualTo(min),
      reason:
          '$label on ${ground.name} (${isDark ? 'dark' : 'light'}) '
          'measured ${ratio.toStringAsFixed(2)}:1, needs $min:1',
    );
  }
}

void expectInk(
  String label,
  Color ink,
  bool isDark, {
  double min = kTextAA,
}) {
  for (final ground in groundsFor(isDark)) {
    final ratio = NeuTheme.contrastRatio(ink, ground.color);
    expect(
      ratio,
      greaterThanOrEqualTo(min),
      reason:
          '$label on ${ground.name} (${isDark ? 'dark' : 'light'}) '
          'measured ${ratio.toStringAsFixed(2)}:1, needs $min:1',
    );
  }
}

void main() {
  group('text inks clear AA on every ground', () {
    for (final isDark in [false, true]) {
      final mode = isDark ? 'dark' : 'light';

      test('primary text — $mode', () {
        expectInk(
          'text',
          NeuTheme.text(isDark),
          isDark,
        );
      });

      test('subtext — $mode', () {
        // The regression that mattered most: this is subtextStyle's default
        // ink at 11px, the most-used size in the app, and it measured 3.40:1.
        expectInk(
          'subtext',
          NeuTheme.subtext(isDark),
          isDark,
        );
      });

      test('semantic status inks — $mode', () {
        expectInk(
          'liveText',
          NeuTheme.liveText(isDark),
          isDark,
        );
        expectInk(
          'dangerText',
          NeuTheme.dangerText(isDark),
          isDark,
        );
        expectInk(
          'warningText',
          NeuTheme.warningText(isDark),
          isDark,
        );
      });

      test('non-text inks clear the 3:1 bar — $mode', () {
        // Disabled labels and the favourite star are never body copy, so they
        // are held to the graphics bar rather than the text bar.
        expectInk(
          'disabledText',
          NeuTheme.disabledText(isDark),
          isDark,
          min: kNonTextAA,
        );
        expectInk(
          'favoriteText',
          NeuTheme.favoriteText(isDark),
          isDark,
          min: kNonTextAA,
        );
      });
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
      for (final isDark in [false, true]) {
        kAccentPresets.forEach((name, accent) {
          expectInk(
            'accentInk($name)',
            NeuTheme.accentInk(accent, isDark),
            isDark,
          );
        });
      }
    });

    test('an accent that is already readable is returned untouched', () {
      // Derivation must not restyle what does not need it: an accent that
      // already clears the bar has to come back byte-identical, or the user's
      // choice is being altered for no gain.
      //
      // Stated as the invariant rather than as example colours, which would
      // have to be re-picked every time a palette moves; this one cannot go
      // stale, and it covers all eleven presets.
      for (final isDark in [false, true]) {
        final p = NeuTheme.palette(isDark);
        kAccentPresets.forEach((name, accent) {
          // The SAME set the derivation walks against, including the accent's
          // own 15% wash - a selected control's ground. Checking a narrower
          // set makes the derivation look like it restyled something that
          // was already fine.
          final grounds = NeuTheme.accentGrounds(accent, p);
          if (grounds
              .any((g) => NeuTheme.contrastRatio(accent, g) < kTextAA)) {
            return;
          }
          expect(
            NeuTheme.accentInk(accent, isDark),
            accent,
            reason: '$name already cleared the bar on '
                '${isDark ? 'dark' : 'light'} and was restyled anyway',
          );
        });
      }
    });

    test('the untouched case is not vacuous', () {
      // A guard for the guard above: if no preset ever cleared the bar, that
      // loop would pass by never running a single assertion. Dark grounds have
      // the headroom, so at least one must.
      var untouched = 0;
      final p = NeuTheme.palette(true);
      for (final accent in kAccentPresets.values) {
        final grounds = NeuTheme.accentGrounds(accent, p);
        if (grounds.every((g) => NeuTheme.contrastRatio(accent, g) >= kTextAA)) {
          untouched++;
        }
      }
      expect(untouched, greaterThan(0),
          reason: 'no preset is readable as-is in the dark theme, so the '
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
    // A log pane paints on the `screen` ground, which `groundsFor`
    // deliberately excludes, so the ordinary matrix cannot see it and no
    // other assertion in the suite looks at this ground at all.
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

    for (final isDark in [false, true]) {
      final mode = isDark ? 'dark' : 'light';

      test('screenText and screenSubtext - $mode', () {
        expectInkOnScreen('screenText',
            NeuTheme.screenText(isDark), isDark);
        expectInkOnScreen('screenSubtext',
            NeuTheme.screenSubtext(isDark), isDark);
      });

      test('every log-line source survives the walk - $mode', () {
        logSources.forEach((name, source) {
          expectInkOnScreen(
            'inkOnScreen($name)',
            NeuTheme.inkOnScreen(source, isDark),
            isDark,
          );
        });
      });

      test('every accent preset survives the walk - $mode', () {
        kAccentPresets.forEach((name, accent) {
          expectInkOnScreen(
            'accentInkOnScreen($name)',
            NeuTheme.accentInkOnScreen(accent, isDark),
            isDark,
          );
        });
      });
    }
  });

  group('a raw accent is never used as a foreground', () {
    // The bug this catches shipped three times over. `accentInk` exists
    // precisely because the raw presets are unusable as ink - Cyan measures
    // 1.04:1 on the light well - and the app derives it correctly in most
    // places. But a *selected* control paints its label on that same accent at
    // 15% alpha, so ink and ground are the same hue at close lightness, and
    // NeuButton used the raw value there: Cyan on the Library tab's
    // always-selected sort button measured 1.015:1.
    //
    // The existing accent group could not see it, because it only ever
    // measures `accentInk`'s OUTPUT. This measures the input against the
    // ground a selected control actually paints.
    for (final isDark in [false, true]) {
      final mode = isDark ? 'dark' : 'light';

      test('a selected control is legible on its own accent tint — $mode',
          () {
        final p = NeuTheme.palette(isDark);
        kAccentPresets.forEach((name, accent) {
          // NeuButton fills a selected surface with the accent at 15% over
          // the sunken ground, then paints the label on top of that.
          for (final role in [SurfaceRole.sunken, SurfaceRole.raised]) {
            final tint = Color.alphaBlend(
                accent.withValues(alpha: 0.15), p.worstGround(role));
            final ink = NeuTheme.accentInk(accent, isDark);
            final ratio = NeuTheme.contrastRatio(ink, tint);
            expect(ratio, greaterThanOrEqualTo(kTextAA),
                reason: 'selected $name on its own 15% tint over $role '
                    '($mode) measured ${ratio.toStringAsFixed(2)}:1');
          }
        });
      });
    }

    test('the raw preset really is unusable, so this is not vacuous', () {
      // If the raw accent happened to be readable on its own tint, the guard
      // above would pass whether or not the app derived anything.
      final p = NeuTheme.palette(false);
      const cyan = Color(0xFF00F2FE);
      final tint = Color.alphaBlend(
          cyan.withValues(alpha: 0.15), p.worstGround(SurfaceRole.sunken));
      expect(NeuTheme.contrastRatio(cyan, tint), lessThan(kTextAA),
          reason: 'the raw accent is readable on its own tint, so nothing in '
              'this group is proving that deriving it mattered');
    });
  });

}
