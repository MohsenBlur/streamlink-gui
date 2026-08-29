import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/material_palette.dart';
import 'package:streamlink_gui/theme/material/texture_cache.dart';

/// The lit-surface shader, asserted on properties a gradient cannot have.
///
/// The point of moving to a fragment shader is not that it looks nicer in one
/// screenshot - it is that the surface behaves like a surface. Each test here
/// names one behaviour that separates a lit object from a picture of one, and
/// every one of them fails on any stack of gradients:
///
/// * the highlight MOVES when the light moves,
/// * the edge is directional - lit side bright, far side dark - not a ring,
/// * the far edge still carries a bright arris at the silhouette, because at
///   grazing incidence every material reflects everything,
/// * a recessed surface inverts its edge lighting relative to a proud one,
/// * a metal's reflection carries the metal's own colour,
/// * the contact shadow hugs the silhouette and the cast shadow reaches past,
/// * output is valid premultiplied everywhere, because Skia will clamp what
///   is not and a clamp silently shifts hue.
///
/// The uniform write below is the layout contract, kept in declaration order
/// in one place because SkSL uniforms are positional: inserting one in the
/// middle of the shader silently shifts every value after it, and the result
/// still renders.
void main() {
  late ui.FragmentProgram program;

  setUpAll(() async {
    program = await ui.FragmentProgram.fromAsset('shaders/surface.frag');
  });

  const pad = 24.0;

  ui.Image? dummyCache;
  ui.Image dummyGrain() {
    if (dummyCache != null) return dummyCache!;
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = const Color(0x00000000));
    dummyCache = rec.endRecording().toImageSync(1, 1);
    return dummyCache!;
  }

  ui.FragmentShader shade({
    required double w,
    required double h,
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
    List<double> light = const [-0.35, 0.72, 0.60],
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
    double seed = 3,
    double shDx = 0.0,
    double shDy = -6.0,
    double shBlur = 12.0,
    double shOp = 0.55,
    double aoOp = 0.40,
    double aoReach = 4.0,
    double innerBlur = 7.0,
    double innerOp = 0.75,
    double exposure = 1.0,
    double white = 2.2,
    double dither = 1.0,
    double opacity = 1.0,
    double px = 1.0,
    double patternKind = 0.0,
    double patternPeriod = 4.0,
    double patternStrength = 0.0,
    double patternStrength2 = 0.0,
    List<double> patternColor = const [1.0, 1.0, 1.0],
    double grainTexStrength = 0.0,
    ui.Image? grainImage,
  }) {
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
    f(px);
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
    f(seed); // uGrain
    f(shDx);
    f(shDy);
    f(shBlur);
    f(shOp); // uShadow
    f(aoOp);
    f(aoReach);
    f(innerBlur);
    f(innerOp); // uOcc
    f(exposure);
    f(white);
    f(dither);
    f(opacity); // uTone
    f(patternKind);
    f(patternPeriod);
    f(patternStrength);
    f(patternStrength2); // uPattern
    patternColor.forEach(f); // uPatternColor
    f(grainTexStrength);
    f((grainImage?.width ?? 1).toDouble());
    f((grainImage?.height ?? 1).toDouble());
    f(0.175); // uGrainTex (mean)
    // A declared child sampler must ALWAYS be bound - Skia refuses to
    // instantiate the effect otherwise - so strength-zero renders bind a
    // 1x1 transparent stand-in.
    s.setImageSampler(0, grainImage ?? dummyGrain());
    return s;
  }

  /// Renders one surface of [w]x[h] centred in a [pad]-inflated draw rect.
  Future<ByteData> render(ui.FragmentShader s, double w, double h) async {
    final dw = (w + 2 * pad).toInt();
    final dh = (h + 2 * pad).toInt();
    final rec = ui.PictureRecorder();
    final c =
        ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()));
    c.drawRect(ui.Rect.fromLTWH(0, 0, dw.toDouble(), dh.toDouble()),
        ui.Paint()..shader = s);
    final img = await rec.endRecording().toImage(dw, dh);
    final bytes = (await img.toByteData())!;
    img.dispose();
    return bytes;
  }

  int lum(ByteData b, int stride, int x, int y) {
    final o = (y * stride + x) * 4;
    return ((b.getUint8(o) * 299 +
                b.getUint8(o + 1) * 587 +
                b.getUint8(o + 2) * 114) /
            1000)
        .round();
  }

  int alpha(ByteData b, int stride, int x, int y) =>
      b.getUint8((y * stride + x) * 4 + 3);

  const w = 220.0, h = 120.0;
  const stride = 268; // w + 2*pad

  test('the highlight moves when the light moves', () async {
    // The property a gradient cannot have. A LinearGradient's bright end is
    // wherever it was authored; a lit surface's is wherever the light is.
    final a =
        await render(shade(w: w, h: h, light: const [-0.60, 0.55, 0.58]), w, h);
    final bb =
        await render(shade(w: w, h: h, light: const [0.60, 0.55, 0.58]), w, h);
    // Sample the two upper corners of the face, inside the chamfer.
    final aLeft = lum(a, stride, (pad + 26).toInt(), (pad + 20).toInt());
    final aRight = lum(a, stride, (pad + w - 26).toInt(), (pad + 20).toInt());
    final bLeft = lum(bb, stride, (pad + 26).toInt(), (pad + 20).toInt());
    final bRight = lum(bb, stride, (pad + w - 26).toInt(), (pad + 20).toInt());

    expect(aLeft, greaterThan(aRight),
        reason: 'lit from the left, the left of the face must be brighter '
            '(L=$aLeft R=$aRight)');
    expect(bRight, greaterThan(bLeft),
        reason: 'lit from the right, the right of the face must be brighter '
            '(L=$bLeft R=$bRight)');
  });

  test('the face is shaded, not one flat colour', () async {
    // A flat normal dotted with a fixed light is a constant, which is exactly
    // what the gradient engine produced and exactly what read as fake. The
    // shallow bow makes the highlight travel across the interior.
    final b = await render(shade(w: w, h: h), w, h);
    final samples = <int>[
      for (var x = 40; x < w - 40; x += 20)
        lum(b, stride, (pad + x).toInt(), (pad + h / 2).toInt())
    ];
    final spread = samples.reduce((a, c) => a > c ? a : c) -
        samples.reduce((a, c) => a < c ? a : c);
    expect(spread, greaterThan(2),
        reason: 'a bowed face must vary across its width (samples $samples)');
  });

  test('a recessed surface lights the opposite edge from a proud one',
      () async {
    // Inversion, not just a darker fill. The old engine made a well by
    // choosing a darker base colour; a real recess turns its near wall away
    // from the light and its far wall toward it.
    final up = await render(shade(w: w, h: h, recess: 0), w, h);
    final dn = await render(shade(w: w, h: h, recess: 1), w, h);
    int topEdge(ByteData b) =>
        lum(b, stride, (pad + w / 2).toInt(), (pad + 2).toInt());
    int botEdge(ByteData b) =>
        lum(b, stride, (pad + w / 2).toInt(), (pad + h - 3).toInt());
    final upTop = topEdge(up), upBot = botEdge(up);
    final dnTop = topEdge(dn), dnBot = botEdge(dn);
    expect(upTop - upBot, greaterThan(0),
        reason: 'a proud edge catches light on the lit side '
            '(raised top=$upTop bot=$upBot)');
    expect(dnTop - dnBot, lessThan(upTop - upBot),
        reason: 'a recess must invert the edge lighting relative to a boss '
            '(recess top=$dnTop bot=$dnBot)');
  });

  test('the edge is directional, not a uniform ring, and its arris grazes',
      () async {
    final b = await render(shade(w: w, h: h), w, h);
    final x = (pad + w / 2).toInt();
    // Light is above, so the top chamfer faces it and the bottom faces away.
    final top = lum(b, stride, x, (pad + 2).toInt());
    final face = lum(b, stride, x, (pad + h / 2).toInt());
    final botLand = lum(b, stride, x, (pad + h - 3).toInt());
    final botArris = lum(b, stride, x, (pad + h - 1).toInt());

    // 1. A machined chamfer is lit on one side and shadowed on the other. A
    //    constant-alpha ring - the thing this replaces - cannot do this at all.
    expect(top, greaterThan(face + 8),
        reason: 'the chamfer facing the light must beat the face '
            '(top=$top face=$face)');
    expect(botLand, lessThan(face - 8),
        reason: 'the chamfer facing away must fall below the face '
            '(botLand=$botLand face=$face)');

    // 2. At the extreme silhouette the normal turns into the screen plane and
    //    reflectance approaches 1 regardless of F0, so even the SHADOWED edge
    //    carries a bright arris. This is the cue a top-lit gradient can never
    //    produce, because a gradient makes the bottom edge monotonically
    //    darkest.
    expect(botArris, greaterThan(botLand + 8),
        reason: 'the grazing arris must brighten against the land inside it '
            '(arris=$botArris land=$botLand)');
  });

  test('a contact shadow hugs the silhouette and the cast shadow reaches past',
      () async {
    // Two different phenomena that UI code habitually collapses into one
    // blurred blob. The contact term is non-directional, has zero offset and
    // is tightest at the edge; the cast shadow is directional and reaches
    // further. The contact term's absence is exactly why UI elements float.
    final b = await render(shade(w: w, h: h), w, h);
    final near = alpha(b, stride, (pad + w / 2).toInt(), (pad + h + 3).toInt());
    final far = alpha(b, stride, (pad + w / 2).toInt(), (pad + h + 20).toInt());
    final corner = alpha(b, stride, 1, 1);
    expect(near, greaterThan(far),
        reason: 'contact occlusion must be tightest at the silhouette '
            '(near=$near far=$far)');
    expect(far, greaterThan(0),
        reason: 'the cast shadow must reach further out');
    expect(corner, lessThan(20), reason: 'and must fade to nothing');
  });

  test('the shape edge is antialiased', () async {
    // Straight from the SDF. Worth asserting because the pixel size arrives
    // as a uniform - SkSL has no fwidth - so a caller that forgets it gets a
    // hard jagged edge and nothing else changes.
    final b = await render(shade(w: w, h: h, radius: 40), w, h);
    var partial = 0;
    for (var y = 0; y < 40; y++) {
      for (var x = 0; x < 40; x++) {
        final a = alpha(b, stride, x, y);
        if (a > 12 && a < 243) partial++;
      }
    }
    expect(partial, greaterThan(10),
        reason: 'no partially covered pixels in the corner, so the outline '
            'is aliased');
  });

  Future<ui.Image> brushedTile() => TextureCache.generateForTest(
      const TileKey(
          kind: TextureKind.brushed,
          width: 512,
          height: 128,
          amplitude: 255,
          seed: 0x5EED));

  test('the sampled grain renders, at every common display scale', () async {
    // The scratches are geometry now - a device-pixel tile tilting the
    // normal - so this drives the real sampler path with the real
    // generator's tile and asserts the lighting makes them visible. The
    // v1.8.0 regression this file remembers (a fade guard erasing all
    // grain at ordinary display scales) cannot come back silently: the
    // sampled path has no Nyquist guard to mis-derive, and this measures
    // at both common scales anyway.
    final tile = await brushedTile();
    for (final px in [1.0, 1 / 1.5]) {
      final off = await render(
          shade(w: w, h: h, dither: 0, px: px, rough: 0.40), w, h);
      final on = await render(
          shade(
              w: w,
              h: h,
              dither: 0,
              px: px,
              rough: 0.40,
              aniso: 0.85,
              grainTexStrength: 0.55,
              grainImage: tile),
          w,
          h);
      double vRough(ByteData b) {
        var v = 0.0;
        var n = 0;
        for (var y = 70; y < 110; y++) {
          for (var x = 60; x < 160; x++) {
            v += (lum(b, stride, x, y + 1) - lum(b, stride, x, y)).abs();
            n++;
          }
        }
        return v / n;
      }

      final base = vRough(off);
      final grained = vRough(on);
      expect(grained, greaterThan(base * 3),
          reason: 'at px=$px the sampled scratches must be measurably '
              'rougher than the plain face '
              '(off=${base.toStringAsFixed(2)} '
              'on=${grained.toStringAsFixed(2)})');
    }
  });

  test('the sampled grain is LIT: scratches follow the lighting, not a stamp',
      () async {
    // The painted-on defect, held out forever: if the scratches were a
    // luminance layer their contrast would be identical everywhere. As
    // geometry their visibility must vary across the face with the
    // specular response - measurably rougher in the lit upper half than in
    // the shaded lower half.
    final tile = await brushedTile();
    final b = await render(
        shade(
            w: w,
            h: h,
            dither: 0,
            rough: 0.40,
            aniso: 0.85,
            grainTexStrength: 0.55,
            grainImage: tile),
        w,
        h);
    double bandRough(int y0, int y1) {
      var v = 0.0;
      var n = 0;
      for (var y = y0; y < y1; y++) {
        for (var x = 60; x < 160; x++) {
          v += (lum(b, stride, x, y + 1) - lum(b, stride, x, y)).abs();
          n++;
        }
      }
      return v / n;
    }

    // Direction deliberately unasserted: where the contrast peaks depends
    // on the tone map (a saturated sheen band COMPRESSES its scratches and
    // the flanks show them hardest - measured, not guessed). What a stamp
    // can never do is VARY: a luminance layer has identical contrast in
    // every band.
    final bands = [
      bandRough(48, 78),
      bandRough(85, 115),
      bandRough(120, 150),
    ]..sort();
    expect(bands.last, greaterThan(bands.first * 1.3),
        reason: 'scratch contrast must vary across the face with the '
            'lighting (bands=${bands.map((b) => b.toStringAsFixed(2)).join(', ')})'
            ' - equal contrast everywhere is the painted-on defect');
  });

  test('the grain is anisotropic: streaks along the brush, not noise',
      () async {
    final tile = await brushedTile();
    final b = await render(
        shade(
            w: w,
            h: h,
            dither: 0,
            rough: 0.40,
            aniso: 0.85,
            grainTexStrength: 0.55,
            grainImage: tile),
        w,
        h);
    var along = 0.0, across = 0.0;
    var n = 0;
    for (var y = 70; y < 110; y++) {
      for (var x = 60; x < 160; x++) {
        along += (lum(b, stride, x + 1, y) - lum(b, stride, x, y)).abs();
        across += (lum(b, stride, x, y + 1) - lum(b, stride, x, y)).abs();
        n++;
      }
    }
    // 2.5x, recalibrated for the satin distribution: the quieter tile
    // trades some across-grain contrast for realism, measuring ~3.1x here.
    // Isotropic noise measures ~1x, so the margin still catches the
    // dirt-not-brush failure this exists for.
    expect(across / n, greaterThan(2.5 * along / n),
        reason: 'a horizontal brush varies fast across the grain, slow '
            'along it (along=${(along / n).toStringAsFixed(3)} '
            'across=${(across / n).toStringAsFixed(3)})');
  });

  test('pattern kind 0 ignores every other pattern parameter', () async {
    // The no-op guard: three materials ship with patternKind 0, and a stray
    // strength or colour must not leak one pixel of raster into them.
    final a = await render(shade(w: w, h: h, dither: 0), w, h);
    final b = await render(
        shade(
            w: w,
            h: h,
            dither: 0,
            patternStrength: 0.9,
            patternStrength2: 0.9,
            patternPeriod: 3,
            patternColor: const [1.0, 0.2, 0.2]),
        w,
        h);
    for (var y = 40; y < 160; y += 7) {
      for (var x = 40; x < 200; x += 7) {
        expect(lum(b, stride, x, y), lum(a, stride, x, y),
            reason: 'kind 0 must be bit-identical at ($x,$y)');
      }
    }
  });

  test('the scanline darkens, periodically, and never lifts', () async {
    // A CRT raster is a property of the SURFACE: multiplicative, so it can
    // only darken the ground under a light ink - the direction the contrast
    // model is safe in.
    final off = await render(shade(w: w, h: h, dither: 0), w, h);
    final on = await render(
        shade(
            w: w,
            h: h,
            dither: 0,
            patternKind: 1,
            patternPeriod: 4,
            patternStrength: 0.3),
        w,
        h);
    var lifted = 0, darkened = 0;
    for (var y = 60; y < 140; y++) {
      final a = lum(off, stride, 110, y), b2 = lum(on, stride, 110, y);
      if (b2 > a + 1) lifted++;
      if (b2 < a - 1) darkened++;
    }
    expect(lifted, 0, reason: 'a multiplicative raster must never lift');
    expect(darkened, greaterThan(20), reason: 'and must visibly darken rows');

    // Periodicity: 4 device px at px=1 - the darkened rows repeat.
    var flips = 0;
    var wasDark = false;
    for (var y = 60; y < 140; y++) {
      final dark =
          lum(on, stride, 110, y) < lum(off, stride, 110, y) - 1;
      if (dark != wasDark) flips++;
      wasDark = dark;
    }
    expect(flips, greaterThan(15),
        reason: 'the darkening must alternate at the period, not be a wash');
  });

  test('the dial glow lifts toward the top of the pane and stays bounded',
      () async {
    final off = await render(shade(w: w, h: h, dither: 0), w, h);
    final on = await render(
        shade(
            w: w,
            h: h,
            dither: 0,
            patternKind: 2,
            patternStrength: 0.10,
            patternStrength2: 2.0,
            patternColor: const [1.0, 0.85, 0.6]),
        w,
        h);
    // y-UP shader frame: the TOP of the pane is the low image y.
    final topLift = lum(on, stride, 110, 50) - lum(off, stride, 110, 50);
    final bottomLift = lum(on, stride, 110, 150) - lum(off, stride, 110, 150);
    expect(topLift, greaterThan(bottomLift + 2),
        reason: 'the lamp sits above the dial, so the glow must fall away '
            'downward (top=+$topLift bottom=+$bottomLift)');
    expect(topLift, lessThan(80), reason: 'a glow, not a floodlight');
  });

  test('the grain is anisotropic: streaks along the brush, not noise',
      () async {
    // Brushed metal varies fast across the grain and slowly along it.
    // Isotropic noise reads as dirt, and is the commonest tell in fake metal.
    final b = await render(
        shade(
            w: w, h: h, grainAmp: 0.3, grainAcross: 3.5, rough: 0.40, dither: 0),
        w,
        h);
    var along = 0.0, across = 0.0;
    var n = 0;
    for (var y = 70; y < 110; y++) {
      for (var x = 60; x < 160; x++) {
        along += (lum(b, stride, x + 1, y) - lum(b, stride, x, y)).abs();
        across += (lum(b, stride, x, y + 1) - lum(b, stride, x, y)).abs();
        n++;
      }
    }
    expect(across / n, greaterThan(4 * along / n),
        reason: 'a horizontal brush varies fast across the grain, slow along '
            'it (along=${(along / n).toStringAsFixed(3)} '
            'across=${(across / n).toStringAsFixed(3)})');
  });

  test('a metal reflects its own tint; a dielectric does not', () async {
    // F0 is what separates gold from grey plastic: a metal's specular carries
    // the metal's colour, a dielectric's stays neutral at ~4% white.
    final die = await render(shade(w: w, h: h, metal: 0.0), w, h);
    final met = await render(
        shade(w: w, h: h, metal: 1.0, f0: const [0.95, 0.64, 0.22]), w, h);
    int chan(ByteData b, int c) =>
        b.getUint8((((pad + 14).toInt()) * stride + (pad + w / 2).toInt()) * 4 +
            c);
    expect(chan(met, 0) - chan(met, 2), greaterThan(chan(die, 0) - chan(die, 2)),
        reason: 'a gold F0 must warm the specular; a dielectric stays neutral');
  });

  test('nothing outside the draw rect, and output is valid premultiplied',
      () async {
    // Skia clamps an invalid premultiplied colour, and the clamp silently
    // shifts hue - so the shader must never rely on it.
    final b = await render(shade(w: w, h: h), w, h);
    final dh = (h + 2 * pad).toInt();
    var bad = 0;
    for (var y = 0; y < dh; y += 3) {
      for (var x = 0; x < stride; x += 3) {
        final o = (y * stride + x) * 4;
        final a = b.getUint8(o + 3);
        for (var c = 0; c < 3; c++) {
          if (b.getUint8(o + c) > a + 1) bad++;
        }
      }
    }
    expect(bad, 0, reason: '$bad premultiplication violations');
  });

  test('the interior is fully opaque and the far corner fully clear', () async {
    // The shader owns its own coverage, so no caller has to clip. If this
    // regresses, every surface in the app gets square corners - or worse,
    // translucent faces compositing over whatever is behind them.
    final b = await render(shade(w: w, h: h, radius: 30), w, h);
    expect(alpha(b, stride, (pad + w / 2).toInt(), (pad + h / 2).toInt()), 255,
        reason: 'the interior must be fully opaque');
    expect(alpha(b, stride, stride - 1, 0), lessThan(8),
        reason: 'the top-right of the pad, away from the shadow, must be '
            'transparent');
  });
}
