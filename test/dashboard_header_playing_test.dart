import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/dashboard_header.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

TwitchChannel liveChannel() {
  final c = TwitchChannel(username: 'shroud');
  c.isLive = true;
  c.game = 'Chess';
  c.streamTitle = 'A title';
  c.viewerCount = '1234';
  return c;
}

void main() {
  late AnimationController pulse;

  setUp(() {
    pulse = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(seconds: 2),
    );
  });

  tearDown(() => pulse.dispose());

  Future<void> pumpHeader(WidgetTester tester, Size size,
      {required bool isPlaying}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: NeuTheme.defaultDarkAccent,
      ),
      home: AppLayout(
        data: AppLayoutData.fromSize(size),
        child: Scaffold(
          body: SingleChildScrollView(
            child: DashboardHeader(
              channel: liveChannel(),
              pulseController: pulse,
              onPlay: () {},
              onRefresh: () {},
              openExternalLink: (_) {},
              isPlaying: isPlaying,
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  // Both header layouts: the compact one at the minimum window and the full
  // card on a desktop one. Each builds its own play button.
  for (final size in const [Size(380, 500), Size(1600, 1000)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('a playing channel shows OPEN without a spinner at $label',
        (tester) async {
      // Regression: "the player is open" was an indeterminate ring that ran
      // for the whole viewing session - hours of per-frame repaints of the
      // header - labelled "Refreshing" for screen readers.
      final semantics = tester.ensureSemantics();
      await pumpHeader(tester, size, isPlaying: true);

      final playButton = find.ancestor(
          of: find.text('OPEN'), matching: find.byType(ElevatedButton));
      expect(playButton, findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(DashboardHeader),
              matching: find.byType(CircularProgressIndicator)),
          findsNothing);
      expect(
          find.descendant(
              of: playButton, matching: find.byIcon(Icons.ondemand_video)),
          findsOneWidget);
      expect(find.bySemanticsLabel('Refreshing'), findsNothing);
      semantics.dispose();
    });

    testWidgets('a live channel that is not playing still offers PLAY at $label',
        (tester) async {
      await pumpHeader(tester, size, isPlaying: false);
      expect(find.text('PLAY'), findsOneWidget);
      expect(find.text('OPEN'), findsNothing);
    });
  }
}
