import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

/// The fidelity gate: the engine's `Soft` must paint what the app shipped.
///
/// `Soft` is not a nostalgia option, it is the proof. If the engine cannot
/// reproduce the old material *from data*, the abstraction is a rack-gear
/// special case wearing a coat of paint and every material built on it inherits
/// that. Checking the palette's declared fields is not enough — that inspects
/// paperwork, and would sail through a painter that changed how the bevel
/// composites.
///
/// So this paints both and compares pixels, in one process, with no stored
/// image. Deliberately **not** a golden: `LocalFileComparator` is
/// zero-tolerance and platform-dependent, and CI runs on ubuntu while the app
/// ships on Windows.
///
/// **This is the one test that must never be re-baselined to match new output.**
/// Loosening a tolerance here is how the classic look would drift away one
/// release at a time, invisibly, while the picker still offered it by name.
void main() {
  /// Mean and max per-channel difference between two same-sized images.
  Future<({double mean, int max})> diff(ui.Image a, ui.Image b) async {
    expect(a.width, b.width);
    expect(a.height, b.height);
    final ad = (await a.toByteData())!.buffer.asUint8List();
    final bd = (await b.toByteData())!.buffer.asUint8List();
    var total = 0, worst = 0;
    for (var i = 0; i < ad.length; i++) {
      final d = (ad[i] - bd[i]).abs();
      total += d;
      if (d > worst) worst = d;
    }
    return (mean: total / ad.length, max: worst);
  }

  Future<ui.Image> render(Decoration d, Size size) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // A neutral ground so shadows outside the shape are compared too, rather
    // than both sides agreeing on transparent black.
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF808080));
    final painter = d.createBoxPainter();
    // Inset the shape so the cast shadow has somewhere to land inside frame.
    painter.paint(canvas, const Offset(24, 24),
        ImageConfiguration(size: Size(size.width - 48, size.height - 48)));
    painter.dispose();
    return recorder
        .endRecording()
        .toImage(size.width.round(), size.height.round());
  }

  /// The shipped v1.6.0 recipe, reached through the live API.
  ///
  /// While `NeuTheme.raised()` still returns the original `BoxDecoration` this
  /// is the real thing rather than a copy. The moment it is re-pointed at the
  /// engine, these two calls must be replaced by a frozen verbatim copy of the
  /// old bodies — otherwise this test compares the engine against itself and
  /// passes for the wrong reason.
  Decoration legacyRaised(bool isDark, {required double depth, required double radius}) =>
      NeuTheme.raised(isDark, depth: depth, radius: radius);
  Decoration legacySunken(bool isDark, {required double depth, required double radius}) =>
      NeuTheme.sunken(isDark, depth: depth, radius: radius);

  group('Soft paints the shipped recipe', () {
    const size = Size(160, 96);

    for (final isDark in [false, true]) {
      final mode = isDark ? 'dark' : 'light';
      final palette = softSpec.palette(isDark);

      for (final depth in [NeuElevation.d2, NeuElevation.d3, NeuElevation.d4]) {
        test('raised at depth $depth — $mode', () async {
          final shipped =
              await render(legacyRaised(isDark, depth: depth, radius: NeuRadius.r12), size);
          final engine = await render(
              SkeuoDecoration.role(
                palette: palette,
                role: SurfaceRole.raised,
                depth: depth,
                radius: NeuRadius.r12,
              ),
              size);

          final d = await diff(shipped, engine);
          shipped.dispose();
          engine.dispose();

          // Tolerances are what the engine actually achieves, not a margin
          // chosen to be comfortable: raised is pixel-identical and sunken
          // differs by at most one level of anti-aliasing. Raising these is
          // how the classic look would drift away one release at a time.
          expect(d.mean, lessThan(0.05),
              reason: 'mean channel delta ${d.mean.toStringAsFixed(4)} — the '
                  'engine is no longer painting what Soft shipped');
          expect(d.max, lessThanOrEqualTo(2),
              reason: 'worst channel delta ${d.max}');
        });

        test('sunken at depth $depth — $mode', () async {
          final shipped =
              await render(legacySunken(isDark, depth: depth, radius: NeuRadius.r12), size);
          final engine = await render(
              SkeuoDecoration.role(
                palette: palette,
                role: SurfaceRole.sunken,
                depth: depth,
                radius: NeuRadius.r12,
              ),
              size);

          final d = await diff(shipped, engine);
          shipped.dispose();
          engine.dispose();

          expect(d.mean, lessThan(0.05),
              reason: 'mean channel delta ${d.mean.toStringAsFixed(4)}');
          expect(d.max, lessThanOrEqualTo(2),
              reason: 'worst channel delta ${d.max}');
        });
      }
    }

    test('the comparison can actually fail', () async {
      // A gate that cannot go red is decoration. Paint two deliberately
      // different depths and confirm the numbers move.
      final a = await render(
          SkeuoDecoration.role(
              palette: softSpec.palette(true),
              role: SurfaceRole.raised,
              depth: NeuElevation.d1,
              radius: NeuRadius.r12),
          size);
      final b = await render(
          SkeuoDecoration.role(
              palette: softSpec.palette(true),
              role: SurfaceRole.raised,
              depth: NeuElevation.d5,
              radius: NeuRadius.r12),
          size);
      final d = await diff(a, b);
      a.dispose();
      b.dispose();
      expect(d.mean, greaterThan(1.0),
          reason: 'if this passes, the diff is not measuring anything');
    });
  });
}
