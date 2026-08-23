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
