import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_progress.dart';

/// Renders every meter style at several values into one strip, because the
/// meters only appear in the app during an active download and a calibration
/// eye needs them on demand.
void main() {
  test('render meter styles', () async {
    const w = 320.0, h = 9.0;
    const pad = 16.0;
    final rows = <(MeterStyle, String, Color, Color?)>[
      (MeterStyle.slot, 'slot (soft)', Color(0xFF35B6C8), null),
      (MeterStyle.ledSegments, 'led (rack)', Color(0xFF35B6C8), null),
      (MeterStyle.needle, 'needle (analogue)', Color(0xFF35B6C8),
          Color(0xFFB08D57)),
      (MeterStyle.vfdSegments, 'vfd (deck)', Color(0xFFA5F2E3), null),
    ];
    const values = [0.25, 0.65, 0.92];

    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final totalW = pad * 2 + values.length * (w + pad);
    final totalH = pad + rows.length * (h + pad * 1.6);
    canvas.drawRect(Rect.fromLTWH(0, 0, totalW, totalH),
        Paint()..color = const Color(0xFF23201D));

    for (var r = 0; r < rows.length; r++) {
      final (style, _, fill, metal) = rows[r];
      for (var v = 0; v < values.length; v++) {
        final x = pad + v * (w + pad);
        final y = pad + r * (h + pad * 1.6);
        canvas.save();
        canvas.translate(x, y);
        MeterPainter(
          value: values[v],
          fill: fill,
          track: const Color(0xFF17150F),
          radius: 2,
          slotted: true,
          shade: const Color(0x59000000),
          light: const Color(0x30FFE8C4),
          style: style,
          metal: metal,
        ).paint(canvas, const Size(w, h));
        canvas.restore();
      }
    }
    final img = await rec
        .endRecording()
        .toImage(totalW.toInt(), totalH.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File('shots/material/meters.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    img.dispose();
  });
}
