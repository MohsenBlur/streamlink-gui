import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/widgets.dart';

import 'material_palette.dart';

/// Procedural surface grain, generated once and tiled forever.
///
/// ## Why the grain only ever lightens
///
/// A texture has to change the surface by an exact number of sRGB levels, or
/// the contrast matrix cannot state a worst texel and the whole thing becomes
/// unassertable. That rules out the obvious approach — a translucent grey tile
/// drawn `srcOver` — because compositing white at alpha `a` over a base gives
/// `base + a * (255 - base)`, which moves a dark ground five times as far as a
/// light one. An amplitude tuned in one brightness is wrong in the other, and
/// no single number fixes it.
///
/// So the tile carries the **positive deviation only** and composites with
/// [BlendMode.plus], which adds exactly: `result = dst + dev`, independent of
/// the ground and of the gradient underneath it. Three levels means three
/// levels everywhere.
///
/// This is also physically right rather than a workaround. The grain on a
/// brushed surface *is* specular highlight — the bright streaks where the
/// abrasive left a groove facing the light. Real brushed metal shows bright
/// streaks on a darker body, not dark scratches on a lighter one.
///
/// It makes the contrast question one-sided too, and in the safe direction: a
/// lighten-only texture reduces contrast for light ink on a dark ground (worst
/// texel `base + amplitude`, computable in closed form) and *increases* it for
/// dark ink on a light ground.
///
/// ## Generation is asynchronous, and the first paint has no texture
///
/// The window is shown from a frame callback and its first redraw is
/// unconditional, so "generate lazily on first paint" would put the work on
/// precisely the frame it meant to spare. Instead [lookup] returns null on a
/// miss, the painter skips layer 3, and the surface paints exactly as an
/// untextured material does. The miss enqueues generation, and completion
/// fires the painter's `onChanged` — the same mechanism `DecorationImage` uses
/// — which `RenderDecoratedBox` has already wired to `markNeedsPaint`. The
/// repaint is per-box and automatic; no call site learns about it.
///
/// "Asynchronous" has to mean off the paint call, not merely "returns a
/// Future": the miss is discovered inside paint(), so the pixel loops run on a
/// background isolate and the asking frame only enqueues them.
class TextureCache {
  TextureCache._();

  static final Map<TileKey, ui.Image> _tiles = <TileKey, ui.Image>{};

  /// Who is owed a repaint when each in-flight key lands.
  ///
  /// A SET, and the painters pass one stable callback each. It used to be a
  /// list fed a fresh closure on every paint that missed, so a surface that
  /// repainted while its tile was in flight - a hover, a resize drag, a
  /// spinner beside it - queued one closure per frame, each holding its
  /// painter alive, and a tile that never landed grew its list for the life
  /// of the process.
  static final Map<TileKey, Set<VoidCallback>> _waiting =
      <TileKey, Set<VoidCallback>>{};

  /// Bumped on eviction. A generation that finishes after its bump is dropped
  /// rather than inserted, so a material switch mid-generation cannot resurrect
  /// the previous material's grain.
  static int _generation = 0;

  /// Failed attempts per key, in the current generation.
  static final Map<TileKey, int> _failures = <TileKey, int>{};

  /// Keys whose retries ran out in the current generation.
  ///
  /// Requests for these are ignored until the next [evictAll], so a tile that
  /// cannot be made does not restart its generation from every paint of every
  /// surface that wants it.
  static final Set<TileKey> _abandoned = <TileKey>{};

  /// The wait before each retry of a failed tile, one entry per retry.
  ///
  /// Widening, because the failures worth retrying (a device-lost event, a
  /// transient allocation failure while the GPU resets) take a moment to
  /// clear, and capped at three because a fourth failure is not transient.
  @visibleForTesting
  static const List<Duration> retryDelays = <Duration>[
    Duration(milliseconds: 500),
    Duration(seconds: 2),
    Duration(seconds: 8),
  ];

  /// Stands in for generation, so a test can stage a failure. Null in the app.
  @visibleForTesting
  static Future<ui.Image> Function(TileKey key)? debugGenerateOverride;

  /// How many distinct callbacks are waiting on [key].
  @visibleForTesting
  static int waitingCount(TileKey key) => _waiting[key]?.length ?? 0;

  /// Resident tile, or null. Never blocks and never generates.
  static ui.Image? lookup(TileKey key) => _tiles[key];

  /// Requests [key], calling [onReady] once when it lands.
  ///
  /// Repeated requests for a key already in flight simply add a listener; the
  /// work happens once however many surfaces ask for it. Pass the SAME
  /// callback on every paint and it is registered once - and [cancel] it when
  /// the surface goes away.
  ///
  /// A key whose retries ran out is not attempted again until the next
  /// [evictAll]. The surface paints untextured, which is the frame every miss
  /// already paints.
  static void request(TileKey key, VoidCallback onReady) {
    if (_tiles.containsKey(key)) {
      onReady();
      return;
    }
    if (_abandoned.contains(key)) return;
    final waiting = _waiting[key];
    if (waiting != null) {
      waiting.add(onReady);
      return;
    }
    _waiting[key] = <VoidCallback>{onReady};
    _start(key);
  }

  /// Withdraws [onReady] from [key]'s queue: a surface torn down while its
  /// tile was in flight is owed nothing.
  ///
  /// An emptied queue is left in place on purpose. It marks the key as in
  /// flight, and removing it would let the next request start a second
  /// generation of the same tile alongside the first.
  static void cancel(TileKey key, VoidCallback onReady) {
    _waiting[key]?.remove(onReady);
  }

  /// Generates [key] for the CURRENT generation and serves whoever is waiting.
  ///
  /// Split out of [request] because of a race that leaves a surface permanently
  /// untextured. `request` appends to whatever queue is already in flight, and
  /// that queue survives a generation bump — so this sequence used to strand a
  /// live requester:
  ///
  ///   1. surface A requests a tile; generation 0 starts.
  ///   2. the user switches material; `evictAll` bumps to generation 1.
  ///   3. surface B requests the same tile. `request` sees a list in flight and
  ///      appends B's callback to it, starting nothing.
  ///   4. generation 0 finishes, notices it is stale, and dropped the whole
  ///      list — B included. Nobody is generating that tile and nobody will
  ///      tell B to repaint.
  ///
  /// B's surface then paints without grain until something unrelated happens to
  /// repaint it, which on an idle window is never. The fix is that a stale
  /// completion **restarts** for the current generation rather than discarding
  /// the queue: anyone still in the list asked after the bump and is owed a
  /// tile. The keys are content-addressed, so re-running is always safe.
  static void _start(TileKey key) {
    final generation = _generation;
    (debugGenerateOverride ?? _generate)(key).then((image) {
      if (generation != _generation) {
        image.dispose();
        _restartIfAwaited(key);
        return;
      }
      _failures.remove(key);
      _tiles[key] = image;
      final callbacks = _waiting.remove(key) ?? const <VoidCallback>{};
      for (final cb in callbacks) {
        cb();
      }
    }, onError: (Object error, StackTrace stack) {
      // A stale generation's failure says nothing about the current one, and
      // whoever is still queued asked after the bump: same restart as a stale
      // success.
      if (generation != _generation) {
        _restartIfAwaited(key);
        return;
      }
      _retryOrAbandon(key, error);
    });
  }

  /// Restarts [key] for the current generation if anybody is still waiting.
  ///
  /// `evictAll` does not clear the queue precisely so that this can serve
  /// them. A queue every requester has cancelled out of is simply forgotten.
  static void _restartIfAwaited(TileKey key) {
    if (_waiting[key]?.isNotEmpty ?? false) {
      _start(key);
    } else {
      _waiting.remove(key);
    }
  }

  /// A failed generation used to strand its key for the rest of the session.
  ///
  /// The chain had no error path, so the queue was never removed: nothing
  /// retried, the material's grain never appeared, and every later paint that
  /// missed appended to a queue nobody would ever drain. Now a failure retries
  /// on [retryDelays], waiters stay queued through the wait (a request during
  /// it joins the queue rather than starting a parallel attempt), and when
  /// the retries run out the queue is released and the key left alone until
  /// the next material switch.
  static void _retryOrAbandon(TileKey key, Object error) {
    final attempt = (_failures[key] ?? 0) + 1;
    _failures[key] = attempt;
    if (attempt > retryDelays.length) {
      _abandoned.add(key);
      _waiting.remove(key);
      debugPrint('texture tile $key failed $attempt times; '
          'painting without it: $error');
      return;
    }
    final delay = retryDelays[attempt - 1];
    debugPrint('texture tile $key failed; retry $attempt of '
        '${retryDelays.length} in ${delay.inMilliseconds}ms: $error');
    Timer(delay, () => _restartIfAwaited(key));
  }

  /// Drops every tile.
  ///
  /// Disposal is deferred by a frame because `ImageShader` asserts on a
  /// disposed image, and a painter built this frame may still hold a shader
  /// over one of these. Evicting under it would throw in debug.
  static void evictAll() {
    _generation++;
    // A new material is a new chance: a tile that failed under the previous
    // one may well succeed now, and its retry budget starts over.
    _failures.clear();
    _abandoned.clear();
    final doomed = _tiles.values.toList();
    _tiles.clear();
    // The queue is deliberately NOT cleared. Every entry in it is a live
    // surface waiting to be told to repaint, and dropping them is how one ends
    // up with no tile and no callback. The in-flight generation notices it is
    // stale and restarts for the new one; see `_start`.
    //
    // Re-generating a key that the new material happens not to want costs one
    // tile and no correctness: keys are content-addressed, so a tile is either
    // wanted by its key or ignored.
    if (doomed.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final image in doomed) {
        image.dispose();
      }
    });
  }

  /// Visible for tests: how many tiles are resident.
  @visibleForTesting
  static int get residentCount => _tiles.length;

  @visibleForTesting
  static Future<ui.Image> generateForTest(TileKey key) => _generate(key);

  /// Generates [key] and inserts it, for gates that must measure WITH the
  /// grain resident rather than racing its async arrival mid-run.
  @visibleForTesting
  static Future<void> prime(TileKey key) async {
    if (_tiles.containsKey(key)) return;
    _tiles[key] = await _generate(key);
  }

  static Future<ui.Image> _generate(TileKey key) async {
    // The pixel loops used to run right here, synchronously - and `request`
    // is called from paint(), so "asynchronous" generation filled a w*h*4
    // buffer (65k sin() calls for one 512x128 brushed tile) inside the very
    // frame the class doc says it spares, on launch and again on every
    // material switch. The loops are pure functions of the key, so they run
    // on a background isolate; only the upload below touches this one, and
    // the engine does that asynchronously.
    final pixels =
        await compute(_pixelsFor, key, debugLabel: 'texture tile $key');
    return _upload(pixels, key.width, key.height);
  }

  /// `ui.decodeImageFromPixels`, unrolled step for step so a failure reaches
  /// the caller.
  ///
  /// The callback form only ever calls back on success. A failure anywhere in
  /// its chain - the buffer allocation, the codec, the frame - surfaced as an
  /// unhandled async error while the Completer waiting on the callback never
  /// completed, which is how one bad upload used to strand its tile forever.
  static Future<ui.Image> _upload(Uint8List pixels, int width, int height) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  /// How many tiles' pixel loops have run on THIS isolate.
  ///
  /// Statics are per-isolate, so on the UI isolate this stays zero for as long
  /// as generation stays off it - which is the contract a test can hold
  /// without timing anything.
  @visibleForTesting
  static int debugPixelPassesOnThisIsolate = 0;

  /// The tile's RGBA bytes. Static and fed only the key, so `compute` ships
  /// nothing across the isolate boundary but a few ints and an enum.
  static Uint8List _pixelsFor(TileKey key) {
    debugPixelPassesOnThisIsolate++;
    final w = key.width, h = key.height;
    final pixels = Uint8List(w * h * 4);
    final rand = _Lcg(key.seed);

    switch (key.kind) {
      case TextureKind.brushed:
        _brushed(pixels, w, h, key.amplitude, rand);
      case TextureKind.speckle:
        _speckle(pixels, w, h, key.amplitude, rand);
      case TextureKind.grain:
      case TextureKind.weave:
      case TextureKind.cell:
      case TextureKind.mesh:
        // Not yet authored. A material that asks for one gets no grain rather
        // than a wrong one; the branch exists so adding it is a function and
        // not a redesign.
        _speckle(pixels, w, h, key.amplitude, rand);
    }
    return pixels;
  }

  /// Horizontal streaks at two frequencies plus a micro grain.
  ///
  /// Two frequencies because one reads as corduroy: a single period gives an
  /// obviously regular comb, while a coarse variation riding under a fine one
  /// reads as an abraded surface. The micro grain doubles as dither, which is
  /// what stops a three-level ramp banding.
  static void _brushed(Uint8List out, int w, int h, int amplitude, _Lcg rand) {
    // A SATIN finish, not a scratched-up one - the second rebalance of this
    // generator, and the statistics are the whole lesson. Machine brushing
    // is a rotating abrasive making uniform passes: the individual grooves
    // are close to invisible, the metal look comes from the anisotropic
    // sheen playing over thousands of near-identical micro-lines, and only
    // the occasional stray scratch reads as a LINE. The previous
    // distribution (base r^2, one row in twenty a deep scratch) rendered
    // exactly what it was - dense high-contrast lines - which reads as
    // corduroy or record grooves, never as metal.
    //
    // So: a quartic base (most rows a whisper), a scratch tail at one row
    // in ~70 and capped well below full depth, and a longer along-fade so
    // what lines exist read as continuous draws rather than strokes.
    final coarse = _smoothNoise(h, 40, rand);

    for (var y = 0; y < h; y++) {
      final r1 = rand.nextDouble();
      var line = r1 * r1 * r1 * r1 * 0.30;
      if (rand.nextDouble() > 0.986) {
        line = 0.40 + 0.25 * rand.nextDouble();
      }
      final phase = rand.nextDouble() * 6.2831853;
      final cycles = 1.0 + 2.0 * rand.nextDouble();

      for (var x = 0; x < w; x++) {
        final along =
            0.72 + 0.28 * math.sin((x / w) * 6.2831853 * cycles + phase);
        final jitter = rand.nextDouble();
        final v = (line * along * 0.88 + coarse[y] * 0.07 + jitter * 0.05)
            .clamp(0.0, 1.0);
        final dev = (v * amplitude).round().clamp(0, 255);
        final i = (y * w + x) * 4;
        out[i] = dev;
        out[i + 1] = dev;
        out[i + 2] = dev;
        out[i + 3] = 255;
      }
    }
  }

  /// Isotropic value noise. Moulded plastic, paper, and the universal dither.
  static void _speckle(Uint8List out, int w, int h, int amplitude, _Lcg rand) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dev = (rand.nextDouble() * amplitude).round().clamp(0, 255);
        final i = (y * w + x) * 4;
        out[i] = dev;
        out[i + 1] = dev;
        out[i + 2] = dev;
        out[i + 3] = 255;
      }
    }
  }

  /// Value noise of a given period, wrapped so the tile is seamless.
  static List<double> _smoothNoise(int length, int period, _Lcg rand) {
    final points = math.max(2, (length / period).ceil());
    final knots = List<double>.generate(points, (_) => rand.nextDouble());
    return List<double>.generate(length, (i) {
      final t = i / period;
      final a = knots[t.floor() % points];
      final b = knots[(t.floor() + 1) % points];
      final f = t - t.floor();
      // Smoothstep, so the seam between knots is not a visible crease.
      final s = f * f * (3 - 2 * f);
      return a + (b - a) * s;
    });
  }
}

/// Everything that changes a tile's pixels, and nothing that does not.
///
/// Deliberately **not** keyed on the surface's size or its base colour. A tiled
/// image keyed on widget size would mint one `ui.Image` per distinct control
/// size across fifty call sites and a scrolling grid, which is worse than no
/// cache at all; and because the grain composites with [BlendMode.plus] rather
/// than being baked into the ground, the same tile is correct on every colour.
@immutable
class TileKey {
  const TileKey({
    required this.kind,
    required this.width,
    required this.height,
    required this.amplitude,
    required this.seed,
  });

  final TextureKind kind;
  final int width, height;

  /// Peak deviation in sRGB levels.
  final int amplitude;

  final int seed;

  @override
  bool operator ==(Object other) =>
      other is TileKey &&
      other.kind == kind &&
      other.width == width &&
      other.height == height &&
      other.amplitude == amplitude &&
      other.seed == seed;

  @override
  int get hashCode => Object.hash(kind, width, height, amplitude, seed);

  @override
  String toString() =>
      'TileKey(${kind.name}, ${width}x$height, +$amplitude, $seed)';
}

/// A small deterministic PRNG.
///
/// Deterministic because the same material must generate the same grain on
/// every launch: a tile that changed between runs would make the screenshot
/// matrix unusable and every visual diff meaningless.
class _Lcg {
  _Lcg(int seed) : _state = seed & 0x7FFFFFFF;
  int _state;

  double nextDouble() {
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
    return _state / 0x7FFFFFFF;
  }
}
