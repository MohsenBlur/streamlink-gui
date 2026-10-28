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
  group('a request that races a material switch still gets its tile', () {
    testWidgets('a requester that arrives after an eviction is not stranded',
        (tester) async {
      // The sequence that used to lose a surface permanently:
      //
      //   1. A requests the tile; generation 0 starts.
      //   2. the material changes; evictAll bumps to generation 1.
      //   3. B requests the SAME tile. `request` sees a list in flight and
      //      appends to it, starting nothing of its own.
      //   4. generation 0 completes, sees it is stale, and threw the list away
      //      - B with it. No generation running, no callback owed to anyone.
      //
      // B's surface then paints with no grain until something unrelated
      // repaints it, which on an idle window is never. This is not reachable
      // by looking at a screenshot: the surface renders, it just renders as
      // the untextured fallback, which is a legitimate frame in every other
      // circumstance.
      const key = TileKey(
          kind: TextureKind.brushed,
          width: 32,
          height: 32,
          amplitude: 3,
          seed: 7);

      var second = 0;
      await tester.runAsync(() async {
        TextureCache.evictAll();
        TextureCache.request(key, () {});
        TextureCache.evictAll();
        TextureCache.request(key, () => second++);

        // Long enough for both the stale generation and its restart to land.
        for (var i = 0; i < 40 && second == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });

      expect(second, 1,
          reason: 'the requester that arrived after the eviction was never '
              'told its tile had landed, so its surface will paint untextured '
              'until something unrelated repaints it');
      expect(TextureCache.residentCount, greaterThan(0),
          reason: 'and no tile was ever produced for it');
    });
  });

  group('a tile that fails to generate', () {
    // Generation used to have no error path at all: a failed upload left its
    // key "in flight" forever, nothing retried, the grain never appeared, and
    // every later paint that missed appended another closure to a queue no
    // one would drain. These stage the failure through the generation seam,
    // under fake time, so the backoff is walked rather than slept through.
    ui.Image standIn() {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 1, 1),
          Paint()..color = const Color(0xFF000000));
      return rec.endRecording().toImageSync(1, 1);
    }

    testWidgets('retries on the backoff and serves its waiter when it lands',
        (tester) async {
      addTearDown(() => TextureCache.debugGenerateOverride = null);
      const key = TileKey(
          kind: TextureKind.speckle,
          width: 8,
          height: 8,
          amplitude: 2,
          seed: 0xFA11);
      final image = standIn();
      var attempts = 0;
      TextureCache.debugGenerateOverride = (_) async {
        attempts++;
        if (attempts <= 2) throw StateError('device lost mid-upload');
        return image;
      };

      var served = 0;
      void onReady() => served++;
      TextureCache.request(key, onReady);
      await tester.pump();
      expect(attempts, 1);
      expect(served, 0);

      // The surface keeps repainting through the wait. It must join the queue
      // it is already in - not start a parallel attempt, not queue again.
      TextureCache.request(key, onReady);
      expect(TextureCache.waitingCount(key), 1);

      await tester.pump(TextureCache.retryDelays[0]);
      expect(attempts, 2, reason: 'the first retry never ran');
      await tester.pump(TextureCache.retryDelays[1]);
      expect(attempts, 3, reason: 'the second retry never ran');

      expect(served, 1,
          reason: 'the tile landed on the third attempt, and the surface '
              'waiting on it is owed exactly one repaint');
      expect(TextureCache.lookup(key), same(image));
      expect(TextureCache.waitingCount(key), 0);

      TextureCache.evictAll();
      await tester.pump();
    });

    testWidgets('gives up after its retries, releases the queue, and waits '
        'for the next material', (tester) async {
      addTearDown(() => TextureCache.debugGenerateOverride = null);
      const key = TileKey(
          kind: TextureKind.speckle,
          width: 8,
          height: 8,
          amplitude: 2,
          seed: 0xDEAD);
      var attempts = 0;
      TextureCache.debugGenerateOverride = (_) async {
        attempts++;
        throw StateError('no GPU');
      };

      TextureCache.request(key, () {});
      await tester.pump();
      for (final delay in TextureCache.retryDelays) {
        await tester.pump(delay);
      }
      final budget = TextureCache.retryDelays.length + 1;
      expect(attempts, budget);
      expect(TextureCache.waitingCount(key), 0,
          reason: 'an abandoned tile must release everyone queued on it, or '
              'their painters stay reachable from a static for the session');

      // Every later paint of every surface wanting it: no queue, no restart.
      for (var i = 0; i < 50; i++) {
        TextureCache.request(key, () {});
      }
      await tester.pump(const Duration(seconds: 30));
      expect(attempts, budget,
          reason: 'paints restarted a generation that already ran out of '
              'retries - one attempt per frame on a broken device');
      expect(TextureCache.waitingCount(key), 0,
          reason: 'requests for an abandoned tile are queuing again');

      // A material switch is a new chance, with a fresh budget.
      TextureCache.evictAll();
      TextureCache.request(key, () {});
      await tester.pump();
      expect(attempts, budget + 1);
      for (final delay in TextureCache.retryDelays) {
        await tester.pump(delay);
      }
      expect(attempts, budget * 2);
    });

    testWidgets('a surface repainting while its tile is in flight queues once, '
        'and leaves the queue when it is torn down', (tester) async {
      addTearDown(() => TextureCache.debugGenerateOverride = null);
      // Through the REAL painter: the queue is only bounded if the painter
      // hands the cache the same callback on every paint and withdraws it on
      // dispose. Both used to pass a fresh closure per paint.
      final inFlight = Completer<ui.Image>();
      TextureCache.debugGenerateOverride = (_) => inFlight.future;
      TextureCache.evictAll(); // in case an earlier test left it resident
      await tester.pump();

      final rack = MaterialSpec.of(AppMaterial.rack).palette(true);
      final spec = rack.texture!;
      final key = TileKey(
        kind: spec.kind,
        width: spec.tileDevicePx.width.round(),
        height: spec.tileDevicePx.height.round(),
        amplitude: spec.amplitudeFor(SurfaceRole.panel),
        seed: spec.seed,
      );
      final d = SkeuoDecoration.role(
        palette: rack,
        role: SurfaceRole.panel,
        depth: NeuElevation.d2,
        radius: NeuRadius.r12,
      );
      expect(d.rendersLit, isFalse,
          reason: 'precondition: the Canvas painter, whose layer 3 asks for '
              'this tile');

      void paintInto(BoxPainter painter) {
        final rec = ui.PictureRecorder();
        painter.paint(Canvas(rec), Offset.zero,
            const ImageConfiguration(size: Size(120, 120), devicePixelRatio: 1));
        rec.endRecording().dispose();
      }

      final hovered = d.createBoxPainter(() {});
      for (var i = 0; i < 50; i++) {
        paintInto(hovered);
      }
      expect(TextureCache.waitingCount(key), 1,
          reason: 'fifty paints of one surface queued '
              '${TextureCache.waitingCount(key)} callbacks');

      final sibling = d.createBoxPainter(() {});
      paintInto(sibling);
      expect(TextureCache.waitingCount(key), 2);

      hovered.dispose();
      sibling.dispose();
      expect(TextureCache.waitingCount(key), 0,
          reason: 'a torn-down surface left its callback in the static queue');

      // Land it so nothing is left in flight for the tests after this one.
      inFlight.complete(standIn());
      await tester.pump();
      expect(TextureCache.lookup(key), isNotNull);
      TextureCache.evictAll();
      await tester.pump();
    });
  });

  testWidgets('a paint-time miss never runs the pixel loops on the UI isolate',
      (tester) async {
    // `request` is called from paint(). Generation used to run its w*h*4
    // pixel loops synchronously inside it, so the "asynchronous" cache put
    // the work on exactly the frame it claimed to spare - the first frame,
    // and every frame after a material switch.
    //
    // Asserted through the per-isolate pass counter rather than a stopwatch:
    // the loops must not run during the call (synchronous in paint) and must
    // not run here later either (a microtask or Timer deferral would only
    // move the same work onto the next frame's UI thread).
    const key = TileKey(
        kind: TextureKind.brushed,
        width: 96,
        height: 48,
        amplitude: 4,
        seed: 0xA11CE);
    TextureCache.debugPixelPassesOnThisIsolate = 0;

    var landed = false;
    await tester.runAsync(() async {
      TextureCache.request(key, () => landed = true);
      expect(TextureCache.debugPixelPassesOnThisIsolate, 0,
          reason: 'request() generated the tile synchronously - inside the '
              'paint call that missed');
      for (var i = 0; i < 80 && !landed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });

    expect(landed, isTrue, reason: 'the tile never arrived');
    expect(TextureCache.lookup(key), isNotNull);
    expect(TextureCache.debugPixelPassesOnThisIsolate, 0,
        reason: 'the pixel loops ran on the UI isolate after all - off the '
            'paint call, but still on the thread that paints the next frame');
  });

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
