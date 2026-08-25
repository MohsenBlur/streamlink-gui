import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_progress.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';

/// [width] is the space the widget is GIVEN, not what it must be. Passing null
/// leaves it unconstrained, which is how the intrinsic-size assertions below
/// can measure the widget's own choice rather than the harness's.
Widget host(Widget child,
    {Brightness brightness = Brightness.dark, double? width = 200}) {
  return MaterialApp(
    theme: ThemeData(
      brightness: brightness,
      primaryColor: NeuTheme.defaultDarkAccent,
    ),
    home: Scaffold(
      body: Center(
        child: width == null ? child : SizedBox(width: width, child: child),
      ),
    ),
  );
}

void main() {
  group('NeuProgressBar', () {
    testWidgets('each size maps to its documented fill thickness',
        (tester) async {
      // The documented thickness is the FILL channel; slotted sizes add two
      // wall pixels and a lit lip below (thickness + 3 total), and xs stays
      // a bare emissive line for the glass pill. Successor to the old
      // LinearProgressIndicator.minHeight assertion, which no longer exists
      // for determinate bars - a meter is a milled slot with a lit fill,
      // painted by MeterPainter.
      const expected = {
        NeuProgressSize.xs: 2.0,
        NeuProgressSize.sm: 6.0,
        NeuProgressSize.md: 7.0,
        NeuProgressSize.lg: 9.0,
      };
      for (final entry in expected.entries) {
        await tester
            .pumpWidget(host(NeuProgressBar(value: 0.5, size: entry.key)));
        final paint = tester.widget<CustomPaint>(find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is MeterPainter));
        expect(paint.size.height, entry.value,
            reason: '${entry.key} should paint ${entry.value}px tall');
        final meter = paint.painter! as MeterPainter;
        expect(meter.slotted, entry.key != NeuProgressSize.xs,
            reason: 'only xs opts out of the slot');
        expect(meter.value, 0.5);
      }
    });

    testWidgets('the slot is cut from the well, not outlined in border grey',
        (tester) async {
      await tester.pumpWidget(
          host(const NeuProgressBar(value: 0.5, size: NeuProgressSize.md)));
      final paint = tester.widget<CustomPaint>(find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is MeterPainter));
      final meter = paint.painter! as MeterPainter;
      expect(meter.track, NeuTheme.wellSurface(themeNotifier.isDarkTheme),
          reason: 'a recessed channel takes the well ground');
      expect(meter.shade, isNot(meter.light),
          reason: 'the slot walls must disagree - that is what a groove is');
    });

    testWidgets('a null value is indeterminate', (tester) async {
      await tester.pumpWidget(host(const NeuProgressBar()));
      final indicator = tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(indicator.value, isNull);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('announces itself when given a label', (tester) async {
      // A bare progress bar tells a screen reader nothing about what is
      // progressing.
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(
        const NeuProgressBar(value: 0.42, semanticLabel: 'Download progress'),
      ));
      expect(find.bySemanticsLabel('Download progress'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('respects an explicit width', (tester) async {
      await tester.pumpWidget(host(
        const NeuProgressBar(value: 0.5, width: 90, size: NeuProgressSize.xs),
        width: null,
      ));
      final size = tester.getSize(find.byType(NeuProgressBar));
      expect(size.width, 90);
    });

    testWidgets('lays out at the 380px minimum without overflow',
        (tester) async {
      final overflows = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exception.toString().contains('overflowed')) {
          overflows.add(d.exception.toString());
        } else {
          previous?.call(d);
        }
      };
      tester.view.physicalSize = const Size(380, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(const NeuProgressBar(value: 0.5)));
      await tester.pump();
      FlutterError.onError = previous;
      expect(overflows, isEmpty);
    });
  });

  group('NeuProgressRing', () {
    testWidgets('each size maps to its documented extent and stroke',
        (tester) async {
      // Replaces four hand-picked stroke widths (1.5, 1.8, 2, 2).
      const extents = {
        NeuProgressRingSize.xs: 12.0,
        NeuProgressRingSize.sm: 16.0,
        NeuProgressRingSize.md: 20.0,
        NeuProgressRingSize.lg: 28.0,
      };
      for (final entry in extents.entries) {
        await tester.pumpWidget(
            host(NeuProgressRing(size: entry.key), width: null));
        expect(tester.getSize(find.byType(NeuProgressRing)),
            Size(entry.value, entry.value));
      }
    });

    testWidgets('stroke grows with the ring', (tester) async {
      double strokeFor(NeuProgressRingSize s) => switch (s) {
            NeuProgressRingSize.xs => 1.5,
            NeuProgressRingSize.sm => 2.0,
            NeuProgressRingSize.md => 2.5,
            NeuProgressRingSize.lg => 3.0,
          };
      for (final size in NeuProgressRingSize.values) {
        await tester.pumpWidget(host(NeuProgressRing(size: size), width: null));
        final ring = tester.widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator));
        expect(ring.strokeWidth, strokeFor(size));
      }
    });
  });
}
