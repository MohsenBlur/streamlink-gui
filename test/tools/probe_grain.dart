import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Calibration probe for the shader grain: renders grain-off vs grain-on
/// across the (grainAcross, px) matrix and prints the measured luminance
/// spread each combination actually paints, so retuning is done against
/// numbers instead of squinting.
void main() {
  late ui.FragmentProgram program;
  setUpAll(() async {
    program = await ui.FragmentProgram.fromAsset('shaders/surface.frag');
  });

  const w = 220.0, h = 120.0, pad = 30.0;

  ui.FragmentShader shade({
    required double grainAmp,
    required double grainAcross,
    required double px,
    double rough = 0.40,
    double aniso = 0.85,
  }) {
    final s = program.fragmentShader();
    var i = 0;
    void f(double v) => s.setFloat(i++, v);
    f(w + 2 * pad);
    f(h + 2 * pad);
    f(w);
    f(h);
    f(pad);
    f(12); // radius
    f(3.0); // chamfer
    f(px);
    f(1.0); // profile
    f(0.5); // landAngle
    for (final v in [0.16, 0.18, 0.21]) {
      f(v); // albedo ~ rack dark surface
    }
    for (final v in [0.91, 0.93, 0.95]) {
      f(v); // f0
    }
    f(rough);
    f(0.30); // metal
    f(aniso);
    f(0.15); // bow
    for (final v in [0.0, 0.6018, 0.7986]) {
      f(v); // light az 90 el 37
    }
    f(0.85); // key
    f(0.52); // ambient
    f(0.03); // sheen
    f(0.0); // recess
    for (final v in [0.45, 0.49, 0.55]) {
      f(v); // sky
    }
    for (final v in [0.03, 0.03, 0.04]) {
      f(v); // gnd
    }
    f(0.20); // envAmt
    f(0.30); // horizon
    f(0.05); // softbox
    f(0.38); // rim
    f(grainAmp);
    f(grainAcross);
    f(0.0); // angle
    f(3.0); // seed
    f(0.0);
    f(-6.0);
    f(12.0);
    f(0.0); // shadow OFF for clean face measurement
    f(0.0);
    f(4.0);
    f(7.0);
    f(0.0); // occ off
    f(1.0);
    f(2.2);
    f(0.0); // dither OFF
    f(1.0);
    return s;
  }

  Future<ByteData> render(ui.FragmentShader s) async {
    final dw = (w + 2 * pad).toInt(), dh = (h + 2 * pad).toInt();
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(
        Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()), Paint()..shader = s);
    final img = await rec.endRecording().toImage(dw, dh);
    final b = (await img.toByteData())!;
    img.dispose();
    return b;
  }

  test('print grain visibility matrix', () async {
    final stride = (w + 2 * pad).toInt();
    double lum(ByteData b, int x, int y) {
      final o = (y * stride + x) * 4;
      return b.getUint8(o) * .299 +
          b.getUint8(o + 1) * .587 +
          b.getUint8(o + 2) * .114;
    }

    // Face interior sample box, clear of chamfer and sheen extremes.
    ({double spread, double vRough, double hRough}) measure(ByteData b) {
      var mn = 255.0, mx = 0.0, v = 0.0, hh = 0.0;
      var n = 0;
      for (var y = 70; y < 130; y++) {
        for (var x = 60; x < 220; x++) {
          final l = lum(b, x, y);
          mn = l < mn ? l : mn;
          mx = l > mx ? l : mx;
          v += (lum(b, x, y + 1) - l).abs();
          hh += (lum(b, x + 1, y) - l).abs();
          n++;
        }
      }
      return (spread: mx - mn, vRough: v / n, hRough: hh / n);
    }

    for (final px in [1.0, 1 / 1.5, 0.5]) {
      final off = measure(await render(shade(grainAmp: 0, grainAcross: 6, px: px)));
      for (final acr in [3.5, 6.0, 9.0]) {
        for (final amp in [0.3, 0.6]) {
          final on =
              measure(await render(shade(grainAmp: amp, grainAcross: acr, px: px)));
          // ignore: avoid_print
          print('px=${px.toStringAsFixed(2)} acr=$acr amp=$amp  '
              'spread ${off.spread.toStringAsFixed(1)}->${on.spread.toStringAsFixed(1)}  '
              'vRough ${off.vRough.toStringAsFixed(2)}->${on.vRough.toStringAsFixed(2)}  '
              'hRough ${off.hRough.toStringAsFixed(2)}->${on.hRough.toStringAsFixed(2)}');
        }
      }
    }
  });
}
