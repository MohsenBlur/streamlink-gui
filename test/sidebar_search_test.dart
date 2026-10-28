import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';
import 'package:streamlink_gui/widgets/sidebar_search_popover.dart';

/// The sidebar search, where favourites are added.
void main() {
  late TextEditingController search;

  setUp(() => search = TextEditingController());
  tearDown(() => search.dispose());

  group('the search popover', () {
    testWidgets('takes focus even though the page already holds it', (tester) async {
      // The home page wraps everything in Focus(autofocus: true). Flutter
      // drops an autofocus request when the scope already has a focused
      // child, so the popover's field opened with no caret and the first
      // keystrokes went to the page's shortcuts.
      var open = false;
      late StateSetter setOpen;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Focus(
            autofocus: true,
            child: StatefulBuilder(builder: (context, setState) {
              setOpen = setState;
              return Column(children: [
                const Text('page'),
                if (open)
                  SidebarSearchPopover(
                    controller: search,
                    channels: const [],
                    tab: 0,
                    onSelect: (_) {},
                    onPlay: (_) {},
                    onAdd: (_) {},
                    close: () {},
                  ),
              ]);
            }),
          ),
        ),
      ));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNotNull,
          reason: 'the page took focus first, as it does in the app');

      setOpen(() => open = true);
      await tester.pump();
      await tester.pump();

      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
    });

    testWidgets('offers to add only something that could be a login', (tester) async {
      Future<void> pumpWith(String query) async {
        search.text = query;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SidebarSearchPopover(
              controller: search,
              channels: const [],
              tab: 0,
              onSelect: (_) {},
              onPlay: (_) {},
              onAdd: (_) {},
              close: () {},
            ),
          ),
        ));
        await tester.pump();
      }

      await pumpWith('foo bar');
      expect(find.textContaining('to Favorites'), findsNothing);
      expect(find.text("No channels match 'foo bar'."), findsOneWidget);

      await pumpWith('foo_bar');
      expect(find.text("Add 'foo_bar' to Favorites"), findsOneWidget);
    });
  });

  group('the expanded sidebar', () {
    late AnimationController pulse;

    setUp(() {
      pulse = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 2),
      );
    });
    tearDown(() => pulse.dispose());

    Future<void> pumpSidebar(WidgetTester tester, String query) async {
      const size = Size(1280, 800);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      search.text = query;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: AppLayout(
          data: AppLayoutData.fromSize(size),
          child: Scaffold(
            body: SidebarPanel(
              channels: [TwitchChannel(username: 'shroud')],
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
      await tester.pump();
    }

    testWidgets('hides "Add" for a name that cannot be a login', (tester) async {
      // Offering to add "foo bar" led to a lookup that could only fail.
      await pumpSidebar(tester, 'foo bar');
      expect(find.textContaining('to Favorites'), findsNothing);

      await pumpSidebar(tester, 'summit1g');
      expect(find.text("Add 'summit1g' to Favorites"), findsOneWidget);
    });
  });
}
