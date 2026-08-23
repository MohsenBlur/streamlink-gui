import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lit-surface shader, asserted on properties a gradient cannot have.
///
/// The point of moving to a fragment shader is not that it looks nicer in one
/// screenshot - it is that the surface behaves like a surface. Each test here
/// names one behaviour that separates a lit object from a picture of one, and
/// every one of them fails on any stack of gradients:
///
/// * the highlight MOVES when the light moves,
/// * the edge is bright on the lit side and dark on the far side, not a ring,
/// * the reflection changes with the surface normal,
/// * a recessed surface is lit on the opposite edge from a proud one.
///
/// They also happen to be cheap, exact, and independent of taste, which the
/// previous engine's "does it look right" screenshot pass was not.
void main() {
  late ui.FragmentProgram program;

  setUpAll(() async {
    program = await ui.FragmentProgram.fromAsset('shaders/surface.frag');
  });

  /// Uniform layout, in declaration order. Kept in one place because SkSL
  /// uniforms are positional: inserting one in the middle of the shader
  /// silently shifts every value after it, and the result still renders.
  ui.FragmentShader shade({
    required double w,
    required double h,
    double radius = 14,
    double bevel = 3.5,
    List<double> base = const [0.165, 0.180, 0.208],
    List<double> spec = const [1.0, 0.98, 0.94],
    double rough = 0.35,
    double lightAz = 1.5707963,
    double lightEl = 0.62,
    double ambient = 0.42,
    List<double> envTop = const [0.52, 0.56, 0.64],
    List<double> envBot = const [0.04, 0.045, 0.06],
    double envAmount = 0.55,
    double grain = 0.0,
    double grainScale = 130,
    double inset = 0,
    double seed = 3,
    double px = 1,
    double bow = 0.10,
    double sheen = 0.22,
  }) {
    final s = program.fragmentShader();
    var i = 0;
    void f(double v) => s.setFloat(i++, v);
    f(w);
    f(h);
    f(radius);
    f(bevel);
    base.forEach(f);
    spec.forEach(f);
    f(rough);
    f(lightAz);
    f(lightEl);
    f(ambient);
    envTop.forEach(f);
    envBot.forEach(f);
    f(envAmount);
    f(grain);
    f(grainScale);
    f(inset);
    f(seed);
    f(px);
    f(bow);
    f(sheen);
    return s;
  }

  Future<Uint8List> render(ui.FragmentShader s, double w, double h) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..shader = s);
    final img = await rec.endRecording().toImage(w.round(), h.round());
    final bytes = (await img.toByteData())!.buffer.asUint8List();
    img.dispose();
    return bytes;
  }

  double lumAt(Uint8List b, int w, int x, int y) {
    final i = (y * w + x) * 4;
    return (b[i] * 0.2126 + b[i + 1] * 0.7152 + b[i + 2] * 0.0722);
  }

  double alphaAt(Uint8List b, int w, int x, int y) => b[(y * w + x) * 4 + 3].toDouble();

  const w = 200.0, h = 120.0;
  const iw = 200, ih = 120;

  test('the highlight moves when the light moves', () async {
    // The property a gradient cannot have. A LinearGradient's bright end is
    // wherever it was authored; a lit surface's is wherever the light is.
    final above = await render(shade(w: w, h: h, lightAz: 1.5707963), w, h);
    final left = await render(shade(w: w, h: h, lightAz: 3.14159), w, h);

    // Sampled ONE pixel in from the outline, which is where the chamfer is
    // steepest and therefore brightest. Three pixels in, with a 3.5px chamfer,
    // is already most of the way back to the flat face - the difference is
    // still in the right direction there but only by a level or two, which
    // would make this test look marginal when the effect is not.
    final topAbove = lumAt(above, iw, iw ~/ 2, 1);
    final leftAbove = lumAt(above, iw, 1, ih ~/ 2);
    final topLeft = lumAt(left, iw, iw ~/ 2, 1);
    final leftLeft = lumAt(left, iw, 1, ih ~/ 2);

    expect(topAbove, greaterThan(leftAbove + 8),
        reason: 'lit from above, the TOP chamfer must be the bright one '
            '(top ${topAbove.toStringAsFixed(1)} vs '
            'left ${leftAbove.toStringAsFixed(1)})');
    expect(leftLeft, greaterThan(topLeft + 8),
        reason: 'lit from the left, the LEFT chamfer must be the bright one '
            '(left ${leftLeft.toStringAsFixed(1)} vs '
            'top ${topLeft.toStringAsFixed(1)})');
  });

  test('the edge is lit on one side and shadowed on the other', () async {
    // A one-pixel ring is the same value all the way round. A chamfer is
    // geometry: it catches the light where it faces it and loses it where it
    // turns away. This is the difference between an outline and an edge.
    final b = await render(shade(w: w, h: h), w, h);
    final top = lumAt(b, iw, iw ~/ 2, 1);
    final bottom = lumAt(b, iw, iw ~/ 2, ih - 2);
    final middle = lumAt(b, iw, iw ~/ 2, ih ~/ 2);

    // Measured at the values that ship: top 84.9, face 76.9, far chamfer 15.9.
    // The near edge is worth 8 levels over the face and the far edge is 61
    // levels UNDER it - the asymmetry is the whole point, and it is why the
    // two halves of this test have such different thresholds.
    expect(top, greaterThan(middle + 5),
        reason: 'the lit chamfer must be brighter than the face '
            '(top ${top.toStringAsFixed(1)} middle ${middle.toStringAsFixed(1)} '
            'bottom ${bottom.toStringAsFixed(1)})');
    expect(bottom, lessThan(middle),
        reason: 'the far chamfer must be darker than the face, not brighter - '
            'a ring that is bright all the way round is a stroke');
  });

  test('a recessed surface lights the opposite edge from a proud one',
      () async {
    // Inversion, not just a darker fill. The old engine made a well by
    // choosing a darker base colour; a real recess turns its near wall away
    // from the light and its far wall toward it.
    final proud = await render(shade(w: w, h: h, inset: 0), w, h);
    final sunk = await render(shade(w: w, h: h, inset: 1), w, h);

    final proudTop = lumAt(proud, iw, iw ~/ 2, 1);
    final proudBottom = lumAt(proud, iw, iw ~/ 2, ih - 2);
    final sunkTop = lumAt(sunk, iw, iw ~/ 2, 1);
    final sunkBottom = lumAt(sunk, iw, iw ~/ 2, ih - 2);

    expect(proudTop - proudBottom, greaterThan(10));
    expect(sunkBottom - sunkTop, greaterThan(10),
        reason: 'the recess is lit the same way round as the proud surface, '
            'so it will read as a flat darker box');
  });

  test('the face is shaded rather than flat', () async {
    // A flat normal dotted with a fixed light is a constant, which is exactly
    // what the gradient engine produced and exactly what read as fake. The
    // shallow bow makes the interior vary.
    final b = await render(shade(w: w, h: h, grain: 0), w, h);
    final near = lumAt(b, iw, iw ~/ 2, 20);
    final far = lumAt(b, iw, iw ~/ 2, ih - 20);
    expect((near - far).abs(), greaterThan(4),
        reason: 'the interior is one flat value, so this is a gradient with '
            'extra steps');
  });

  test('the grain is anisotropic, not noise', () async {
    // Brushed metal streaks along one axis. Isotropic noise reads as dirt -
    // the plan's own word for it - and is the commonest tell in a fake metal.
    // Variance along x at fixed y should be much lower than along y at fixed
    // x, because a streak is constant along its own length.
    final b = await render(shade(w: w, h: h, grain: 0.35), w, h);

    double variance(List<double> v) {
      final m = v.reduce((a, c) => a + c) / v.length;
      return v.map((x) => (x - m) * (x - m)).reduce((a, c) => a + c) / v.length;
    }

    final alongStreak = <double>[
      for (var x = 40; x < 160; x++) lumAt(b, iw, x, 60)
    ];
    final acrossStreak = <double>[
      for (var y = 30; y < 90; y++) lumAt(b, iw, 100, y)
    ];

    expect(variance(acrossStreak), greaterThan(variance(alongStreak) * 2),
        reason: 'the grain varies as much along the streak as across it, so '
            'it is isotropic noise rather than a brush');
  });

  test('nothing is painted outside the rounded shape', () async {
    // The shader owns its own coverage, so a caller does not have to clip. If
    // this regresses, every surface in the app gets square corners.
    final b = await render(shade(w: w, h: h, radius: 30), w, h);
    expect(alphaAt(b, iw, 1, 1), 0,
        reason: 'the corner outside a 30px radius must be fully transparent');
    expect(alphaAt(b, iw, iw ~/ 2, ih ~/ 2), 255,
        reason: 'the interior must be fully opaque');
  });

  test('the shape edge is antialiased', () async {
    // Straight from the SDF. Worth asserting because the pixel size arrives as
    // a uniform - SkSL has no fwidth - so a caller that forgets it gets a hard
    // jagged edge and nothing else changes.
    final b = await render(shade(w: w, h: h, radius: 30), w, h);
    var partial = 0;
    for (var y = 0; y < ih; y++) {
      for (var x = 0; x < iw; x++) {
        final a = alphaAt(b, iw, x, y);
        if (a > 8 && a < 247) partial++;
      }
    }
    expect(partial, greaterThan(100),
        reason: 'no partially covered pixels anywhere on the outline, so the '
            'edge is aliased');
  });
}
