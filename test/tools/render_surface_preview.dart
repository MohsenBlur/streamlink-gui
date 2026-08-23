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
void main() {
  test('render', () async {
    final program = await ui.FragmentProgram.fromAsset('shaders/surface.frag');

    Future<void> render(String name, {
      required double w, required double h,
      required double radius, required double bevel,
      required List<double> base, required List<double> spec,
      required double rough, required double lightAz, required double lightEl,
      required double ambient,
      required List<double> envTop, required List<double> envBot,
      required double envAmount, required double grain,
      required double grainScale, required double inset,
      required double bow, required double sheen,
    }) async {
      final s = program.fragmentShader();
      var i = 0;
      void f(double v) => s.setFloat(i++, v);
      f(w); f(h); f(radius); f(bevel);
      base.forEach(f); spec.forEach(f);
      f(rough); f(lightAz); f(lightEl); f(ambient);
      envTop.forEach(f); envBot.forEach(f);
      f(envAmount); f(grain); f(grainScale); f(inset); f(3.0); f(1.0);
      f(bow); f(sheen);

      const pad = 30.0;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(Rect.fromLTWH(0, 0, w + pad * 2, h + pad * 2),
          Paint()..color = const Color(0xFF16181C));
      c.save();
      c.translate(pad, pad);
      c.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..shader = s);
      c.restore();
      final img = await rec.endRecording()
          .toImage((w + pad * 2).round(), (h + pad * 2).round());
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      File('shots/shader/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    // Brushed graphite panel, lit from above.
    await render('panel',
        w: 320, h: 120, radius: 14, bevel: 3.5,
        base: [0.165, 0.180, 0.208], spec: [1.0, 0.98, 0.94],
        rough: 0.35, lightAz: 1.5708, lightEl: 0.62, ambient: 0.42,
        envTop: [0.52, 0.56, 0.64], envBot: [0.04, 0.045, 0.06],
        envAmount: 0.55, grain: 0.16, grainScale: 130.0, inset: 0.0,
        bow: 0.10, sheen: 0.22);

    // The same, recessed.
    await render('well',
        w: 320, h: 120, radius: 14, bevel: 3.5,
        base: [0.10, 0.11, 0.13], spec: [1.0, 0.98, 0.94],
        rough: 0.45, lightAz: 1.5708, lightEl: 0.62, ambient: 0.38,
        envTop: [0.52, 0.56, 0.64], envBot: [0.04, 0.045, 0.06],
        envAmount: 0.45, grain: 0.13, grainScale: 130.0, inset: 1.0,
        bow: 0.08, sheen: 0.14);

    // Champagne aluminium, light theme.
    await render('champagne',
        w: 320, h: 120, radius: 14, bevel: 3.5,
        base: [0.86, 0.84, 0.78], spec: [1.0, 0.99, 0.95],
        rough: 0.30, lightAz: 1.5708, lightEl: 0.60, ambient: 0.55,
        envTop: [1.0, 0.99, 0.96], envBot: [0.35, 0.34, 0.31],
        envAmount: 0.45, grain: 0.14, grainScale: 130.0, inset: 0.0,
        bow: 0.10, sheen: 0.20);

    // A small control, to check it survives at button scale.
    await render('button',
        w: 120, h: 34, radius: 10, bevel: 2.5,
        base: [0.20, 0.215, 0.245], spec: [1.0, 0.98, 0.94],
        rough: 0.32, lightAz: 1.5708, lightEl: 0.62, ambient: 0.44,
        envTop: [0.55, 0.59, 0.68], envBot: [0.04, 0.045, 0.06],
        envAmount: 0.55, grain: 0.16, grainScale: 130.0, inset: 0.0,
        bow: 0.12, sheen: 0.22);
  });
}
