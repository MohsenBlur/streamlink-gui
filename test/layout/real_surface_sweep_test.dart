import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/state/library_entries.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';
import 'package:streamlink_gui/widgets/dashboard_header.dart';
import 'package:streamlink_gui/widgets/library_view.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';
import 'package:streamlink_gui/widgets/shell/neu_dialog.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

import 'overflow_sweep_test.dart' show channel, sweepSizes;

/// The overflow sweep, run against the **real** surfaces rather than a
/// stand-in.
///
/// `overflow_sweep_test` pumps `_liveCardFooter()` — a copy of the welcome
/// card's footer, defined in the test file itself. It caught the bug it was
/// written for, and it has been drifting from the widget it imitates ever
/// since: it touches no theme token, so nothing it does can be affected by a
/// material at all. A sweep that cannot see the thing being changed is not
/// covering this work.
///
/// So this pumps `SidebarPanel`, `DashboardHeader`, `LibraryView` and
/// `NeuDialog` at every reachable window size, once per material. It exists
/// specifically to run **before** furniture lands: screws, seams and engraved
/// plates all add widgets inside surfaces that are already tight at 380px, and
/// a green sweep beforehand is what makes a red one afterwards mean something.
///
/// The brightness axis is collapsed deliberately — see the last test. Light and
/// dark palettes differ only in colour, and a sweep is about geometry, so
/// running both would double the cost to re-measure identical boxes. That
/// claim is asserted rather than assumed.
void main() {
  /// Pumps [build] at [size] under [material] and fails on any overflow.
  ///
  /// Not shared with `overflow_sweep_test.expectNoOverflow`: this one has to
  /// set the active material and the global theme notifier, which that harness
  /// knows nothing about.
  Future<void> sweep(
    WidgetTester tester,
    Size size,
    AppMaterial material,
    Widget Function() build,
  ) async {
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

    final previousMaterial = NeuTheme.activeMaterial;
    NeuTheme.activeMaterial = material;
    themeNotifier.isDarkTheme = true;

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => NeuTheme.activeMaterial = previousMaterial);

    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          primaryColor: NeuTheme.defaultDarkAccent,
        ),
        home: AppLayout(
          data: AppLayoutData.fromSize(size),
          child: Scaffold(body: build()),
        ),
      ));
      // Long enough for every entrance animation in these surfaces to settle;
      // a mid-animation frame can be transiently over-wide and would make this
      // flaky in both directions.
      await tester.pump(const Duration(milliseconds: 400));
    } finally {
      FlutterError.onError = previous;
    }

    expect(overflows, isEmpty,
        reason: '${material.key} at ${size.width.toInt()}x'
            '${size.height.toInt()}:\n${overflows.join('\n')}');
  }

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

  /// Hostile content: real Twitch strings run long, and the point of a sweep
  /// is the case that does not fit.
  List<TwitchChannel> channels() => [
        channel(),
        channel(username: 'b_streamer', isLive: false),
        channel(username: 'c', isLive: false),
      ];

  Widget sidebar({required bool horizontal, required bool collapsed}) =>
      SidebarPanel(
        channels: channels(),
        followedChannels: channels(),
        selectedChannel: null,
        settings: AppSettings(),
        sidebarCollapsed: collapsed,
        isHorizontal: horizontal,
        sidebarTab: 0,
        isAdding: false,
        isGlobalLoading: false,
        isLoadingFollowed: false,
        authenticatedUserLogin: 'a_user_with_a_long_login_name',
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
      );

  Widget header() => DashboardHeader(
        channel: channel(),
        pulseController: pulse,
        onPlay: () {},
        onRefresh: () {},
        openExternalLink: (_) {},
        isPlaying: false,
      );

  Widget library() => LibraryView(
        entries: [
          for (var i = 0; i < 6; i++)
            LibraryEntry(
              vodId: 'v$i',
              filePath:
                  r'C:\a\very\deep\downloads\folder\that\goes\on\file.mp4',
              title: 'An extremely long recorded stream title that will not '
                  'fit in a narrow row at all, day $i',
              channel: 'a_streamer_with_a_very_long_channel_name',
              sizeBytes: 15300000000,
              modified: DateTime(2026, 8, 20),
            ),
        ],
        onRefresh: () {},
        onPlay: (_) {},
        onOpenFolder: (_) {},
        onDelete: (_) {},
        onRemoveFromHistory: (_) {},
      );

  /// A dialog with leading actions, which is what the settings dialog is.
  ///
  /// Added after the plain variant below sailed through every size while the
  /// real settings sheet overflowed its own 600px footer by 27px. A sweep that
  /// exercises the simplest configuration of a widget is testing the
  /// configuration nothing ships.
  Widget dialogWithLeading() => NeuDialog(
        title: 'Settings',
        icon: Icons.settings,
        width: 600,
        content: const Text('Body copy.'),
        // Four leading actions and the longest status string the updater can
        // produce, which is what the settings dialog actually passes. The
        // earlier version of this used three bare Texts and therefore tested a
        // configuration nothing ships - it sailed through every size while the
        // real dialog overflowed.
        //
        // The ParentDataWidget half of that bug is guarded separately, in
        // neu_dialog_test: it cannot be caught by measuring, because debug
        // renders it correctly and only release throws.
        leadingActions: [
          const Text('v9.9.9-dev'),
          const Text('GitHub Repo'),
          const Text('Check for Updates'),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: const Text(
              'v9.9.9 available - close Settings to install',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        actions: [
          const NeuDialogAction.secondary('Cancel', null),
          NeuDialogAction.primary('Save changes', () {}),
        ],
      );

  Widget dialog() => NeuDialog(
        title: 'A dialog title long enough to need the ellipsis it declares',
        subtitle: 'And a subtitle that is also longer than a 380px window',
        icon: Icons.settings,
        content: const Text('Body copy.'),
        actions: [
          const NeuDialogAction.secondary('Cancel', null),
          NeuDialogAction.primary('Save changes', () {}),
        ],
      );

  group('real surfaces survive every size, on every material', () {
    for (final spec in MaterialSpec.available) {
      final m = spec.id;
      for (final size in sweepSizes) {
        final label = '${m.key} ${size.width.toInt()}x${size.height.toInt()}';

        testWidgets('the sidebar — $label', (tester) async {
          // Both roots. The expanded sidebar and the horizontal rail are
          // separate returns reached by an early return, and the rail is the
          // branch that only appears in portrait — exactly the window shapes
          // least likely to be looked at by hand.
          final isRail = AppLayoutData.fromSize(size).isRail;
          await sweep(tester, size, m,
              () => sidebar(horizontal: isRail, collapsed: false));
        });

        // The collapsed VERTICAL sidebar, at the sizes where it exists. Below
        // 700 wide, and in any portrait window, the layout picks the rail
        // instead - so pumping a collapsed vertical sidebar at 380x500 would
        // be asserting about a state the app cannot reach, and the 46px
        // vertical overflow it reports is an artefact of the harness rather
        // than a defect. Stated here rather than silently skipped.
        if (!AppLayoutData.fromSize(size).isRail) {
          testWidgets('the collapsed sidebar — $label', (tester) async {
            await sweep(tester, size, m,
                () => sidebar(horizontal: false, collapsed: true));
          });
        }

        testWidgets('the dashboard header — $label', (tester) async {
          await sweep(tester, size, m, header);
        });

        testWidgets('the library — $label', (tester) async {
          await sweep(tester, size, m, library);
        });

        testWidgets('a dialog with leading actions — $label', (tester) async {
          await sweep(
              tester, size, m, () => Center(child: dialogWithLeading()));
        });

        testWidgets('a dialog — $label', (tester) async {
          // Dialogs are the surface most likely to break on this work: they
          // just changed from a flat sheet to a panel, which means they now
          // carry a bevel and a border that claim real padding.
          await sweep(tester, size, m, () => Center(child: dialog()));
        });
      }
    }
  });

  group('the brightness axis is collapsed on purpose', () {
    test('light and dark palettes declare identical geometry', () {
      // The justification for sweeping dark only. A material's two palettes
      // may differ in every colour and in nothing that occupies space — if one
      // ever grew a wider bevel than the other, the sweep above would be
      // covering half the app and saying so in neither direction.
      for (final spec in MaterialSpec.available) {
        final light = spec.palette(false);
        final dark = spec.palette(true);
        final where = spec.id.key;

        expect(light.bevelWidth, dark.bevelWidth, reason: '$where bevelWidth');
        expect(light.fill.length, dark.fill.length,
            reason: '$where fill stop count');
        for (var i = 0; i < light.fill.length; i++) {
          expect(light.fill[i].at, dark.fill[i].at,
              reason: '$where fill stop $i position');
        }
        expect(light.contact.length, dark.contact.length,
            reason: '$where contact layer count');
        expect(light.inset.length, dark.inset.length,
            reason: '$where inset layer count');
        expect(light.recessStyle, dark.recessStyle,
            reason: '$where recessStyle — a true inset and an outer fake do '
                'not occupy the same box');
        expect(light.lightAzimuthDeg, dark.lightAzimuthDeg,
            reason: '$where light direction');

        // Shadow extents, which is where a difference would actually move a
        // pixel: a cast layer's reach is offset plus blur plus spread.
        double reach(List<ShadowLayer> layers) => layers.fold(0.0, (max, l) {
              final r = Offset(l.dx, l.dy).distance + l.blur + l.spread;
              return r > max ? r : max;
            });
        expect(reach(light.contact), closeTo(reach(dark.contact), 1e-9),
            reason: '$where contact reach');
        expect(reach(light.inset), closeTo(reach(dark.inset), 1e-9),
            reason: '$where inset reach');
      }
    });
  });
}
