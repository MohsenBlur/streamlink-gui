import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/material/texture_cache.dart';

/// The grain's two load-bearing invariants.
///
/// Both exist so the contrast matrix can state a worst texel in closed form
/// rather than by sampling. A texture whose effect depended on the ground would
/// make every ink assertion in the app approximate.
void main() {
  Future<List<int>> pixelsOf(TileKey key) async {
    final image = await TextureCache.generateForTest(key);
    final data = await image.toByteData();
    image.dispose();
    return data!.buffer.asUint8List().toList();
  }

  const brushed =
      TileKey(kind: TextureKind.brushed, width: 64, height: 32, amplitude: 3, seed: 0x5EED);

  test('the grain only ever lightens, and never by more than its amplitude',
      () async {
    // This is what makes the worst texel computable: `base + amplitude` on a
    // dark ground, and nothing at all on the friendly side. A tile that could
    // darken would put the worst case somewhere only sampling could find.
    for (final amp in [1, 2, 3, 4]) {
      final px = await pixelsOf(TileKey(
          kind: TextureKind.brushed,
          width: 64,
          height: 32,
          amplitude: amp,
          seed: 0x5EED));
      for (var i = 0; i < px.length; i += 4) {
        expect(px[i], inInclusiveRange(0, amp),
            reason: 'deviation must stay within the declared amplitude');
        expect(px[i + 1], px[i], reason: 'the tile is grey');
        expect(px[i + 2], px[i], reason: 'the tile is grey');
        expect(px[i + 3], 255, reason: 'plus needs a fully opaque source');
      }
    }
  });

  test('a tile is deterministic across runs', () async {
    // A grain that changed between launches would make the screenshot matrix
    // unusable and every visual diff meaningless.
    expect(await pixelsOf(brushed), await pixelsOf(brushed));
  });

  test('different amplitudes and kinds are different tiles', () async {
    final a = await pixelsOf(brushed);
    final b = await pixelsOf(const TileKey(
        kind: TextureKind.brushed,
        width: 64,
        height: 32,
        amplitude: 1,
        seed: 0x5EED));
    final c = await pixelsOf(const TileKey(
        kind: TextureKind.speckle,
        width: 64,
        height: 32,
        amplitude: 3,
        seed: 0x5EED));
    expect(a, isNot(b));
    expect(a, isNot(c));
    expect(brushed, isNot(equals(c)));
    expect(brushed.hashCode, isNot(c.hashCode));
  });

  test('brushed streaks run along x, not along y', () async {
    // The anisotropy IS the material. An isotropic tile on a faceplate reads
    // as plastic, and a round specular hotspot on brushed metal is the single
    // clearest tell that it is fake.
    final px = await pixelsOf(brushed);
    int at(int x, int y) => px[((y * 64) + x) * 4];

    // Variation along a row should be far smaller than variation down a column.
    double spread(List<int> v) {
      final mean = v.reduce((a, b) => a + b) / v.length;
      var s = 0.0;
      for (final x in v) {
        s += (x - mean) * (x - mean);
      }
      return s / v.length;
    }

    final alongRow = spread([for (var x = 0; x < 64; x++) at(x, 7)]);
    final downColumn = spread([for (var y = 0; y < 32; y++) at(3, y)]);
    expect(downColumn, greaterThan(alongRow),
        reason: 'streaks must vary across the grain more than along it');
  });

  test('plus compositing adds exactly, on any ground', () async {
    // The claim the whole design rests on. srcOver with a translucent grey
    // would move a dark ground about five times as far as a light one; plus
    // moves both by the same integer.
    for (final ground in [
      const Color(0xFF16181C), // Rack dark canvas
      const Color(0xFFE4DDCE), // Rack light surface
      const Color(0xFF808080),
    ]) {
      const dev = 3;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const rect = Rect.fromLTWH(0, 0, 4, 4);
      canvas.drawRect(rect, Paint()..color = ground);
      canvas.drawRect(
          rect,
          Paint()
            ..blendMode = BlendMode.plus
            ..color = const Color.fromARGB(255, dev, dev, dev));
      final image = await recorder.endRecording().toImage(4, 4);
      final data = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();

      expect(data[0], (ground.r * 255).round() + dev, reason: 'red on $ground');
      expect(data[1], (ground.g * 255).round() + dev,
          reason: 'green on $ground');
      expect(data[2], (ground.b * 255).round() + dev, reason: 'blue on $ground');
    }
  });

  testWidgets('a material that declares a grain actually paints one',
      (tester) async {
    // The vacuous-pass this exists to stop: the cache starts empty, the
    // painter skips layer 3 on a miss, and every assertion about texture
    // passes because there is no texture. So warm the tile first, then measure
    // the painted surface and require it to be non-uniform.
    final rack = MaterialSpec.of(AppMaterial.rack).palette(true);
    final spec = rack.texture!;
    final key = TileKey(
      kind: spec.kind,
      width: spec.tileDevicePx.width.round(),
      height: spec.tileDevicePx.height.round(),
      amplitude: spec.amplitudeFor(SurfaceRole.panel),
      seed: spec.seed,
    );

    // Inside runAsync, not around it: `request` schedules real async work, and
    // started in the fake-async zone it would never progress.
    await tester.runAsync(() async {
      final ready = Completer<void>();
      TextureCache.request(key, ready.complete);
      await ready.future;
    });

    Future<double> spreadOf(MaterialPalette palette) async {
      final d = SkeuoDecoration.role(
        palette: palette,
        role: SurfaceRole.panel,
        depth: NeuElevation.d2,
        radius: NeuRadius.r12,
      );
      final recorder = ui.PictureRecorder();
      final painter = d.createBoxPainter();
      painter.paint(Canvas(recorder), Offset.zero,
          const ImageConfiguration(size: Size(120, 120), devicePixelRatio: 1));
      painter.dispose();
      final image = await recorder.endRecording().toImage(120, 120);
      final px = (await image.toByteData())!.buffer.asUint8List();
      image.dispose();
      // The second difference of row means.
      //
      // Two things had to be cancelled out to see the grain at all. Adjacent
      // pixels are no good: Skia dithers gradients by about a level, which
      // swamps a three-level structured grain - measured, an untextured Soft
      // panel is as "rough" by that metric as a brushed Rack one. And plain
      // variance is no good either, because a gradient is variance.
      //
      // Averaging each row cancels the dither, and taking the second
      // difference cancels the ramp: a linear gradient has zero curvature by
      // construction, so whatever is left is structure. For a brushed tile
      // that is the streaks, which is exactly what should be measured.
      final rowMeans = <double>[];
      for (var y = 30; y < 90; y++) {
        var sum = 0;
        for (var x = 40; x < 80; x++) {
          sum += px[((y * 120) + x) * 4];
        }
        rowMeans.add(sum / 40);
      }
      var curvature = 0.0;
      for (var i = 1; i < rowMeans.length - 1; i++) {
        curvature +=
            (rowMeans[i - 1] - 2 * rowMeans[i] + rowMeans[i + 1]).abs();
      }
      return curvature / (rowMeans.length - 2);
    }

    final rackSpread = await tester.runAsync(() => spreadOf(rack)) as double;
    final softSpread = await tester
        .runAsync(() => spreadOf(MaterialSpec.of(AppMaterial.soft).palette(true)))
        as double;

    expect(rackSpread, greaterThan(softSpread * 3),
        reason: 'Rack declares a brushed grain and Soft declares none, so '
            'Rack must show structure a smooth ramp does not. Equal readings '
            'mean the tile never landed and every texture assertion in the '
            'suite is vacuous.');
  });
}
