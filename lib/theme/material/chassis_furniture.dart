import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'material_palette.dart';

/// The window's ornament: the milled edge groove, the corner screws, the rim.
///
/// ## Why this is not one of `SkeuoDecoration`'s seven layers
///
/// The seven layers are what a *surface* is made of, and every one of them is
/// a function of the box it is given. Furniture is not: a screw is 12 logical
/// pixels whether the window is 380 wide or 2560, it belongs to the window
/// rather than to any control, and whether it should be drawn at all depends
/// on how much room the window has — which `BoxPainter.paint` cannot know.
/// `ImageConfiguration.size` is the *decorated box's* size, so a painter
/// cannot tell a 400px window from a 400px card inside a 2560px one.
///
/// So the decision lives in the widget ([AppChassis]) and the drawing lives
/// here. This is deliberately a `Decoration` rather than a `CustomPaint`
/// because it is installed as a `foregroundDecoration`: that paints after the
/// child, and `RenderDecoratedBox.hitTestSelf` is false, so the ornament sits
/// over the whole app without an `IgnorePointer` and without a `Stack`.
///
/// Foreground, not background, and that is forced rather than preferred: a
/// background chassis has its corners covered by the title bar and the
/// sidebar, and insetting the content to expose them would move the layout
/// this whole effort is committed to leaving alone.
@immutable
class ChassisFurniture extends Decoration {
  const ChassisFurniture({
    required this.furniture,
    required this.palette,
  });

  final Furniture furniture;
  final MaterialPalette palette;

  /// How far the groove and the screws sit in from the window edge.
  ///
  /// One number for both, because a screw that is not centred in its own
  /// groove is the detail that makes a faceplate look drawn rather than made.
  static const double inset = 11.0;

  /// Screw head diameter. Twelve, not eight: below about twelve the socket,
  /// the slot and the specular all land inside two pixels of each other and
  /// the result reads as a smudge — the failure mode the plan calls
  /// photorealistic detail below 12px.
  static const double screwDiameter = 12.0;

  /// How much room a corner screw needs at the window's edge.
  ///
  /// The one number any surface that reaches an edge has to respect, so that
  /// the ornament never lands on a control. Only the title bar needs it: the
  /// sidebar's footer icons start 36px in and every content view carries at
  /// least 32px of padding, both already clear of `inset + screwDiameter`.
  /// The title bar had 16, and the first build put a screw squarely on the
  /// close button - which is the exact failure the plan names as ornament
  /// obscuring a control.
  static const double edgeClearance = inset + screwDiameter + 4;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _FurniturePainter(this);

  @override
  EdgeInsetsGeometry get padding => EdgeInsets.zero;

  /// Never. This is ornament drawn over the app; it must not eat a click that
  /// lands on a control underneath it.
  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      false;

  @override
  bool get isComplex => true;

  @override
  bool operator ==(Object other) =>
      other is ChassisFurniture &&
      other.furniture == furniture &&
      other.palette == palette;

  @override
  int get hashCode => Object.hash(furniture, palette);
}

class _FurniturePainter extends BoxPainter {
  _FurniturePainter(this.spec);

  final ChassisFurniture spec;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    final p = spec.palette;

    // The light direction, shared with every surface in the app. A screw lit
    // from one side while the panel it sits in is lit from another is the
    // mirrored-bevel defect at a smaller scale.
    final r = p.lightAzimuthDeg * math.pi / 180.0;
    final toLight = Offset(math.cos(r), -math.sin(r));

    if (spec.furniture.rim != RimStyle.none) _paintRim(canvas, rect, p);
    if (spec.furniture.seams) _paintGroove(canvas, rect, p, toLight);
    if (spec.furniture.screws) _paintScrews(canvas, rect, p, toLight);

    final chassis = spec.furniture.chassis;
    if (chassis != null) {
      switch (chassis.kind) {
        case ChassisKind.rails:
          _paintRail(canvas, rect, p, chassis);
        case ChassisKind.woodFrame:
          _paintWoodFrame(canvas, rect, p, chassis);
        case ChassisKind.ventStrip:
          _paintVentStrip(canvas, rect, p, chassis);
      }
    }
  }

  /// The band's base colour for the current brightness.
  Color _tone(MaterialPalette p, ChassisSpec c) =>
      (p.isLight ? c.tone : c.toneDark) ?? p.surface;

  /// A deterministic PRNG for ornament detail.
  ///
  /// Seeded by a constant: the wood's figure and the rail's machining marks
  /// must be identical on every launch, or the screenshot matrix and every
  /// visual diff dissolve into noise - the same rule the texture tiles
  /// follow.
  static double _rand(int n) {
    var x = (n * 1103515245 + 12345) & 0x7FFFFFFF;
    x = (x * 1103515245 + 12345) & 0x7FFFFFFF;
    return x / 0x7FFFFFFF;
  }

  /// The broadcast machine's mounting flange: one milled rail along the
  /// bottom edge, socket-head bolts at pitch.
  ///
  /// Bottom only, and that is a finding inherited rather than a taste call:
  /// a top band crosses the title bar's controls, and ornament over controls
  /// is the exact v1.7.1 failure. The bottom edge belongs to padding on
  /// every surface that reaches it.
  void _paintRail(
      Canvas canvas, Rect rect, MaterialPalette p, ChassisSpec c) {
    final band = Rect.fromLTRB(
        rect.left, rect.bottom - c.bandExtent, rect.right, rect.bottom);
    final tone = _tone(p, c);

    // The rail's own body: a vertical ramp, lit on top, falling away - a
    // strip of milled stock, not a painted stripe.
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            p.shadeStop(tone, (at: 0.0, dh: 0.0, ds: 0.0, dl: 0.045)),
            p.shadeStop(tone, (at: 1.0, dh: 0.0, ds: 0.0, dl: -0.050)),
          ],
        ).createShader(band),
    );
    // The engraved margin pair along its top: the rail carries its own
    // margin, which is what makes a hairline here a SEAM rather than the
    // stray line the v1.7.1 groove became.
    canvas
      ..drawLine(band.topLeft, band.topRight,
          Paint()..strokeWidth = 1..color = p.bevelShade)
      ..drawLine(band.topLeft.translate(0, 1), band.topRight.translate(0, 1),
          Paint()..strokeWidth = 1..color = p.bevelLight);

    // Socket-head bolts at pitch, never near the corners. Socket, not slot:
    // a dark hex-ish well with a lit upper arc reads as a fastener at 7px
    // where a slotted disc reads as a button.
    if (c.boltPitchPx > 0) {
      final cy = band.center.dy;
      final r = (c.bandExtent * 0.30).clamp(2.0, 3.5);
      final usable = rect.width - 2 * c.cornerAvoidPx;
      if (usable > c.boltPitchPx) {
        final n = (usable / c.boltPitchPx).floor();
        final step = usable / n;
        for (var i = 0; i <= n; i++) {
          final cx = rect.left + c.cornerAvoidPx + i * step;
          canvas
            ..drawCircle(Offset(cx, cy), r,
                Paint()..color = _opaque(p.shadow, 0.55))
            ..drawCircle(Offset(cx, cy), r * 0.55,
                Paint()..color = _opaque(p.shadow, 0.85))
            ..drawArc(
                Rect.fromCircle(center: Offset(cx, cy), radius: r),
                math.pi * 1.15,
                math.pi * 0.7,
                false,
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1
                  ..color = _opaque(p.highlight, 0.45));
        }
      }
    }
  }

  /// The walnut sleeve: four mitred bands with the grain running along each.
  ///
  /// The grain is painted directly - deterministic streak lines from the
  /// seeded PRNG - rather than through the tile cache: a 10px band needs a
  /// dozen strokes, not an ImageShader, and a synchronous painter cannot
  /// leave a flat first frame the way an async tile would.
  ///
  /// This is a contrast-free zone: no glyph ever sits on the window's outer
  /// band (the title bar honours [ChassisSpec.edgeClearance], the sidebar's
  /// children hold >= 12px, content holds >= 16px), so the figure may swing
  /// far louder than any budgeted surface texture.
  void _paintWoodFrame(
      Canvas canvas, Rect rect, MaterialPalette p, ChassisSpec c) {
    final w = c.bandExtent;
    final wTop = c.resolvedTopExtent;
    final tone = _tone(p, c);

    final top = Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + wTop);
    final bottom =
        Rect.fromLTRB(rect.left, rect.bottom - w, rect.right, rect.bottom);
    final left = Rect.fromLTRB(
        rect.left, rect.top + wTop, rect.left + w, rect.bottom - w);
    final right = Rect.fromLTRB(
        rect.right - w, rect.top + wTop, rect.right, rect.bottom - w);

    _woodBand(canvas, top, tone, p, horizontal: true, seedBase: 11);
    _woodBand(canvas, bottom, tone, p, horizontal: true, seedBase: 47);
    _woodBand(canvas, left, tone, p, horizontal: false, seedBase: 83);
    _woodBand(canvas, right, tone, p, horizontal: false, seedBase: 131);

    // Mitre seams: the 45-degree joints a real case is cut with. A shade
    // hairline with a lit partner on the inner side, running corner-in.
    void mitre(Offset corner, Offset dir) {
      final len = math.max(w, wTop) * 1.4142;
      canvas
        ..drawLine(corner, corner + dir * len,
            Paint()..strokeWidth = 1..color = _opaque(p.shadow, 0.45))
        ..drawLine(corner + Offset(dir.dx, dir.dy) * 0.0 +
                Offset(dir.dx.sign, dir.dy.sign),
            corner + dir * len + Offset(dir.dx.sign, dir.dy.sign),
            Paint()..strokeWidth = 1..color = _opaque(p.highlight, 0.18));
    }

    mitre(rect.topLeft, const Offset(0.7071, 0.7071));
    mitre(rect.topRight, const Offset(-0.7071, 0.7071));
    mitre(rect.bottomLeft, const Offset(0.7071, -0.7071));
    mitre(rect.bottomRight, const Offset(-0.7071, -0.7071));

    // Where the faceplate meets the case: a soft inner shadow just inside
    // the frame, so the plate reads as SET INTO the wood rather than butted
    // against a painted border.
    final inner = Rect.fromLTRB(rect.left + w, rect.top + wTop,
        rect.right - w, rect.bottom - w);
    canvas.drawRect(
        inner.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = _opaque(p.shadow, 0.35));
    canvas.drawRect(
        inner.deflate(1.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = _opaque(p.shadow, 0.15));
  }

  /// One band of wood: base ramp, long grain streaks, a couple of figure
  /// bands. [horizontal] runs the grain along x; vertical bands run it along
  /// y - the way a mitred case's grain actually turns the corner.
  void _woodBand(Canvas canvas, Rect band, Color tone, MaterialPalette p,
      {required bool horizontal, required int seedBase}) {
    if (band.isEmpty) return;
    // Base: lit toward the window centre, darker at the outer edge - the
    // case's edge rolls away from the room's light.
    final outward = horizontal
        ? (band.top < 50 ? Alignment.bottomCenter : Alignment.topCenter)
        : (band.left < 50 ? Alignment.centerRight : Alignment.centerLeft);
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          begin: outward,
          end: Alignment(-outward.x, -outward.y),
          colors: [
            p.shadeStop(tone, (at: 0.0, dh: 2.0, ds: 0.03, dl: 0.035)),
            p.shadeStop(tone, (at: 1.0, dh: 4.0, ds: 0.05, dl: -0.045)),
          ],
        ).createShader(band),
    );

    // The figure: long streaks in both directions from the deterministic
    // PRNG. Dark streaks are the pore; the sparser light ones are the sheen
    // off the early wood. Amplitudes here would be illegal on any surface
    // carrying text; the frame carries none.
    final along = horizontal ? band.width : band.height;
    final across = horizontal ? band.height : band.width;
    final streaks = (across * 1.6).round().clamp(8, 26);
    for (var i = 0; i < streaks; i++) {
      final t = _rand(seedBase * 97 + i * 13);
      final pos = across * (0.06 + 0.88 * t);
      final dark = _rand(seedBase * 31 + i * 7) > 0.32;
      final alpha = dark
          ? 0.10 + 0.16 * _rand(seedBase * 53 + i * 17)
          : 0.05 + 0.08 * _rand(seedBase * 53 + i * 17);
      final colour = dark
          ? _opaque(p.shadow, alpha)
          : _opaque(p.highlight, alpha);
      final thickness = 0.7 + 1.1 * _rand(seedBase * 71 + i * 29);
      // A streak wanders: three segments with slight drift, so the figure
      // reads as grown rather than ruled.
      final drift1 = (across * 0.08) * (_rand(seedBase + i * 41) - 0.5);
      final drift2 = (across * 0.08) * (_rand(seedBase + i * 43) - 0.5);
      final paint = Paint()
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round
        ..color = colour;
      Offset at(double f, double d) => horizontal
          ? Offset(band.left + along * f, band.top + pos + d)
          : Offset(band.left + pos + d, band.top + along * f);
      final path = Path()..moveTo(at(0, 0).dx, at(0, 0).dy);
      path
        ..lineTo(at(0.35, drift1).dx, at(0.35, drift1).dy)
        ..lineTo(at(0.7, drift2).dx, at(0.7, drift2).dy)
        ..lineTo(at(1, 0).dx, at(1, 0).dy);
      canvas.drawPath(path, paint..style = PaintingStyle.stroke);
    }
  }

  /// The vent: staggered perforation rows along the bottom edge.
  void _paintVentStrip(
      Canvas canvas, Rect rect, MaterialPalette p, ChassisSpec c) {
    final band = Rect.fromLTRB(
        rect.left, rect.bottom - c.bandExtent, rect.right, rect.bottom);
    final tone = _tone(p, c);
    canvas.drawRect(band, Paint()..color = tone);
    canvas
      ..drawLine(band.topLeft, band.topRight,
          Paint()..strokeWidth = 1..color = p.bevelShade)
      ..drawLine(band.topLeft.translate(0, 1), band.topRight.translate(0, 1),
          Paint()..strokeWidth = 1..color = _opaque(p.highlight, 0.20));

    // Two staggered rows of holes, hex-pitched. Each hole is a dark well
    // with a 1px lit lower lip - light falls INTO a hole from above.
    const pitch = 7.0;
    final r = (c.bandExtent * 0.16).clamp(1.0, 1.6);
    final rows = c.bandExtent >= 8 ? 2 : 1;
    for (var row = 0; row < rows; row++) {
      final cy = band.top + c.bandExtent * (rows == 1 ? 0.55 : 0.34 + 0.38 * row);
      final offset = row.isOdd ? pitch / 2 : 0.0;
      for (var x = band.left + 10 + offset; x < band.right - 10; x += pitch) {
        canvas
          ..drawCircle(Offset(x, cy), r, Paint()..color = _opaque(p.shadow, 0.75))
          ..drawArc(
              Rect.fromCircle(center: Offset(x, cy), radius: r),
              math.pi * 0.15,
              math.pi * 0.7,
              false,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 0.8
                ..color = _opaque(p.highlight, 0.25));
      }
    }
  }

  /// The milled groove running just inside the panel edge.
  ///
  /// Two hairlines, not one. A single dark line is a drawn rectangle; a dark
  /// line with a light line on its lit side is a *cut*, because that is what
  /// an engraved channel actually shows — the far wall in shadow and the near
  /// wall catching the light. The whole read of "machined" comes from this
  /// pair being the right way round, which is why it takes the palette's
  /// light direction rather than assuming one.
  void _paintGroove(
      Canvas canvas, Rect rect, MaterialPalette p, Offset toLight) {
    final groove = RRect.fromRectAndRadius(
      rect.deflate(ChassisFurniture.inset),
      const Radius.circular(2),
    );
    // The offset is a whole pixel: a half-pixel pair of hairlines antialiases
    // into one grey line, which is exactly the smear it is trying not to be.
    final lit = Offset(toLight.dx.sign, toLight.dy.sign);

    // Shadow on the side the light comes FROM, highlight on the far side.
    // That is what makes it a channel cut into the plate rather than a bead
    // raised on top of one - crossing the near wall you turn away from the
    // light, and the far wall turns back toward it. The first build had the
    // pair the other way round and read as a moulding, which is the same
    // defect as a mirrored bevel and just as hard to name when you see it.
    canvas
      ..drawRRect(
        groove.shift(lit),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = p.bevelShade,
      )
      ..drawRRect(
        groove.shift(-lit),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = p.bevelLight,
      );
  }

  /// One screw at each corner of the groove.
  ///
  /// All four take the same light, which is the point: four screws lit from
  /// four directions is what a decorative screenshot looks like, and one is
  /// what a photograph of a panel looks like.
  void _paintScrews(
      Canvas canvas, Rect rect, MaterialPalette p, Offset toLight) {
    const d = ChassisFurniture.screwDiameter;
    final margin = ChassisFurniture.inset + d / 2 + 3;
    for (final centre in <Offset>[
      rect.topLeft + Offset(margin, margin),
      rect.topRight + Offset(-margin, margin),
      rect.bottomLeft + Offset(margin, -margin),
      rect.bottomRight + Offset(-margin, -margin),
    ]) {
      _paintScrew(canvas, centre, d / 2, p, toLight);
    }
  }

  void _paintScrew(Canvas canvas, Offset c, double radius, MaterialPalette p,
      Offset toLight) {
    // The countersunk socket: a shadow ring the head sits down inside. Drawn
    // slightly larger than the head, so the head reads as recessed rather than
    // stuck on.
    canvas.drawCircle(
      c,
      radius + 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = _opaque(p.shadow, 0.60),
    );

    // The head. A linear ramp across it, not a radial one: a screw head is a
    // flat disc catching a directional light, and a radial gradient would make
    // it a sphere.
    final head = Rect.fromCircle(center: c, radius: radius);
    final lit = Offset(toLight.dx, toLight.dy);
    canvas.drawCircle(
      c,
      radius,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(lit.dx, lit.dy),
          end: Alignment(-lit.dx, -lit.dy),
          colors: [
            p.shadeStop(p.surface, (at: 0.0, dh: 0.0, ds: 0.0, dl: 0.090)),
            p.shadeStop(p.surface, (at: 1.0, dh: 0.0, ds: 0.0, dl: -0.075)),
          ],
        ).createShader(head),
    );

    // The slot. Perpendicular to the light, so it catches one wall — a slot
    // running along the light direction has no shadow in it and disappears.
    //
    // Debossed like the groove, and for the same reason: shadow on the lit
    // side, highlight opposite. A slot with its highlight on top is a raised
    // ridge across the screw head.
    final across = Offset(-toLight.dy, toLight.dx);
    final half = radius * 0.62;
    canvas
      ..drawLine(
        c - across * half,
        c + across * half,
        Paint()
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = _opaque(p.shadow, 0.55),
      )
      ..drawLine(
        c - across * half - toLight * 0.9,
        c + across * half - toLight * 0.9,
        Paint()
          ..strokeWidth = 1
          ..strokeCap = StrokeCap.round
          ..color = _opaque(p.highlight, 0.45),
      );
  }

  /// A palette colour at a chosen alpha.
  ///
  /// The screw takes its contrast from `shadow` and `highlight` rather than
  /// from `bevelShade`/`bevelLight`. The bevel pair is calibrated for a 1px
  /// edge on a surface *of the same material*; a screw is a different object
  /// sitting in a hole, and at the bevel's alphas it rendered as a smudge -
  /// three features inside twelve pixels, none of them separated by enough
  /// levels to be seen as separate.
  static Color _opaque(Color c, double alpha) => c.withValues(alpha: alpha);

  /// The frame around the whole window, for the materials that have one.
  ///
  /// Rack does not — an anodised faceplate has no separate frame, it *is* the
  /// frame — so this branch is written and unused until v1.9.0's chrome. It
  /// exists now because the alternative is discovering in v1.9.0 that the
  /// furniture record has no way to say "and a rim", which is an engine change
  /// rather than a palette one.
  void _paintRim(Canvas canvas, Rect rect, MaterialPalette p) {
    final width = switch (spec.furniture.rim) {
      RimStyle.none => 0.0,
      RimStyle.chrome => 3.0,
      RimStyle.brass => 2.5,
      RimStyle.moulded => 4.0,
    };
    if (width == 0) return;
    canvas.drawRect(
      rect.deflate(width / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [p.bevelLight, p.bevelShade],
        ).createShader(rect),
    );
  }
}
