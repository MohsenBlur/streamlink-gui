import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/lit_surface.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';

/// The lit-surface routing and its end-to-end paint.
///
/// Two failure modes need pinning, and neither is visible in a screenshot:
///
///  * a wrong `rendersLit` branch still paints *something* plausible through
///    the other engine, so a material can silently lose its lighting - or
///    worse, `Soft` can silently gain some;
///  * a drifted uniform write still renders - SkSL uniforms are positional,
///    so writing one value out of order shifts everything after it and the
///    surface becomes abstract art with valid alpha.
///
/// So the routing is asserted directly, and the painted output is asserted on
/// the same physical properties `shader_surface_test` uses, but through the
/// REAL `createBoxPainter` path: factory -> params -> painter -> uniforms.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lit = LitSpec(
    f0: Color(0xFFE8EAEC),
    metalness: 0.9,
    anisotropy: 0.85,
    grainAmp: 0.14,
    sky: Color(0xFF9FA8B8),
    ground: Color(0xFF0D0E11),
  );

  /// A minimal material that declares a lit model. Synthetic on purpose: no
  /// shipped material is lit yet, and this test must not depend on which
  /// ones become so.
  MaterialPalette palette({LitSpec? spec}) => MaterialPalette(
        canvas: const Color(0xFF16181C),
        surface: const Color(0xFF2A2E35),
        well: const Color(0xFF171A1F),
        screen: const Color(0xFF0C0F13),
        text: const Color(0xFFE8EBEF),
        subtext: const Color(0xFFB9C3D2),
        border: const Color(0xFF737A88),
        highlight: const Color(0xFF3A404A),
        shadow: const Color(0xFF0B0E13),
        disabledText: const Color(0xFF8F99A8),
        lightAzimuthDeg: 90,
        fill: const [
          (at: 0.0, dh: 0.0, ds: 0.0, dl: 0.0),
          (at: 1.0, dh: 0.0, ds: 0.0, dl: -0.02),
        ],
        bevelLight: const Color(0x1FFFFFFF),
        bevelShade: const Color(0x59000000),
        contact: const [
          ShadowLayer(color: Color(0x8C0B0E13), dx: 0, dy: 1, blur: 1),
        ],
        lit: spec,
      );

  SkeuoDecoration deco(SurfaceRole role,
          {LitSpec? spec = lit, Gradient? gradient}) =>
      SkeuoDecoration.role(
        palette: palette(spec: spec),
        role: role,
        depth: 3,
        radius: 12,
        gradient: gradient,
      );

  group('routing', () {
    setUpAll(() async {
      await LitSurfaceProgram.load();
    });

    test('a lit material routes raised, panel and sunken to the shader', () {
      expect(LitSurfaceProgram.ready, isTrue,
          reason: 'the program must load inside flutter test - the probe '
              'commit established that it does');
      for (final role in [
        SurfaceRole.raised,
        SurfaceRole.panel,
        SurfaceRole.sunken,
        SurfaceRole.well,
        SurfaceRole.screen,
      ]) {
        expect(deco(role).rendersLit, isTrue, reason: '$role should be lit');
      }
    });

    test('flat never routes to the shader', () {
      // A flat surface is a fill, not an object; it has no edge, no shadow
      // and no thickness for the shader to model.
      expect(deco(SurfaceRole.flat).rendersLit, isFalse);
    });

    test('a material without a lit model never routes to the shader', () {
      expect(deco(SurfaceRole.raised, spec: null).rendersLit, isFalse);
    });

    test('a caller gradient forces the Canvas path', () {
      // The rainbow live border replaces the fill, and the shader has no slot
      // for an arbitrary gradient - nor should it grow one.
      expect(
          deco(SurfaceRole.raised,
                  gradient: const LinearGradient(
                      colors: [Colors.red, Colors.blue]))
              .rendersLit,
          isFalse);
    });

    test('an unloaded program forces the Canvas path', () {
      LitSurfaceProgram.reset();
      expect(deco(SurfaceRole.raised).rendersLit, isFalse,
          reason: 'with no program, every surface must fall back to the '
              'seven-layer engine rather than paint nothing');
      // Restore for the groups below - setUpAll only runs once per group.
    });
  });

  group('painted output', () {
    setUpAll(() async {
      await LitSurfaceProgram.load();
    });

    Future<ByteData> paint(Decoration d, Size size, {double inset = 30}) async {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final full = Size(size.width + 2 * inset, size.height + 2 * inset);
      canvas.drawRect(Offset.zero & full,
          Paint()..color = const Color(0xFF101216));
      final painter = d.createBoxPainter(() {});
      painter.paint(canvas, Offset(inset, inset),
          ImageConfiguration(size: size, devicePixelRatio: 1.0));
      painter.dispose();
      final img = await rec
          .endRecording()
          .toImage(full.width.round(), full.height.round());
      final bytes = (await img.toByteData())!;
      img.dispose();
      return bytes;
    }

    int lum(ByteData b, int stride, int x, int y) {
      final o = (y * stride + x) * 4;
      return ((b.getUint8(o) * 299 +
                  b.getUint8(o + 1) * 587 +
                  b.getUint8(o + 2) * 114) ~/
          1000);
    }

    const size = Size(200, 100);
    const stride = 260; // 200 + 2*30
    const inset = 30;

    test('the raised surface is lit: directional edge, shaded face', () async {
      final b = await paint(deco(SurfaceRole.raised), size);
      final x = inset + 100;
      final top = lum(b, stride, x, inset + 1);
      final face = lum(b, stride, x, inset + 50);
      final bottomLand = lum(b, stride, x, inset + 97);
      expect(top, greaterThan(face + 5),
          reason: 'the chamfer facing the light must beat the face '
              '(top=$top face=$face) - if this fails while '
              'shader_surface_test passes, the painter is writing uniforms '
              'out of order');
      expect(bottomLand, lessThan(face),
          reason: 'the chamfer facing away must fall below the face '
              '(bottom=$bottomLand face=$face)');
    });

    test('the raised surface casts below itself; the sunken one does not',
        () async {
      final raised = await paint(deco(SurfaceRole.raised), size);
      final sunken = await paint(deco(SurfaceRole.sunken), size);
      // On the dark ground, a shadow only darkens - compare against the
      // ground away from the shape.
      final groundLum = lum(raised, stride, 5, 5);
      final belowRaised = lum(raised, stride, inset + 100, inset + 105);
      final belowSunken = lum(sunken, stride, inset + 100, inset + 105);
      expect(belowRaised, lessThan(groundLum),
          reason: 'a proud surface must darken the ground under its edge '
              '(below=$belowRaised ground=$groundLum)');
      expect(belowSunken, greaterThanOrEqualTo(belowRaised),
          reason: 'a recess must not cast an outward shadow');
    });

    test('the recess inverts the edge lighting', () async {
      final raised = await paint(deco(SurfaceRole.raised), size);
      final sunken = await paint(deco(SurfaceRole.sunken), size);
      int grad(ByteData b) =>
          lum(b, stride, inset + 100, inset + 2) -
          lum(b, stride, inset + 100, inset + 97);
      expect(grad(raised), greaterThan(0));
      expect(grad(sunken), lessThan(grad(raised)),
          reason: 'a recess must light the opposite wall from a boss');
    });

    test('a caller border still paints, over the shader output', () async {
      final withBorder = await paint(
          SkeuoDecoration.role(
            palette: palette(spec: lit),
            role: SurfaceRole.raised,
            depth: 3,
            radius: 12,
            border: Border.all(color: const Color(0xFFFF0000), width: 2),
          ),
          size);
      // The top edge must be red-dominant: the ring wins over the material.
      final o = ((inset + 1) * stride + inset + 100) * 4;
      final r = withBorder.getUint8(o), g = withBorder.getUint8(o + 1);
      expect(r, greaterThan(g + 60),
          reason: 'the selection ring must paint over the lit surface');
    });
  });

  group('interpolation and identity', () {
    test('lit params interpolate; the checkbox tween crosses roles smoothly',
        () {
      final a = deco(SurfaceRole.raised);
      final b = deco(SurfaceRole.sunken);
      final mid = SurfaceParams.lerp(a.params, b.params, 0.5);
      expect(mid.litRecess, 0.5,
          reason: 'recess must tween, not switch - this is the checkbox');
      expect(mid.litShadow, closeTo(0.5, 1e-9),
          reason: 'the cast must fade out on the way down');
      expect(mid.lit, isNotNull);
    });

    test('lit-to-unlit snaps at the midpoint, like Decoration.lerp', () {
      final a = deco(SurfaceRole.raised);
      final b = deco(SurfaceRole.raised, spec: null);
      expect(SurfaceParams.lerp(a.params, b.params, 0.25).lit, isNotNull);
      expect(SurfaceParams.lerp(a.params, b.params, 0.75).lit, isNull);
    });

    test('== sees the lit model', () {
      // A missed field here restarts every tween on the widget and destroys
      // the painter each rebuild - the same defect the fill comparison fixed.
      expect(deco(SurfaceRole.raised), deco(SurfaceRole.raised));
      expect(
          deco(SurfaceRole.raised) ==
              deco(SurfaceRole.raised,
                  spec: const LitSpec(
                    f0: Color(0xFFE8EAEC),
                    metalness: 0.9,
                    anisotropy: 0.85,
                    grainAmp: 0.14,
                    sky: Color(0xFF9FA8B8),
                    ground: Color(0xFF0D0E11),
                    roughness: 0.5,
                  )),
          isFalse,
          reason: 'a different roughness is a different material');
    });

    test('scaled() fades the lit surface rather than popping it', () {
      final p = deco(SurfaceRole.raised).params.scaled(0.3);
      expect(p.litOpacity, closeTo(0.3, 1e-9));
      expect(p.litShadow, closeTo(0.3, 1e-9));
    });
  });

  group('every shipped material stays honestly declared', () {
    test('Soft has no lit model, in either brightness', () {
      // The fidelity gate proves Soft paints the v1.6.0 recipe; this proves
      // nothing can quietly route it away from that recipe.
      for (final isDark in [false, true]) {
        expect(softSpec.palette(isDark).lit, isNull,
            reason: 'a lit Soft would be a different material wearing the '
                'classic name');
      }
    });
  });
}
