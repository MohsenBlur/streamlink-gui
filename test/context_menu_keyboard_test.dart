import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';
import 'package:streamlink_gui/widgets/shell/context_menu.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

void main() {
  group('NeuContextMenu opens from the keyboard', () {
    Future<List<String>> pumpMenu(WidgetTester tester) async {
      final picked = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: NeuContextMenu(
              items: [
                NeuMenuItem(
                    label: 'Rename',
                    icon: Icons.edit,
                    onSelected: () => picked.add('rename')),
              ],
              child: TextButton(onPressed: () {}, child: const Text('Item')),
            ),
          ),
        ),
      ));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      return picked;
    }

    testWidgets('with the Menu key', (tester) async {
      final picked = await pumpMenu(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(picked, ['rename']);
    });

    testWidgets('with Shift+F10, but not with F10 alone', (tester) async {
      await pumpMenu(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
    });

    testWidgets('the wrapper adds no Tab stop of its own', (tester) async {
      await pumpMenu(tester);
      // One Tab landed on the button itself, not on an invisible wrapper.
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
          focused?.findAncestorWidgetOfExactType<TextButton>() != null ||
              focused?.widget is TextButton,
          isTrue);
    });
  });

  testWidgets('a sidebar row\'s menu is reachable without a mouse',
      (tester) async {
    // The sidebar rows were the first NeuContextMenu users, and right-click
    // was the only way to their "Watch now" and favourite actions.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final pulse = AnimationController(
        vsync: const TestVSync(), duration: const Duration(seconds: 2));
    addTearDown(pulse.dispose);
    final search = TextEditingController();
    addTearDown(search.dispose);
    final played = <String>[];

    final live = TwitchChannel(username: 'live_one')
      ..isLive = true
      ..game = 'Chess';
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: AppLayout(
        data: AppLayoutData.fromSize(const Size(1280, 800)),
        child: Scaffold(
          body: SidebarPanel(
            channels: [live],
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
            onChannelPlayPressed: (c) => played.add(c.username),
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

    // Focus the row's own InkWell, as Tab would land on it.
    final row = find.widgetWithText(ListTile, 'live_one');
    final inkWell = find.descendant(of: row, matching: find.byType(InkWell)).first;
    Focus.of(tester.element(find.descendant(
            of: inkWell, matching: find.byType(Text)).first))
        .requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Watch now'));
    await tester.pumpAndSettle();
    expect(played, ['live_one']);
  });
}
