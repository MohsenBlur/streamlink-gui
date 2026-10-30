import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_type.dart';

/// The panel legend step and the readout treatment: neither may move a size.
void main() {
  test('plate is the micro step: legends never change size or weight', () {
    // The binding rule at type scale. 10 is the floor because below it Segoe
    // UI's stems go sub-pixel, and the tracking is the 0.6 measured on Segoe.
    for (final isDark in [false, true]) {
      final micro = NeuType.micro(isDark);
      final plate = NeuType.plate(isDark);
      expect(plate.fontSize, 10);
      expect(plate.fontSize, micro.fontSize);
      expect(plate.fontWeight, micro.fontWeight);
      expect(plate.letterSpacing, micro.letterSpacing);
      expect(plate.fontFamily, isNull,
          reason: 'the app face, like every other step');
      expect(plate.color, micro.color);
    }
    const accent = Color(0xFFFF6584);
    expect(NeuType.plate(false, color: accent).color, accent);
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
