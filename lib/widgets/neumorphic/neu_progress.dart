import 'package:flutter/material.dart';

import '../../theme/material/app_material.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// Bar thickness. The app used 2, 3, 3 and the Material default (4) for the
/// same idea, and rounded two of them but not the others.
enum NeuProgressSize {
  /// 2px — inside the title-bar activity pill, where vertical room is scarce.
  xs,

  /// 3px — list rows: the Library, the activity popover.
  sm,

  /// 4px — the default.
  md,

  /// 6px — a progress bar that is the point of its container.
  lg,
}

extension on NeuProgressSize {
  double get thickness => switch (this) {
        NeuProgressSize.xs => 2,
        NeuProgressSize.sm => 3,
        NeuProgressSize.md => 4,
        NeuProgressSize.lg => 6,
      };

  /// Kept at 2 for every size: the radius reads as "rounded" rather than
  /// scaling with thickness, which is what the two rounded call sites chose.
  double get radius => 2;
}

/// A determinate or indeterminate progress bar.
///
/// Owns the `ClipRRect(borderRadius: circular(2))` that was duplicated verbatim
/// at the call sites that bothered to round it, and the track colour that all
/// of them spelled out as `NeuTheme.border(isDark)`.
///
/// The fill uses the raw accent rather than `accentInk`: this is a filled
/// shape, not a foreground, so its legibility comes from the track behind it.
class NeuProgressBar extends StatelessWidget {
  const NeuProgressBar({
    Key? key,
    this.value,
    this.size = NeuProgressSize.md,
    this.color,
    this.trackColor,
    this.width,
    this.semanticLabel,
  }) : super(key: key);

  /// 0..1, or null for indeterminate.
  final double? value;

  final NeuProgressSize size;
  final Color? color;
  final Color? trackColor;

  /// Fixed width, when the bar sits somewhere unbounded. Prefer letting the
  /// parent constrain it.
  final double? width;

  /// Announced to assistive tech. Without one a bare progress bar tells a
  /// screen reader nothing about what is progressing.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    final accent = color ?? Theme.of(context).primaryColor;

    // A meter is a milled slot with a lit fill, not a coloured line. The
    // reference hardware's meters are recessed channels - a dark slot whose
    // top wall is in shadow and whose near lip catches the light - with a
    // bright fill that GLOWS, because on an instrument the fill is an
    // emissive element, not paint. The xs size opts out of the slot: it
    // lives inside the title-bar glass pill, where it reads as a line of
    // light on the display itself.
    //
    // Indeterminate keeps the framework's animation, run inside the slot's
    // tone, because reimplementing that animation buys nothing.
    final slotted = size != NeuProgressSize.xs;
    final track = trackColor ??
        (slotted ? NeuTheme.wellSurface(isDark) : NeuTheme.border(isDark));

    // The material's meter style. xs always stays the emissive line: it
    // lives inside the title-bar glass, where every material's reading is a
    // line of light on the display itself.
    final spec = MaterialSpec.of(NeuTheme.activeMaterial);
    final style = slotted ? spec.instruments.meterStyle : MeterStyle.slot;
    final palette = NeuTheme.palette(isDark);
    // The VFD draws in its own phosphor - the one meter whose colour is the
    // material's identity rather than the user's accent. The others keep
    // the accent: the STYLE is the differentiator, the hue stays the
    // user's choice.
    final lit = style == MeterStyle.vfdSegments ? palette.screenText : accent;

    Widget bar;
    if (value != null) {
      bar = CustomPaint(
        size: Size(width ?? double.infinity,
            slotted ? size.thickness + 3 : size.thickness),
        painter: MeterPainter(
          value: value!.clamp(0.0, 1.0),
          fill: lit,
          track: track,
          radius: size.radius,
          slotted: slotted,
          shade: palette.bevelShade,
          light: palette.bevelLight,
          style: style,
          metal: palette.accentMetal,
        ),
      );
    } else {
      bar = ClipRRect(
        borderRadius: BorderRadius.circular(size.radius),
        child: LinearProgressIndicator(
          value: value,
          minHeight: size.thickness,
          backgroundColor: track,
          valueColor: AlwaysStoppedAnimation<Color>(accent),
        ),
      );
    }

    if (width != null) bar = SizedBox(width: width, child: bar);

    if (semanticLabel != null) {
      bar = Semantics(
        label: semanticLabel,
        value: value == null ? null : '${(value! * 100).round()}%',
        child: ExcludeSemantics(child: bar),
      );
    }
    return bar;
  }
}

/// Circular counterpart, for the "working…" spinners.
enum NeuProgressRingSize { xs, sm, md, lg }

extension on NeuProgressRingSize {
  double get extent => switch (this) {
        NeuProgressRingSize.xs => 12,
        NeuProgressRingSize.sm => 16,
        NeuProgressRingSize.md => 20,
        NeuProgressRingSize.lg => 28,
      };

  /// Stroke tracks the diameter instead of the four hand-picked values
  /// (1.5, 1.8, 2, 2) that were in use.
  double get stroke => switch (this) {
        NeuProgressRingSize.xs => 1.5,
        NeuProgressRingSize.sm => 2,
        NeuProgressRingSize.md => 2.5,
        NeuProgressRingSize.lg => 3,
      };
}

class NeuProgressRing extends StatelessWidget {
  const NeuProgressRing({
    Key? key,
    this.value,
    this.size = NeuProgressRingSize.md,
    this.color,
    this.semanticLabel,
  }) : super(key: key);

  final double? value;
  final NeuProgressRingSize size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    Widget ring = SizedBox(
      width: size.extent,
      height: size.extent,
      child: CircularProgressIndicator(
        value: value,
        strokeWidth: size.stroke,
        color: color ?? Theme.of(context).primaryColor,
      ),
    );

    if (semanticLabel != null) {
      ring = Semantics(
        label: semanticLabel,
        child: ExcludeSemantics(child: ring),
      );
    }
    return ring;
  }
}


/// Paints one determinate meter: slot, walls, lit fill, glow.
///
/// Public and value-comparable so the widget test can assert what will paint
/// without rasterising - the geometry contract lives in the fields.
class MeterPainter extends CustomPainter {
  const MeterPainter({
    required this.value,
    required this.fill,
    required this.track,
    required this.radius,
    required this.slotted,
    required this.shade,
    required this.light,
    this.style = MeterStyle.slot,
    this.metal,
  });

  final double value;
  final Color fill, track, shade, light;
  final double radius;
  final bool slotted;

  /// The material's instrument shape. [MeterStyle.slot] is the v1.8.0
  /// meter and Soft's forever.
  final MeterStyle style;

  /// The needle's pointer metal; null falls back to [fill].
  final Color? metal;

  /// Segment pitch for the discrete styles, in logical px (segment + gap).
  static const double segmentPitch = 7.0;

  /// How many segments a meter of [width] carries.
  static int segmentCount(double width) =>
      ((width - 2) / segmentPitch).floor().clamp(4, 60);

  /// How many of [total] segments are lit at [value].
  static int litSegments(double value, int total) =>
      (value * total).round().clamp(value > 0 ? 1 : 0, total);

  /// Segments at or past this fraction of the scale light amber - the
  /// broadcast meter's headroom zone.
  static const double warmZone = 0.78;

  /// The amber. Semantic like `live` and `danger`: a meter's headroom is
  /// the same colour in every world that has one.
  static const Color warm = Color(0xFFFFB350);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    if (w <= 0) return;

    if (!slotted) {
      // The emissive line: fill over track, plus bloom.
      final r = Radius.circular(radius);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Offset.zero & size, r),
          Paint()..color = track);
      if (value > 0) {
        final fw = (w * value).clamp(size.height, w);
        final rect = Rect.fromLTWH(0, 0, fw, size.height);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, r),
            Paint()
              ..color = fill.withValues(alpha: 0.55)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
        canvas.drawRRect(
            RRect.fromRectAndRadius(rect, r), Paint()..color = fill);
      }
      return;
    }

    // The slot: 1px shadowed top wall inside, 1px lit lip below. Every
    // style shares it - the difference is what sits IN the channel.
    final slotH = size.height - 1;
    final slot = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w, slotH), Radius.circular(radius + 1));
    canvas.drawRRect(slot, Paint()..color = track);

    canvas.save();
    canvas.clipRRect(slot);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, 1), Paint()..color = shade);
    canvas.restore();

    canvas.drawRect(
        Rect.fromLTWH(1, slotH, w - 2, 1), Paint()..color = light);

    switch (style) {
      case MeterStyle.ledSegments:
      case MeterStyle.vfdSegments:
        _paintSegments(canvas, w, slotH);
        return;
      case MeterStyle.needle:
        _paintNeedle(canvas, w, slotH);
        return;
      case MeterStyle.slot:
        break;
    }

    if (value > 0) {
      final channelH = slotH - 2;
      final fw = (w * value).clamp(channelH.toDouble(), w.toDouble());
      final rect = Rect.fromLTWH(1, 1, fw - 1, channelH);
      final r = Radius.circular(radius);
      // Bloom first, then the crisp fill: the meter is lit, not painted.
      canvas.drawRRect(RRect.fromRectAndRadius(rect, r),
          Paint()
            ..color = fill.withValues(alpha: 0.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5));
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, r), Paint()..color = fill);
      // A brighter top edge on the fill itself - the lit face of the bar.
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(rect, r));
      canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.top, rect.width, 1),
          Paint()..color = const Color(0x66FFFFFF));
      canvas.restore();
    }
  }

  /// Discrete segments in the channel. LED and VFD share the geometry and
  /// differ in dress: LED shows dark sockets and an amber headroom zone;
  /// VFD shows dim phosphor ghosts and a bloom, because a fluorescent cell
  /// is never fully dark and always slightly lit.
  void _paintSegments(Canvas canvas, double w, double slotH) {
    final channelH = slotH - 2;
    final n = segmentCount(w);
    final segW = (w - 2) / n - 1.2;
    final lit = litSegments(value, n);
    final vfd = style == MeterStyle.vfdSegments;

    for (var i = 0; i < n; i++) {
      final x = 1 + i * ((w - 2) / n);
      final rect = Rect.fromLTWH(x, 1, segW, channelH);
      final isLit = i < lit;
      final inWarmZone = (i + 1) / n > warmZone;

      if (!isLit) {
        // LED: an unlit socket, darker than the channel. VFD: a ghost -
        // phosphor idling at a whisper of its colour.
        canvas.drawRect(
            rect,
            Paint()
              ..color = vfd
                  ? fill.withValues(alpha: 0.10)
                  : shade.withValues(alpha: 0.35));
        continue;
      }
      final colour = !vfd && inWarmZone ? warm : fill;
      if (vfd || i == lit - 1) {
        // Bloom on every VFD cell, and on the LED bar's tip segment - the
        // peak is the reading, and the reading glows.
        canvas.drawRect(
            rect.inflate(0.8),
            Paint()
              ..color = colour.withValues(alpha: 0.45)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.8));
      }
      canvas.drawRect(rect, Paint()..color = colour);
    }
  }

  /// The engraved scale and its pointer. No fill: the position is the
  /// reading, which is what makes it a needle and not a bar.
  void _paintNeedle(Canvas canvas, double w, double slotH) {
    final channelH = slotH - 2;
    // Tick hairlines every tenth, engraved into the channel.
    for (var i = 1; i < 10; i++) {
      final x = 1 + (w - 2) * i / 10;
      canvas.drawLine(
          Offset(x, 1.5),
          Offset(x, 1 + channelH * 0.55),
          Paint()
            ..strokeWidth = 1
            ..color = shade.withValues(alpha: 0.6));
    }
    // A faint trail up to the pointer, so "how far along" still reads at a
    // glance the way a filled meter does.
    final px = 1 + (w - 2) * value;
    canvas.drawRect(Rect.fromLTWH(1, 1, px - 1, channelH),
        Paint()..color = fill.withValues(alpha: 0.14));
    // The pointer: brass where the material declares it.
    final pointer = metal ?? fill;
    canvas
      ..drawLine(Offset(px, 0.5), Offset(px, slotH - 0.5),
          Paint()..strokeWidth = 2.4..color = pointer)
      ..drawLine(Offset(px - 1.4, 0.5), Offset(px - 1.4, slotH - 0.5),
          Paint()
            ..strokeWidth = 0.8
            ..color = const Color(0x66FFFFFF));
  }

  @override
  bool shouldRepaint(MeterPainter old) =>
      old.value != value ||
      old.fill != fill ||
      old.track != track ||
      old.radius != radius ||
      old.slotted != slotted ||
      old.shade != shade ||
      old.light != light ||
      old.style != style ||
      old.metal != metal;
}
