import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/activity_state.dart';
import 'package:streamlink_gui/state/library_entries.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/library_view.dart';
import 'package:streamlink_gui/widgets/shell/app_chassis.dart';
import 'package:streamlink_gui/widgets/shell/app_layout.dart';

/// A bulk "Download" from the multi-select bar: one running, the rest queued.
ActivitySnapshot bulkQueue(int count) => ActivitySnapshot(
      downloading: [
        const ActivityItem(
          kind: ActivityKind.downloading,
          id: 'q0',
          label: 'Download 0',
          progress: 0.4,
          status: '40.0% at 3.1MiB/s',
        ),
      ],
      queued: [
        for (var i = 1; i < count; i++)
          ActivityItem(kind: ActivityKind.queued, id: 'q$i', label: 'Download $i'),
      ],
      playing: const [],
    );

List<LibraryEntry> entries() => [
      for (var i = 0; i < 8; i++)
        LibraryEntry(
          vodId: 'v$i',
          filePath: r'C:\downloads\file.mp4',
          title: 'Recorded stream $i',
          channel: 'a_streamer',
          sizeBytes: 1500000000,
          modified: DateTime(2026, 8, 20),
        ),
    ];

/// Height of the scroll viewport that contains [inside].
double viewportHeight(WidgetTester tester, Finder inside) => tester
    .getSize(find
        .ancestor(of: inside, matching: find.byType(Scrollable))
        .first)
    .height;

ScrollPosition positionOf(WidgetTester tester, Finder inside) => tester
    .state<ScrollableState>(
        find.ancestor(of: inside, matching: find.byType(Scrollable)).first)
    .position;

void main() {
  /// Pumps the real LibraryView under the chassis the app wraps it in, at
  /// [size], with [chrome] px of window above it standing in for the title
  /// bar and (in portrait) the top bar - the Library is never the whole
  /// window in the app. Fails on any overflow.
  Future<void> pumpLibrary(
    WidgetTester tester, {
    required Size size,
    required ValueNotifier<ActivitySnapshot> activity,
    double chrome = 0,
  }) async {
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
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          primaryColor: NeuTheme.defaultDarkAccent,
        ),
        home: AppLayout(
          data: AppLayoutData.fromSize(size),
          child: Scaffold(
            body: AppChassis(
              child: Column(
                children: [
                  SizedBox(height: chrome),
                  Expanded(
                    child: LibraryView(
                      entries: entries(),
                      onRefresh: () {},
                      onPlay: (_) {},
                      onOpenFolder: (_) {},
                      onDelete: (_) {},
                      onRemoveFromHistory: (_) {},
                      activity: activity,
                      onStopActivity: (_) {},
                      onBack: () {},
                      backLabel: 'Home',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 400));
    } finally {
      FlutterError.onError = previous;
    }
    expect(overflows, isEmpty,
        reason: 'at ${size.width.toInt()}x${size.height.toInt()}:\n'
            '${overflows.join('\n')}');
  }

  final firstLibraryRow = find.byKey(const ValueKey('lib_v0'));
  final firstLiveRow = find.text('Download 0');

  group('a bulk download queue cannot take the Library away', () {
    // The real window at the enforced minimum: 380x500, with ~100px of title
    // bar and portrait top bar above the Library. And the bare 380x500 the
    // layout sweep uses, and a large desktop window.
    for (final (size, chrome) in [
      (const Size(380, 500), 100.0),
      (const Size(380, 500), 0.0),
      (const Size(1600, 1000), 40.0),
    ]) {
      final label = '${size.width.toInt()}x${size.height.toInt()}'
          '${chrome > 0 ? ' under ${chrome.toInt()}px of chrome' : ''}';

      testWidgets('15 in flight at $label', (tester) async {
        // Regression: fifteen ~64px rows in an unscrollable Column overflowed
        // the page and left the library list's Expanded 0px tall.
        final activity = ValueNotifier(bulkQueue(15));
        addTearDown(activity.dispose);
        await pumpLibrary(tester,
            size: size, activity: activity, chrome: chrome);

        final live = viewportHeight(tester, firstLiveRow);
        final library = viewportHeight(tester, firstLibraryRow);
        expect(library, greaterThan(live),
            reason: 'the library keeps the larger share (live $live, '
                'library $library)');
        expect(library, greaterThan(50),
            reason: 'at least most of a row of the library stays visible');

        // The section scrolls within itself, and its count says how many
        // rows are behind the fold.
        expect(positionOf(tester, firstLiveRow).maxScrollExtent,
            greaterThan(0));
        expect(find.text('15'), findsOneWidget);

        // Every queued item is still reachable. The scrollable is found by
        // any live row, not the first one: that one scrolls out of the tree.
        await tester.scrollUntilVisible(find.text('Download 14'), 60,
            scrollable: find
                .ancestor(
                    of: find.textContaining('Download '),
                    matching: find.byType(Scrollable))
                .first);
        expect(find.text('Download 14'), findsOneWidget);
      });
    }

    testWidgets('a short queue shows every row without scrolling',
        (tester) async {
      // The cap only bites when it has to: two items on a desktop window are
      // laid out in full, with nothing hidden behind a scroll.
      final activity = ValueNotifier(bulkQueue(2));
      addTearDown(activity.dispose);
      await pumpLibrary(tester,
          size: const Size(1600, 1000), activity: activity, chrome: 40);

      expect(positionOf(tester, firstLiveRow).maxScrollExtent, 0);
      expect(find.text('Download 1'), findsOneWidget);
    });

    testWidgets('the section follows the queue as it drains', (tester) async {
      final activity = ValueNotifier(bulkQueue(15));
      addTearDown(activity.dispose);
      await pumpLibrary(tester,
          size: const Size(380, 500), activity: activity, chrome: 100);
      final crowded = viewportHeight(tester, firstLibraryRow);

      activity.value = ActivitySnapshot.empty;
      await tester.pump();
      expect(find.text('IN PROGRESS'), findsNothing);
      expect(viewportHeight(tester, firstLibraryRow), greaterThan(crowded),
          reason: 'the library takes the space back');
    });
  });
}
