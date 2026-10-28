import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

TwitchChannel ch(String username, {required bool isLive}) {
  final c = TwitchChannel(username: username);
  c.isLive = isLive;
  if (isLive) {
    c.game = 'Chess';
    c.streamTitle = 'A title';
  }
  return c;
}

/// Clicks recorded from the REAL sidebar, in the order they arrived.
class Clicks {
  final selected = <String>[];
  final doubled = <String>[];
}

void main() {
  late AnimationController pulse;
  late TextEditingController search;

  setUp(() {
    pulse = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(seconds: 2),
    );
    search = TextEditingController();
  });

  tearDown(() {
    pulse.dispose();
    search.dispose();
  });

  Future<Clicks> pumpSidebar(
    WidgetTester tester, {
    required Size size,
    required bool horizontal,
    bool collapsed = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final clicks = Clicks();
    final channels = [
      ch('live_one', isLive: true),
      ch('offline_one', isLive: false),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: AppLayout(
        data: AppLayoutData.fromSize(size),
        child: Scaffold(
          body: SidebarPanel(
            channels: channels,
            followedChannels: const [],
            selectedChannel: null,
            settings: AppSettings(),
            sidebarCollapsed: collapsed,
            isHorizontal: horizontal,
            sidebarTab: 0,
            isAdding: false,
            isGlobalLoading: false,
            isLoadingFollowed: false,
            authenticatedUserLogin: null,
            authenticatedUserAvatar: null,
            pulseController: pulse,
            searchController: search,
            onChannelSelected: (c) => clicks.selected.add(c.username),
            onChannelDoubleTapped: (c) => clicks.doubled.add(c.username),
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
    await tester.pump();
    return clicks;
  }

  /// A mouse click, so the row's hover state and the real pointer kind are
  /// both in play.
  Future<void> click(WidgetTester tester, Finder target) async {
    await tester.tap(target, kind: PointerDeviceKind.mouse);
  }

  /// The row itself. Hovering a live row opens its preview card, which
  /// repeats the username, so a bare text finder is ambiguous after a click.
  Finder row(String username) => find.widgetWithText(ListTile, username);

  group('the expanded sidebar', () {
    const size = Size(1280, 800);

    testWidgets('a single click on a live row selects at once',
        (tester) async {
      // Regression: the row's GestureDetector(onDoubleTap:) held the gesture
      // arena for the whole double-tap timeout, so a live row selected about
      // 300ms after the click. No time passes here at all.
      final clicks = await pumpSidebar(tester, size: size, horizontal: false);

      await click(tester, row('live_one'));
      await tester.pump();

      expect(clicks.selected, ['live_one']);
      expect(clicks.doubled, isEmpty);

      // And nothing turns up late once the old timeout would have expired.
      await tester.pump(const Duration(milliseconds: 400));
      expect(clicks.selected, ['live_one']);
      expect(clicks.doubled, isEmpty);
    });

    testWidgets('a double-click on a live row selects once and plays once',
        (tester) async {
      final clicks = await pumpSidebar(tester, size: size, horizontal: false);

      await click(tester, row('live_one'));
      await tester.pump(const Duration(milliseconds: 120));
      await click(tester, row('live_one'));
      await tester.pump();

      expect(clicks.doubled, ['live_one']);
      // The second click is swallowed: re-selecting the channel selected a
      // moment ago would only clear and refetch its VOD list.
      expect(clicks.selected, ['live_one']);

      await tester.pump(const Duration(milliseconds: 400));
      expect(clicks.doubled, ['live_one']);
      expect(clicks.selected, ['live_one']);
    });

    testWidgets('clicks further apart than the timeout are two selections',
        (tester) async {
      final clicks = await pumpSidebar(tester, size: size, horizontal: false);

      await click(tester, row('live_one'));
      await tester.pump(const Duration(milliseconds: 500));
      await click(tester, row('live_one'));
      await tester.pump();

      expect(clicks.selected, ['live_one', 'live_one']);
      expect(clicks.doubled, isEmpty);
    });

    testWidgets('an offline row never plays on a double-click',
        (tester) async {
      final clicks = await pumpSidebar(tester, size: size, horizontal: false);

      await click(tester, row('offline_one'));
      await tester.pump(const Duration(milliseconds: 120));
      await click(tester, row('offline_one'));
      await tester.pump();

      expect(clicks.selected, ['offline_one', 'offline_one']);
      expect(clicks.doubled, isEmpty);
    });

    testWidgets('a double-click spread over two rows is two selections',
        (tester) async {
      final clicks = await pumpSidebar(tester, size: size, horizontal: false);

      await click(tester, row('live_one'));
      await tester.pump(const Duration(milliseconds: 120));
      await click(tester, row('offline_one'));
      await tester.pump();

      expect(clicks.selected, ['live_one', 'offline_one']);
      expect(clicks.doubled, isEmpty);
    });
  });

  group('the avatar rails', () {
    Finder liveAvatar() => find.byTooltip('live_one (LIVE: Chess)');

    testWidgets('the portrait top bar selects at once and plays on a double',
        (tester) async {
      // Portrait, and wide enough for the avatar strip: at the 380px minimum
      // the fixed controls leave it less than one whole avatar, and it
      // deliberately renders nothing rather than a slice of a face.
      final clicks = await pumpSidebar(tester,
          size: const Size(700, 900), horizontal: true);
      expect(liveAvatar(), findsOneWidget);

      await click(tester, liveAvatar());
      await tester.pump();
      expect(clicks.selected, ['live_one']);

      await tester.pump(const Duration(milliseconds: 500));
      await click(tester, liveAvatar());
      await tester.pump(const Duration(milliseconds: 120));
      await click(tester, liveAvatar());
      await tester.pump();
      expect(clicks.selected, ['live_one', 'live_one']);
      expect(clicks.doubled, ['live_one']);
    });

    testWidgets('the collapsed rail selects at once', (tester) async {
      final clicks = await pumpSidebar(tester,
          size: const Size(1280, 800), horizontal: false, collapsed: true);

      await click(tester, liveAvatar());
      await tester.pump();
      expect(clicks.selected, ['live_one']);
      expect(clicks.doubled, isEmpty);
    });
  });
}
