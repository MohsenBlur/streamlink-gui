import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';

/// Renders Soft's roles to `shots/material/soft-*.png`, for the dark-depth
/// tuning loop. Same harness shape as render_material_preview, which skips
/// unlit materials.
void main() {
  test('render', () async {
    for (final isDark in [true, false]) {
      final p = softSpec.palette(isDark);
      final mode = isDark ? 'dark' : 'light';
      for (final (role, size, depth) in [
        (SurfaceRole.raised, const Size(220, 110), 5.0),
        (SurfaceRole.raised, const Size(120, 34), 3.0),
        (SurfaceRole.sunken, const Size(220, 110), 3.0),
      ]) {
        const inset = 30.0;
        final d = SkeuoDecoration.role(
            palette: p, role: role, depth: depth, radius: 12);
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
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        File('shots/material/soft-$mode-${role.name}-${size.width.toInt()}.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!.buffer.asUint8List());
      }
    }
  });
}
