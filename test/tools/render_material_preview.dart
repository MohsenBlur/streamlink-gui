import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/lit_surface.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';

/// Renders every lit material's roles through the REAL painter to
/// `shots/material/*.png`, with face statistics printed for calibration.
///
/// Not a guard - `lit_ground_test.dart` holds the honesty bound. This is the
/// tuning loop: edit the `LitSpec`, run this, read the numbers, look at the
/// picture.
///
///   flutter test test/tools/render_material_preview.dart
void main() {
  setUpAll(() async {
    await LitSurfaceProgram.load();
  });

  test('render', () async {
    expect(LitSurfaceProgram.ready, isTrue);

    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final p = spec.palette(isDark);
        if (p.lit == null) continue;
        final mode = isDark ? 'dark' : 'light';

        for (final (role, size, depth) in [
          (SurfaceRole.panel, const Size(360, 140), 2.0),
          (SurfaceRole.raised, const Size(220, 110), 3.0),
          (SurfaceRole.raised, const Size(120, 34), 2.0),
          (SurfaceRole.sunken, const Size(220, 110), 3.0),
          (SurfaceRole.screen, const Size(220, 110), 2.0),
        ]) {
          const inset = 30.0;
          final d = SkeuoDecoration.role(
            palette: p,
            role: role,
            depth: depth,
            radius: 12,
          );
          final full =
              Size(size.width + 2 * inset, size.height + 2 * inset);
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
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          final raw = (await img.toByteData())!;
          img.dispose();

          final tag =
              '${spec.id.key}-$mode-${role.name}-${size.width.toInt()}';
          File('shots/material/$tag.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(png!.buffer.asUint8List());

          // Face statistics over the content region (8px inside the edge),
          // in sRGB levels relative to the albedo the factory resolved.
          final stride = full.width.round();
          final albedo = (d.params.base.r * 255 * 299 +
                  d.params.base.g * 255 * 587 +
                  d.params.base.b * 255 * 114) /
              1000;
          var minL = 255.0, maxL = 255.0 * -1, sum = 0.0;
          var n = 0;
          final bytes = raw.buffer.asUint8List();
          for (var y = (inset + 8).toInt();
              y < inset + size.height - 8;
              y++) {
            for (var x = (inset + 8).toInt();
                x < inset + size.width - 8;
                x++) {
              final o = (y * stride + x) * 4;
              final l = (bytes[o] * 299 +
                      bytes[o + 1] * 587 +
                      bytes[o + 2] * 114) /
                  1000;
              minL = math.min(minL, l);
              maxL = math.max(maxL, l);
              sum += l;
              n++;
            }
          }
          final mean = sum / n;
          // ignore: avoid_print
          print('$tag  albedo=${albedo.toStringAsFixed(0)} '
              'mean=${mean.toStringAsFixed(0)} '
              '(${(mean - albedo).toStringAsFixed(0)}) '
              'min=${minL.toStringAsFixed(0)} '
              '(${(minL - albedo).toStringAsFixed(0)}) '
              'max=${maxL.toStringAsFixed(0)} '
              '(${(maxL - albedo).toStringAsFixed(0)})');
        }
      }
    }
  });
}
