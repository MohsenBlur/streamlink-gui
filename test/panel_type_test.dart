import 'dart:ui' show FontFeature, FontVariation;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_type.dart';

/// The panel face and the readout treatment, asserted where they CAN be.
///
/// What this file deliberately does not check is whether Bahnschrift actually
/// renders. It cannot: `flutter test` runs against a bundled test font with no
/// system fonts at all, and CI runs on ubuntu where the face does not exist —
/// so an assertion here would measure the fallback against itself and pass
/// while the binding was broken. That measurement lives in `TypeProbe`, which
/// runs in a real build behind `--dart-define=SKEUO_TYPE_PROBE=true`, and its
/// result at the time of writing was 22.1% narrower than Segoe UI at the same
/// nominal weight, with the wght axis separating 400 from 375 at *identical*
/// advance — which is the case width alone cannot detect.
///
/// What is checkable here is the shape of the request: that the style carries
/// the axes at all, that a material without a face is left alone, and that no
/// adoption changed a size.
void main() {
  group('plated asks for the face by axis, not by family name', () {
    test('a material with a label face gets both axes', () {
      for (final spec in MaterialSpec.available) {
        final type = spec.type;
        for (final isDark in [false, true]) {
          final styled = NeuType.plated(
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              isDark,
              material: spec.id);

          if (type.labelFamily == null) {
            // Untouched, not "styled with the default face". A material that
            // declares no face must leave the step exactly as the scale
            // produced it, which is how Soft opts out with no call site
            // knowing Soft exists.
            expect(styled.fontFamily, isNull, reason: '${spec.id.key}');
            expect(styled.fontVariations, isNull, reason: '${spec.id.key}');
            continue;
          }

          expect(styled.fontFamily, type.labelFamily);
          expect(styled.fontFamilyFallback, contains('Segoe UI'),
              reason: 'a face with no fallback renders as whatever the '
                  'platform picks, which on a machine without it is not '
                  'something anyone chose');

          final axes = styled.fontVariations!;
          expect(
            axes,
            containsAll(<FontVariation>[
              FontVariation('wght', type.weightFor(isDark)),
              FontVariation('wdth', type.labelWidth),
            ]),
            reason: '${spec.id.key} ${isDark ? 'dark' : 'light'}: the family '
                'name alone resolves to Segoe UI Semibold — only the axes '
                'produce the condensed face',
          );
        }
      }
    });

    test('the weight is stated twice and is allowed to disagree', () {
      // Not a bug and not redundancy. `fontVariations` is what Bahnschrift
      // reads; `fontWeight` is what Segoe UI gets when the family does not
      // resolve, and the two faces need different numbers — DIN at 400 is
      // sturdy where Segoe at 400 and 10px goes sub-pixel and greys out.
      // Forcing them to agree would make one of the two wrong.
      for (final spec in MaterialSpec.available) {
        if (spec.type.labelFamily == null) continue;
        final plate = NeuType.plate(false, material: spec.id);
        expect(plate.fontWeight, FontWeight.w700,
            reason: 'the fallback weight must stay at micro\'s, which is what '
                'keeps 10px caps legible in Segoe UI');
        expect(plate.fontVariations, isNotNull);
      }
    });

    test('a material may change the letterfit and never the size', () {
      // The binding rule at type scale. `plate` is `micro` re-skinned: same
      // size, same weight, the material's face and tracking. If a material
      // could move the size, adopting it would move layout — which is the one
      // thing this whole effort is committed to not doing.
      final micro = NeuType.micro(false);
      for (final spec in MaterialSpec.available) {
        final plate = NeuType.plate(false, material: spec.id);
        expect(plate.fontSize, micro.fontSize, reason: spec.id.key);
        expect(plate.fontSize, 10,
            reason: '10 is the floor because below it Segoe UI\'s stems go '
                'sub-pixel — a fact about the fallback, so no material may '
                'move it');
        expect(plate.fontWeight, micro.fontWeight, reason: spec.id.key);
        expect(plate.letterSpacing, spec.type.labelTracking,
            reason: '${spec.id.key}: letterfit is a property of the face, so '
                'the material owns it');
      }
    });

    test('the fallback can be forced, so it can be looked at', () {
      // A compile-time constant, so it costs nothing when off. It exists
      // because nothing detects the fall-through at runtime: a machine without
      // the face renders Segoe UI and says nothing, and this is the only way
      // to see that layout before shipping it.
      expect(NeuType.suppressMaterialFace, isFalse,
          reason: 'the escape hatch must be off by default');
    });
  });

  group('readout is a treatment, not a step', () {
    test('it changes the figures and nothing else', () {
      // Every adoption has to be size-preserving or the migration is a
      // redesign. Counts, durations and sizes keep the step they already use.
      for (final base in [
        NeuType.caption(false),
        NeuType.body(true),
        NeuType.label(false),
      ]) {
        final r = NeuType.readout(base);
        expect(r.fontSize, base.fontSize);
        expect(r.fontWeight, base.fontWeight);
        expect(r.fontFamily, base.fontFamily);
        expect(r.letterSpacing, base.letterSpacing);
        expect(r.color, base.color);
        expect(r.fontFeatures, contains(const FontFeature.tabularFigures()));
      }
    });

    test('mono adopts nothing', () {
      // `tnum` on a fixed-pitch face is a no-op, and applying it anyway would
      // suggest the log pane needed a fix it does not.
      expect(NeuType.mono(false).fontFeatures, isNull);
    });
  });
}
