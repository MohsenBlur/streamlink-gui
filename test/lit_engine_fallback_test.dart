import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/lit_surface.dart';
import 'package:streamlink_gui/theme/material/skeuo_decoration.dart';

/// The lit engine's fallbacks past the load step, and its kill switch.
///
/// The load-time fallback was the only one: Skia accepts the SkSL front end at
/// load and compiles the GPU backend lazily at the first draw, and a failure
/// there drops the draw - every lit surface paints nothing - with no probe and
/// no switch to flip. These pin the self-test that catches it, the switch that
/// covers what it cannot (the software rasteriser renders the shader
/// correctly, just on the CPU), and the runtime hand-over to Canvas.
///
/// A file of its own because every test here moves the engine's process-wide
/// state, and test files are isolates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => LitSurfaceProgram.debugRasterizeOverride = null);

  /// What a GPU that drops the lit draw reads back: the self-test's control
  /// patch (the left half) rendered, the lit surface (the right half) not.
  Future<ui.Image> litDrawDropped(ui.Picture picture, int w, int h) async {
    final full = await picture.toImage(w, h);
    final rec = ui.PictureRecorder();
    final half = Rect.fromLTWH(0, 0, w / 2, h.toDouble());
    Canvas(rec).drawImageRect(full, half, half, Paint());
    full.dispose();
    return rec.endRecording().toImage(w, h);
  }

  /// A minimal lit material with no grain, so a painted surface is fully
  /// deterministic: nothing waits on a tile.
  MaterialPalette litPalette() => MaterialPalette(
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
        lit: const LitSpec(
          f0: Color(0xFFE8EAEC),
          metalness: 0.9,
          anisotropy: 0.85,
          sky: Color(0xFF9FA8B8),
          ground: Color(0xFF0D0E11),
        ),
      );

  SkeuoDecoration raised() => SkeuoDecoration.role(
        palette: litPalette(),
        role: SurfaceRole.raised,
        depth: 3,
        radius: 12,
      );

  group('the self-test', () {
    test('a shader that renders passes, with a margin, and stays lit',
        () async {
      // The vacuous-pass guard: a self-test whose threshold the real shader
      // only scrapes past would flip working machines to Canvas on a tuning
      // change. Read the same pixels the probe reads and hold them well clear.
      ByteData? seen;
      LitSurfaceProgram.debugRasterizeOverride = (picture, w, h) async {
        final image = await picture.toImage(w, h);
        seen = await image.toByteData();
        return image;
      };
      await LitSurfaceProgram.load();

      expect(LitSurfaceProgram.ready, isTrue,
          reason: 'the self-test failed a shader that renders: '
              '${LitSurfaceProgram.status}');
      expect(LitSurfaceProgram.status, 'lit engine');
      expect(seen, isNotNull, reason: 'the self-test never read anything back');
      // The probe surface's centre: offset (36, 4) plus half of 24x24.
      final o = (16 * 64 + 48) * 4;
      final face = [for (var c = 0; c < 4; c++) seen!.getUint8(o + c)];
      expect(face[3], 255, reason: 'the lit face is not opaque: $face');
      expect(face.take(3).reduce((a, b) => a > b ? a : b), greaterThan(48),
          reason: 'the lit face reads back $face - too close to the '
              'self-test\'s "drew nothing" threshold of 16');
    });

    test('a GPU that drops the lit draw switches to Canvas', () async {
      LitSurfaceProgram.debugRasterizeOverride = litDrawDropped;
      await LitSurfaceProgram.load();

      expect(LitSurfaceProgram.ready, isFalse,
          reason: 'the lit surface read back blank while the control patch '
              'rendered, and the engine stayed lit - every chassis, card and '
              'button would paint nothing');
      expect(LitSurfaceProgram.status, contains('drew nothing'));
      expect(raised().rendersLit, isFalse,
          reason: 'new surfaces must route to the Canvas engine');
    });

    test('a readback that is itself broken keeps the lit engine', () async {
      // Control AND surface blank: the readback is what failed, and it says
      // nothing about the shader. Falling back on that would trade a working
      // engine for nothing.
      LitSurfaceProgram.debugRasterizeOverride = (picture, w, h) async {
        final rec = ui.PictureRecorder();
        Canvas(rec);
        return rec.endRecording().toImage(w, h);
      };
      await LitSurfaceProgram.load();
      expect(LitSurfaceProgram.ready, isTrue);

      LitSurfaceProgram.debugRasterizeOverride =
          (picture, w, h) async => throw StateError('context lost');
      await LitSurfaceProgram.load();
      expect(LitSurfaceProgram.ready, isTrue,
          reason: 'a readback that threw is not evidence against the shader');
    });

    test('an overrunning self-test does not hold the launch, and still falls '
        'back when it finally fails', () async {
      final slow = Completer<void>();
      LitSurfaceProgram.debugRasterizeOverride = (picture, w, h) async {
        await slow.future;
        return litDrawDropped(picture, w, h);
      };
      await LitSurfaceProgram.load(
          probeBudget: const Duration(milliseconds: 20));
      expect(LitSurfaceProgram.ready, isTrue,
          reason: 'slow is not broken: an overrun must keep the lit engine');

      slow.complete();
      for (var i = 0; i < 40 && LitSurfaceProgram.ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(LitSurfaceProgram.ready, isFalse,
          reason: 'the late verdict was a failure and nothing acted on it');
    });
  });

  group('the kill switch', () {
    test('the environment variable forces Canvas before anything loads',
        () async {
      for (final on in ['1', 'true', 'YES', ' on ']) {
        await LitSurfaceProgram.load(environment: {
          LitSurfaceProgram.canvasEnvironmentVariable: on,
        });
        expect(LitSurfaceProgram.ready, isFalse, reason: '"$on" is on');
        expect(LitSurfaceProgram.status,
            contains(LitSurfaceProgram.canvasEnvironmentVariable));
      }
      for (final off in ['0', 'false', '', 'no']) {
        await LitSurfaceProgram.load(environment: {
          LitSurfaceProgram.canvasEnvironmentVariable: off,
        });
        expect(LitSurfaceProgram.ready, isTrue, reason: '"$off" is off');
      }
    });

    test('the caller can force Canvas', () async {
      await LitSurfaceProgram.load(forceCanvas: true, environment: const {});
      expect(LitSurfaceProgram.ready, isFalse);
      expect(LitSurfaceProgram.status, contains('forced'));
      expect(raised().rendersLit, isFalse);
    });

    test('the status names which switch forced it', () async {
      // Every forced start read "requested at launch", whether the Settings
      // switch or the command-line flag did it.
      await LitSurfaceProgram.load(
          forceCanvas: true,
          forceCanvasReason: 'Simple rendering setting',
          environment: const {});
      expect(LitSurfaceProgram.status,
          'Canvas engine (forced: Simple rendering setting)');

      await LitSurfaceProgram.load(
          forceCanvas: true,
          forceCanvasReason: '--canvas-engine flag',
          environment: {LitSurfaceProgram.canvasEnvironmentVariable: '1'});
      expect(LitSurfaceProgram.status,
          'Canvas engine (forced: --canvas-engine flag)',
          reason: "the caller's reason, not the variable it also has set");

      await LitSurfaceProgram.load(
          environment: {LitSurfaceProgram.canvasEnvironmentVariable: '1'});
      expect(LitSurfaceProgram.status,
          'Canvas engine (forced: ${LitSurfaceProgram.canvasEnvironmentVariable} is set)');
    });
  });

  test('a disposed lit painter leaves the engine switch\'s registry',
      () async {
    // The registry is a static set of each lit box's markNeedsPaint. A painter
    // that stayed in it after its box went (a VOD card scrolled away, a
    // decoration that changed) would keep that render object reachable for
    // the whole session and be called on a box that no longer paints.
    await LitSurfaceProgram.load(environment: const {});
    expect(LitSurfaceProgram.ready, isTrue, reason: 'precondition');

    var kept = 0, dropped = 0;
    final live = raised().createBoxPainter(() => kept++);
    raised().createBoxPainter(() => dropped++).dispose();

    LitSurfaceProgram.disable('switched off by the test');
    expect(kept, 1, reason: 'a live lit box was not told about the switch');
    expect(dropped, 0,
        reason: 'a disposed painter is still registered for engine switches');
    live.dispose();
  });

  testWidgets('a surface already painted lit repaints through Canvas when '
      'the engine is switched off under it', (tester) async {
    // The painter is built once per decoration and kept while the decoration
    // compares equal, so a runtime switch rebuilds nothing. Before this, the
    // lit painter would dereference the vanished program on its next paint,
    // and no paint was coming anyway: the surface kept its last (possibly
    // blank) picture until something unrelated repainted it.
    await tester.runAsync(() => LitSurfaceProgram.load(environment: const {}));
    expect(LitSurfaceProgram.ready, isTrue, reason: 'precondition');

    final boundary = GlobalKey();
    Widget surface(Key key) => Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: boundary,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: DecoratedBox(
                  key: key,
                  decoration: raised(),
                  child: const SizedBox(width: 160, height: 80),
                ),
              ),
            ),
          ),
        );

    Future<Uint8List> capture() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await render.toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!.buffer.asUint8List();
      });
      return bytes!;
    }

    await tester.pumpWidget(surface(const ValueKey('built lit')));
    final lit = await capture();

    LitSurfaceProgram.disable('switched off by the test');
    final box = tester.renderObject(find.byKey(const ValueKey('built lit')));
    expect(box.debugNeedsPaint, isTrue,
        reason: 'the switch did not ask the lit-painted box to repaint');
    await tester.pump();
    expect(tester.takeException(), isNull);
    final handedOver = await capture();

    // A box built from scratch after the switch: the Canvas painter itself.
    await tester.pumpWidget(surface(const ValueKey('built canvas')));
    final canvas = await capture();

    expect(handedOver, isNot(equals(lit)),
        reason: 'precondition: the two engines must paint differently, or '
            'this comparison proves nothing');
    expect(handedOver, equals(canvas),
        reason: 'the surface built lit did not repaint as the Canvas engine '
            'paints it');
  });
}
