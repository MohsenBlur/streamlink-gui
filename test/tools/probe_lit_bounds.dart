import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/lit_surface.dart';
import 'package:streamlink_gui/theme/material/texture_cache.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';

/// Calibration instrument, not a gate: prints the measured lift/drop for
/// every lit role of every registered material in one pass, so a new
/// material's declared bounds can be set to measurement instead of iterated
/// one gate-failure at a time. Register the draft spec, run this, copy the
/// numbers in.
void main() {
  setUpAll(() async {
    await LitSurfaceProgram.load();
    // Prime what the painter samples, or this probe measures a different
    // surface than the gate it calibrates.
    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final t = spec.palette(isDark).texture;
        if (t == null) continue;
        await TextureCache.prime(TileKey(
          kind: t.kind,
          width: t.tileDevicePx.width.round(),
          height: t.tileDevicePx.height.round(),
          amplitude: 255,
          seed: t.seed,
        ));
      }
    }
  });

  Future<({double lift, double drop})> measure(
      MaterialPalette p, SurfaceRole role, double depth,
      {Size size = const Size(220, 110)}) async {
    const inset = 30.0;
    final d =
        SkeuoDecoration.role(palette: p, role: role, depth: depth, radius: 12);
    final full = Size(size.width + 2 * inset, size.height + 2 * inset);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Offset.zero & full, Paint()..color = p.canvas);
    final painter = d.createBoxPainter(() {});
    painter.paint(canvas, const Offset(inset, inset),
        ImageConfiguration(size: size, devicePixelRatio: 1.0));
    painter.dispose();
    final img = await rec
        .endRecording()
        .toImage(full.width.round(), full.height.round());
    final raw = (await img.toByteData())!;
    img.dispose();
    final stride = full.width.round();
    final bytes = raw.buffer.asUint8List();
    double lum(int x, int y) {
      final o = (y * stride + x) * 4;
      return (bytes[o] * 299 + bytes[o + 1] * 587 + bytes[o + 2] * 114) / 1000;
    }

    final x0 = (inset + 8).toInt(), x1 = (inset + size.width - 8).toInt();
    final y0 = (inset + 8).toInt(), y1 = (inset + size.height - 8).toInt();
    var minL = 255.0, maxL = -255.0;
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        var sum = 0.0;
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            sum += lum(x + dx, y + dy);
          }
        }
        final l = sum / 25;
        minL = math.min(minL, l);
        maxL = math.max(maxL, l);
      }
    }
    final albedo = (d.params.base.r * 255 * 299 +
            d.params.base.g * 255 * 587 +
            d.params.base.b * 255 * 114) /
        1000;
    return (lift: maxL - albedo, drop: albedo - minL);
  }

  test('print measured bounds for every lit material', () async {
    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final p = spec.palette(isDark);
        if (p.lit == null) continue;
        final mode = '${spec.id.key} ${isDark ? 'dark ' : 'light'}';
        for (final (role, depths) in [
          (SurfaceRole.panel, const [2.0, 3.0]),
          (SurfaceRole.raised, const [2.0, 3.0, 5.0]),
          (SurfaceRole.sunken, const [3.0]),
          (SurfaceRole.well, const [1.0]),
          (SurfaceRole.screen, const [2.0]),
        ]) {
          for (final depth in depths) {
            final m = await measure(p, role, depth);
            // ignore: avoid_print
            print('$mode ${role.name.padRight(6)} d$depth  '
                'lift=${m.lift.toStringAsFixed(1)}  '
                'drop=${m.drop.toStringAsFixed(1)}');
          }
        }
        final chip = await measure(p, SurfaceRole.raised, 2,
            size: const Size(120, 34));
        // ignore: avoid_print
        print('$mode raised CHIP    lift=${chip.lift.toStringAsFixed(1)}  '
            'drop=${chip.drop.toStringAsFixed(1)}');
      }
    }
  });
}
