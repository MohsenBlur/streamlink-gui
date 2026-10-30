import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/theme/app_theme.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';
import 'package:streamlink_gui/widgets/shell/engraved_rule.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

/// A theme toggle reaches what reads the theme global, as the app rebuilds
/// on one: a ListenableBuilder on themeNotifier over the MaterialApp.
///
/// const_theme_reader_test is the source net for the class of bug; this is
/// one shipped instance of it, seen from the screen.
void main() {
  late AnimationController pulse;
  late TextEditingController search;

  setUp(() {
    pulse = AnimationController(
        vsync: const TestVSync(), duration: const Duration(seconds: 2));
    search = TextEditingController();
  });
  tearDown(() {
    pulse.dispose();
    search.dispose();
    themeNotifier.setDarkTheme(true);
  });

  testWidgets("the portrait top bar's grooves follow a toggle to light",
      (tester) async {
    // Under `const SizedBox(child: EngravedRule(...))` the two dividers kept
    // the dark palette's groove colours until the bar was rebuilt by shape.
    const size = Size(700, 900);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    themeNotifier.setDarkTheme(true);

    await tester.pumpWidget(ListenableBuilder(
      listenable: themeNotifier,
      builder: (context, _) => MaterialApp(
        theme: buildAppTheme(isDark: false),
        darkTheme: buildAppTheme(isDark: true),
        themeMode:
            themeNotifier.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
        home: AppLayout(
          data: AppLayoutData.fromSize(size),
          child: Scaffold(
            body: SidebarPanel(
              channels: [TwitchChannel(username: 'shroud')],
              followedChannels: const [],
              selectedChannel: null,
              settings: AppSettings(),
              sidebarCollapsed: false,
              isHorizontal: true,
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
      ),
    ));
    await tester.pump();

    List<Color> grooves() => [
          for (final box in tester.widgetList<ColoredBox>(find.descendant(
              of: find.byType(EngravedRule), matching: find.byType(ColoredBox))))
            box.color,
        ];
    final dark = NeuTheme.palette(true);
    expect(grooves(), hasLength(4), reason: 'two rules, two lines each');
    expect(grooves(), [for (var i = 0; i < 2; i++) ...[dark.bevelShade, dark.bevelLight]]);

    themeNotifier.setDarkTheme(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final light = NeuTheme.palette(false);
    expect(grooves(),
        [for (var i = 0; i < 2; i++) ...[light.bevelShade, light.bevelLight]]);
  });
}
