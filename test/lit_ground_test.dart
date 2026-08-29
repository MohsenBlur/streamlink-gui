import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/lit_surface.dart';
import 'package:streamlink_gui/theme/material/texture_cache.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';

/// The lit model's honesty gate: a declared bound may never understate paint.
///
/// The shader replaces the fill stops, so `worstGround` cannot derive the
/// painted extremes from the palette - a shading equation with a tone map is
/// not invertible in closed form. Instead each `LitSpec` DECLARES how far the
/// lighting may move a face from its albedo (`faceLiftLevels` /
/// `faceDropLevels`), the whole contrast matrix trusts the declaration, and
/// this test is why the trust is warranted: every lit role of every shipped
/// material is rasterised through the real painter, and a measurement past
/// the declaration is a failure here rather than an invisible WCAG failure in
/// the app.
///
/// Ground convention, same as the engine's own §3a discipline: deflate to the
/// content rect (8px - where text can actually land, past the chamfer), then
/// box-blur the luminance 2px, because a glyph stem is 1-2px wide and its
/// operative ground is the local mean; per-texel extremes over a grain field
/// would force the grain to zero without making any letter harder to read.
void main() {
  setUpAll(() async {
    await LitSurfaceProgram.load();
    // The lit painter composites the hairline tile; measuring before it
    // lands would race the async generation and make later measurements in
    // the same run see grain that earlier ones did not. Prime every tile a
    // shipped material can ask for.
    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final t = spec.palette(isDark).texture;
        if (t == null) continue;
        for (final role in SurfaceRole.values) {
          final amp = t.amplitudeFor(role);
          if (amp <= 0 || RoleModifier.of(role).textureScale <= 0) continue;
          await TextureCache.prime(TileKey(
            kind: t.kind,
            width: t.tileDevicePx.width.round(),
            height: t.tileDevicePx.height.round(),
            amplitude: (amp * RoleModifier.of(role).textureScale).round(),
            seed: t.seed,
          ));
          // The full-range twin the lit path samples as its micro-normal.
          await TextureCache.prime(TileKey(
            kind: t.kind,
            width: t.tileDevicePx.width.round(),
            height: t.tileDevicePx.height.round(),
            amplitude: 255,
            seed: t.seed,
          ));
        }
      }
    }
  });

  Future<({double lift, double drop})> measure(
      MaterialPalette p, SurfaceRole role, double depth,
      {Size size = const Size(220, 110)}) async {
    const inset = 30.0;
    final d = SkeuoDecoration.role(
      palette: p,
      role: role,
      depth: depth,
      radius: 12,
    );
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

    // 2px box blur over the content rect, then extremes.
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

  test('every lit role of every material paints inside its declared bounds',
      () async {
    var measured = 0;
    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final p = spec.palette(isDark);
        if (p.lit == null) continue;
        final mode = isDark ? 'dark' : 'light';

        for (final (role, depths) in [
          (SurfaceRole.panel, const [2.0, 3.0]),
          (SurfaceRole.raised, const [2.0, 3.0, 5.0]),
          (SurfaceRole.sunken, const [3.0]),
          (SurfaceRole.well, const [1.0]),
          (SurfaceRole.screen, const [2.0]),
        ]) {
          final litSpec = p.litFor(role)!;
          // The same split worstGround applies: recessed roles measure
          // against their own declared bounds.
          final recessed = RoleModifier.of(role).insetScale > 0;
          final liftBound = recessed
              ? litSpec.recessLiftLevels
              : litSpec.faceLiftLevels;
          final dropBound = recessed
              ? litSpec.recessDropLevels
              : litSpec.faceDropLevels;
          for (final depth in depths) {
            final m = await measure(p, role, depth);
            measured++;
            expect(m.lift, lessThanOrEqualTo(liftBound + 0.5),
                reason: '${spec.id.key} $mode ${role.name} d$depth painted '
                    '${m.lift.toStringAsFixed(1)} levels above its albedo, '
                    'but declares a lift bound of $liftBound - the contrast '
                    'matrix is trusting a lie. Raise the declaration (and '
                    'let the inks re-derive) or dim the material.');
            expect(m.drop, lessThanOrEqualTo(dropBound + 0.5),
                reason: '${spec.id.key} $mode ${role.name} d$depth painted '
                    '${m.drop.toStringAsFixed(1)} levels below its albedo, '
                    'but declares a drop bound of $dropBound');
          }
        }

        // The pillow policy: small parts take a wider fillet and more dome,
        // so a chip's face moves further than a card's. The bounds must hold
        // at chip scale too, where the content rect sits almost entirely on
        // the domed region.
        final chip =
            await measure(p, SurfaceRole.raised, 2, size: const Size(120, 34));
        measured++;
        final chipSpec = p.litFor(SurfaceRole.raised)!;
        expect(chip.lift, lessThanOrEqualTo(chipSpec.faceLiftLevels + 0.5),
            reason: '${spec.id.key} $mode raised at chip size painted '
                '${chip.lift.toStringAsFixed(1)} levels above its albedo, '
                'past the declared ${chipSpec.faceLiftLevels}');
        expect(chip.drop, lessThanOrEqualTo(chipSpec.faceDropLevels + 0.5),
            reason: '${spec.id.key} $mode raised at chip size painted '
                '${chip.drop.toStringAsFixed(1)} levels below its albedo, '
                'past the declared ${chipSpec.faceDropLevels}');
      }
    }
    expect(measured, greaterThan(0),
        reason: 'no lit material was measured - if the last lit material was '
            'just removed, delete this test with it; if not, the loop is '
            'broken and the gate is decoration');
  });

  test('the declared bounds are not padded into meaninglessness', () async {
    // The bound feeds straight into every ink derivation: an over-declared
    // lift forces every light ink darker than the paint requires, which is
    // its own kind of dishonesty. Hold declarations within 12 levels of the
    // worst measurement so tuning keeps them true in both directions.
    for (final spec in MaterialSpec.available) {
      for (final isDark in [false, true]) {
        final p = spec.palette(isDark);
        if (p.lit == null) continue;

        // Keyed on (spec, bound-class) because the proud and recessed
        // bounds are separate declarations with separate worst cases.
        final worst = <(LitSpec, bool), double>{};
        for (final role in [
          SurfaceRole.panel,
          SurfaceRole.raised,
          SurfaceRole.sunken,
          SurfaceRole.well,
          SurfaceRole.screen,
        ]) {
          final litSpec = p.litFor(role)!;
          final recessed = RoleModifier.of(role).insetScale > 0;
          final m = await measure(p, role, 3.0);
          final k = (litSpec, recessed);
          worst[k] = math.max(worst[k] ?? 0, m.lift);
        }
        worst.forEach((k, worstLift) {
          final (litSpec, recessed) = k;
          final bound = recessed
              ? litSpec.recessLiftLevels
              : litSpec.faceLiftLevels;
          expect(bound - worstLift, lessThan(12),
              reason: '${spec.id.key} declares a '
                  '${recessed ? 'recess' : 'face'} lift bound of $bound but '
                  'never paints more than ${worstLift.toStringAsFixed(1)} - '
                  'the slack darkens every derived ink for nothing');
        });
      }
    }
  });
}
