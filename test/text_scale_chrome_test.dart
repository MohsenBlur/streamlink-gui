import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/state/activity_state.dart';
import 'package:streamlink_gui/widgets/activity_pill.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_title_bar.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

/// Fixed-size chrome under Windows' Text size past what the sweeps cover
/// (test/layout/text_scale_sweep_test runs 125% and 150%).
void main() {
  setUp(() {
    addTearDown(TestWidgetsFlutterBinding
        .instance.platformDispatcher.clearTextScaleFactorTestValue);
  });

  testWidgets('the title bar draws its text at no more than 125%',
      (tester) async {
    // A fixed 40px strip: at 175% the activity pill's two lines overflowed
    // its slot at the bottom.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    late double inside;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NeuTitleBar(
          isDarkTheme: true,
          onThemeToggle: (_) {},
          actions: [
            Builder(builder: (context) {
              inside = MediaQuery.textScalerOf(context).scale(10) / 10;
              return const Text('pill');
            }),
          ],
        ),
      ),
    ));
    expect(inside, NeuTitleBar.maxTextScale);
    expect(tester.takeException(), isNull);
  });

  testWidgets("but the activity popover it opens follows Windows' setting",
      (tester) async {
    // The popover is an OverlayPortal child, built under the strip's clamp
    // though it is no part of the strip: it has no fixed height to keep,
    // and its list of downloads and players is what Text size is for.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    final activity = ValueNotifier(ActivitySnapshot(
      downloading: const [
        ActivityItem(
            kind: ActivityKind.downloading, id: '1', label: 'Download 1'),
      ],
      queued: const [],
      playing: const [],
    ));
    addTearDown(activity.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NeuTitleBar(
          isDarkTheme: true,
          onThemeToggle: (_) {},
          actions: [ActivityPill(activity: activity, onStop: (_) {})],
        ),
      ),
    ));
    await tester.tap(find.byType(ActivityPill));
    await tester.pump(const Duration(milliseconds: 400));

    final popover = tester.element(find.byType(ActivityPopover));
    expect(MediaQuery.textScalerOf(popover).scale(10) / 10, 2.0);
  });

  testWidgets('the expanded sidebar holds at 175%', (tester) async {
    // The Automation label pushed the Refresh/Automation row past the
    // sidebar, and a live row's LIVE badge overran its title; the label
    // ellipsizes now, Refresh keeps its icon, and the badge scales down.
    const size = Size(1280, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.75;

    final pulse = AnimationController(
        vsync: const TestVSync(), duration: const Duration(seconds: 2));
    final search = TextEditingController();
    addTearDown(pulse.dispose);
    addTearDown(search.dispose);

    final overflows = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.exception.toString();
      if (text.contains('overflowed')) {
        overflows.add(text.split('\n').first);
      } else {
        previous?.call(details);
      }
    };
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: AppLayout(
          data: AppLayoutData.fromSize(size),
          child: Scaffold(
            body: SidebarPanel(
              channels: [
                TwitchChannel(username: 'offline_one'),
                TwitchChannel(username: 'a_streamer_with_a_long_name')
                  ..isLive = true
                  ..game = 'Just Chatting',
              ],
              followedChannels: const [],
              selectedChannel: null,
              settings: AppSettings(),
              sidebarCollapsed: false,
              isHorizontal: false,
              sidebarTab: 0,
              isAdding: false,
              isGlobalLoading: false,
              isLoadingFollowed: false,
              authenticatedUserLogin: null,
              authenticatedUserAvatar: null,
              pulseController: pulse,
              searchController: search,
              onChannelSelected: (_) {},
              onChannelDoubleTapped: (_) {},
              onChannelPlayPressed: (_) {},
              onAddChannel: (_) {},
              onToggleFavorite: (_) {},
              onToggleCollapse: (_) {},
              onTabChanged: (_) {},
              onRefresh: () {},
              onShowSettings: () {},
              onShowLibrary: () {},
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
    } finally {
      FlutterError.onError = previous;
    }

    expect(overflows, isEmpty);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });
}
