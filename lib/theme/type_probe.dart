import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'material/app_material.dart';
import 'neu_type.dart';

/// The typography gate, and the reason it cannot be a unit test.
///
/// `flutter test` runs against a bundled test font with no system fonts at
/// all, and CI runs on ubuntu, where Bahnschrift does not exist. A test that
/// asserted the axis binding works would therefore assert it *in the one
/// environment where it cannot*, and pass by measuring the fallback against
/// itself. So this runs in a real `flutter run`, behind a dart-define, and
/// writes its measurements where a human can read them:
///
/// ```
/// flutter run -d windows --dart-define=SKEUO_TYPE_PROBE=true
/// ```
///
/// Two measurements, not one, and both are required. Width alone is
/// insufficient: `'Bahnschrift'` at wght 300 through 700 all lay out at
/// identical advance and differ only in ink coverage, so an advance check
/// alone cannot tell a weight axis that works from one that is ignored. Ink
/// alone is insufficient the other way — a bolder fallback also inks more.
///
/// The pass condition is that the plated style is **materially narrower** than
/// the same style in plain Segoe UI at the same nominal weight, AND that its
/// ink count differs. Both together mean the axes bound.
class TypeProbe {
  TypeProbe._();

  static const bool enabled =
      bool.fromEnvironment('SKEUO_TYPE_PROBE', defaultValue: false);

  static Future<void> run() async {
    const sample = 'TWITCH STREAMLINK GUI';
    final out = StringBuffer()
      ..writeln('=== typography gate ===')
      ..writeln('sample: "$sample" at 40px');

    Future<({double advance, int ink})> measure(TextStyle style) async {
      final painter = TextPainter(
        // Intentional: 40px is a measuring rod, not a UI size. The axes have
        // to be read at a size where a 22% width difference is unambiguous;
        // at the 10px this actually ships, rounding to whole device pixels
        // would swallow the signal being measured.
        text: TextSpan(text: sample, style: style.copyWith(fontSize: 40)),
        textDirection: TextDirection.ltr,
      )..layout();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final w = painter.width.ceil() + 8;
      final h = painter.height.ceil() + 8;
      canvas.drawRect(
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint()..color = const Color(0xFF000000));
      painter.paint(canvas, const Offset(4, 4));
      final image = await recorder.endRecording().toImage(w, h);
      final bytes = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      var ink = 0;
      for (var i = 0; i < bytes.length; i += 4) {
        if (bytes[i] > 40) ink++;
      }
      final advance = painter.width;
      painter.dispose();
      return (advance: advance, ink: ink);
    }

    for (final spec in MaterialSpec.available) {
      final family = spec.type.labelFamily;
      if (family == null) {
        out.writeln('${spec.id.key}: no label family, uses the default face');
        continue;
      }
      for (final isDark in [false, true]) {
        final mode = isDark ? 'dark' : 'light';
        final plated = NeuType.plated(
            const TextStyle(fontWeight: FontWeight.w700), isDark,
            material: spec.id);
        final control = const TextStyle(
          fontFamily: 'Segoe UI',
          fontWeight: FontWeight.w700,
        );

        final a = await measure(plated);
        final b = await measure(control);
        final narrower = (1 - a.advance / b.advance) * 100;
        final inkDiffers = a.ink != b.ink;

        out
          ..writeln('${spec.id.key} $mode ($family '
              'wght ${spec.type.weightFor(isDark)} '
              'wdth ${spec.type.labelWidth}):')
          ..writeln('  plated : advance ${a.advance.toStringAsFixed(3)}  '
              'ink ${a.ink}')
          ..writeln('  Segoe  : advance ${b.advance.toStringAsFixed(3)}  '
              'ink ${b.ink}')
          ..writeln('  -> ${narrower.toStringAsFixed(1)}% narrower, '
              'ink ${inkDiffers ? 'differs' : 'IDENTICAL'}')
          ..writeln('  -> ${narrower > 15 && inkDiffers ? 'BOUND' : 'FELL '
              'THROUGH TO THE FALLBACK'}');
      }
    }

    final path = 'type_probe.txt';
    File(path).writeAsStringSync(out.toString());
    debugPrint(out.toString());
  }
}
