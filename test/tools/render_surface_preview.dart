import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the lit-surface shader to `shots/shader/*.png`, to look at.
///
/// Not a guard - `shader_surface_test.dart` holds the behaviour. This exists
/// because tuning a material is a loop of render, look, adjust, and doing that
/// through the whole app means a five-minute release build per iteration.
///
///   flutter test test/tools/render_surface_preview.dart
///
/// Named as a test so it can use the asset bundle, which is the only way to
/// reach `FragmentProgram.fromAsset` outside a running app.
ui.Image? _previewDummy;
ui.Image dummyGrain() {
  if (_previewDummy != null) return _previewDummy!;
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const Color(0x00000000));
  _previewDummy = rec.endRecording().toImageSync(1, 1);
  return _previewDummy!;
}

void main() {
  test('render', () async {
    final program = await ui.FragmentProgram.fromAsset('shaders/surface.frag');

    Future<void> render(
      String name, {
      required double w,
      required double h,
      required Color ground,
      double radius = 14,
      double bevel = 3.5,
      double profile = 1.0,
      double landAngle = 0.5,
      List<double> albedo = const [0.26, 0.27, 0.30],
      List<double> f0 = const [0.91, 0.92, 0.92],
      double rough = 0.34,
      double metal = 0.0,
      double aniso = 0.0,
      double bow = 0.26,
      List<double> light = const [0.0, 0.60, 0.80],
      double key = 1.0,
      double ambient = 0.55,
      double sheen = 0.20,
      double recess = 0.0,
      List<double> sky = const [0.62, 0.67, 0.76],
      List<double> gnd = const [0.05, 0.055, 0.07],
      double envAmt = 0.75,
      double horizon = 0.22,
      double softbox = 0.40,
      double rim = 0.55,
      double grainAmp = 0.0,
      double grainAcross = 3.0,
      double grainAngle = 0.0,
      double shDy = -6.0,
      double shBlur = 12.0,
      double shOp = 0.55,
      double aoOp = 0.40,
      double aoReach = 4.0,
      double innerBlur = 7.0,
      double innerOp = 0.75,
      double exposure = 1.0,
      double white = 2.2,
    }) async {
      const pad = 30.0;
      final s = program.fragmentShader();
      var i = 0;
      void f(double v) => s.setFloat(i++, v);
      f(w + 2 * pad);
      f(h + 2 * pad); // uDraw
      f(w);
      f(h); // uShape
      f(pad);
      f(radius); // uPadRad
      f(bevel);
      f(1.0);
      f(profile);
      f(landAngle); // uBevel
      albedo.forEach(f); // uAlbedo
      f0.forEach(f); // uF0
      f(rough);
      f(metal);
      f(aniso);
      f(bow); // uMat
      light.forEach(f); // uL
      f(key);
      f(ambient);
      f(sheen);
      f(recess); // uKey
      sky.forEach(f); // uSky
      gnd.forEach(f); // uGnd
      f(envAmt);
      f(horizon);
      f(softbox);
      f(rim); // uEnv
      f(grainAmp);
      f(grainAcross);
      f(grainAngle);
      f(3.0); // uGrain (seed)
      f(0.0);
      f(shDy);
      f(shBlur);
      f(shOp); // uShadow
      f(aoOp);
      f(aoReach);
      f(innerBlur);
      f(innerOp); // uOcc
      f(exposure);
      f(white);
      f(1.0);
      f(1.0); // uTone (dither, opacity)
      f(0.0);
      f(4.0);
      f(0.0);
      f(0.0); // uPattern (none)
      f(1.0);
      f(1.0);
      f(1.0); // uPatternColor
      f(0.0);
      f(1.0);
      f(1.0);
      f(0.175); // uGrainTex (off)
      s.setImageSampler(0, dummyGrain());

      final dw = w + pad * 2, dh = h + pad * 2;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(Rect.fromLTWH(0, 0, dw, dh), Paint()..color = ground);
      c.drawRect(Rect.fromLTWH(0, 0, dw, dh), Paint()..shader = s);
      final img = await rec.endRecording().toImage(dw.round(), dh.round());
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      File('shots/shader/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    // Brushed graphite panel, lit from above - rack dark.
    await render('panel',
        w: 320,
        h: 120,
        ground: const Color(0xFF16181C),
        albedo: [0.165, 0.180, 0.208],
        rough: 0.34,
        metal: 0.9,
        aniso: 0.85,
        grainAmp: 0.16,
        ambient: 0.42,
        envAmt: 0.60);

    // The same, recessed.
    await render('well',
        w: 320,
        h: 120,
        ground: const Color(0xFF16181C),
        albedo: [0.10, 0.11, 0.13],
        rough: 0.45,
        metal: 0.9,
        aniso: 0.85,
        grainAmp: 0.12,
        recess: 1.0,
        shOp: 0.0,
        ambient: 0.38,
        envAmt: 0.40);

    // Champagne aluminium, light theme.
    await render('champagne',
        w: 320,
        h: 120,
        ground: const Color(0xFFCFC9BE),
        albedo: [0.86, 0.84, 0.78],
        f0: const [0.94, 0.92, 0.86],
        rough: 0.30,
        metal: 0.9,
        aniso: 0.85,
        grainAmp: 0.13,
        ambient: 0.60,
        sky: const [1.0, 0.99, 0.96],
        gnd: const [0.35, 0.34, 0.31],
        envAmt: 0.45,
        shOp: 0.30);

    // A small control, to check it survives at button scale.
    await render('button',
        w: 120,
        h: 34,
        ground: const Color(0xFF16181C),
        radius: 10,
        bevel: 2.5,
        albedo: [0.20, 0.215, 0.245],
        rough: 0.32,
        metal: 0.9,
        aniso: 0.85,
        grainAmp: 0.16,
        bow: 0.16,
        shDy: -3.0,
        shBlur: 6.0,
        aoReach: 2.5);
  });
}
