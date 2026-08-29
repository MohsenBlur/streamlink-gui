import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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
class TextureCache {
  TextureCache._();

  static final Map<TileKey, ui.Image> _tiles = <TileKey, ui.Image>{};
  static final Map<TileKey, List<VoidCallback>> _waiting =
      <TileKey, List<VoidCallback>>{};

  /// Bumped on eviction. A generation that finishes after its bump is dropped
  /// rather than inserted, so a material switch mid-generation cannot resurrect
  /// the previous material's grain.
  static int _generation = 0;

  /// Resident tile, or null. Never blocks and never generates.
  static ui.Image? lookup(TileKey key) => _tiles[key];

  /// Requests [key], calling [onReady] once when it lands.
  ///
  /// Repeated requests for a key already in flight simply add a listener; the
  /// work happens once however many surfaces ask for it.
  static void request(TileKey key, VoidCallback onReady) {
    if (_tiles.containsKey(key)) {
      onReady();
      return;
    }
    final waiting = _waiting[key];
    if (waiting != null) {
      waiting.add(onReady);
      return;
    }
    _waiting[key] = <VoidCallback>[onReady];
    _start(key);
  }

  /// Generates [key] for the CURRENT generation and serves whoever is waiting.
  ///
  /// Split out of [request] because of a race that leaves a surface permanently
  /// untextured. `request` appends to whatever list is already in flight, and
  /// that list survives a generation bump — so this sequence used to strand a
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
    _generate(key).then((image) {
      if (generation != _generation) {
        image.dispose();
        // Only restart if somebody is still waiting. `evictAll` does not clear
        // the queue precisely so that this can serve them.
        if (_waiting.containsKey(key)) _start(key);
        return;
      }
      _tiles[key] = image;
      final callbacks = _waiting.remove(key) ?? const <VoidCallback>[];
      for (final cb in callbacks) {
        cb();
      }
    });
  }

  /// Drops every tile.
  ///
  /// Disposal is deferred by a frame because `ImageShader` asserts on a
  /// disposed image, and a painter built this frame may still hold a shader
  /// over one of these. Evicting under it would throw in debug.
  static void evictAll() {
    _generation++;
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

  static Future<ui.Image> _generate(TileKey key) {
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

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        pixels, w, h, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// Horizontal streaks at two frequencies plus a micro grain.
  ///
  /// Two frequencies because one reads as corduroy: a single period gives an
  /// obviously regular comb, while a coarse variation riding under a fine one
  /// reads as an abraded surface. The micro grain doubles as dither, which is
  /// what stops a three-level ramp banding.
  static void _brushed(Uint8List out, int w, int h, int amplitude, _Lcg rand) {
    // Dense hairlines, not waves - and that distinction is what separates
    // brushed metal from corduroy. The first generator smoothed its noise
    // over a 3-row period, which renders as soft undulating bands; a real
    // brush leaves INDEPENDENT scratches, one device-pixel row each, most
    // of them faint, a heavy tail of them deep. So each row draws its own
    // line depth from a squared distribution (most rows whisper), roughly
    // one row in twenty gets a true scratch, and each line fades along its
    // length with its own phase so the field reads as thousands of strokes
    // rather than as printed stripes. A slow 40-row envelope keeps the
    // sheet from being statistically uniform, which no rolled sheet is.
    final coarse = _smoothNoise(h, 40, rand);

    for (var y = 0; y < h; y++) {
      final r1 = rand.nextDouble();
      var line = r1 * r1 * 0.50;
      if (rand.nextDouble() > 0.95) {
        line = 0.70 + 0.30 * rand.nextDouble();
      }
      final phase = rand.nextDouble() * 6.2831853;
      final cycles = 2.0 + 3.0 * rand.nextDouble();

      for (var x = 0; x < w; x++) {
        // The along-length fade: a scratch is a stroke with ends, not a
        // stripe. Kept tile-periodic (whole cycles across the width) so the
        // seam never shows.
        final along =
            0.55 + 0.45 * math.sin((x / w) * 6.2831853 * cycles + phase);
        final jitter = rand.nextDouble();
        final v = (line * along * 0.86 + coarse[y] * 0.10 + jitter * 0.06)
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
