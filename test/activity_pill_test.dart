import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/activity_state.dart';
import 'package:streamlink_gui/state/library_entries.dart';
import 'package:streamlink_gui/widgets/activity_pill.dart';
import 'package:streamlink_gui/widgets/library_view.dart';

ActivityItem download(String id, {double? progress}) => ActivityItem(
      kind: ActivityKind.downloading,
      id: id,
      label: 'Download $id',
      progress: progress,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('ActivityPill', () {
    testWidgets('renders nothing at all when idle', (tester) async {
      final activity = ValueNotifier(ActivitySnapshot.empty);
      addTearDown(activity.dispose);

      await tester.pumpWidget(host(
        ActivityPill(activity: activity, onStop: (_) {}),
      ));

      // The whole point: an idle app spends no chrome on this.
      expect(find.byType(Tooltip), findsNothing);
      expect(tester.getSize(find.byType(ActivityPill)), Size.zero);
    });

    testWidgets('summarises a mixed snapshot', (tester) async {
      final activity = ValueNotifier(ActivitySnapshot(
        downloading: [download('1', progress: 0.5), download('2')],
        queued: const [],
        playing: const [
          ActivityItem(
              kind: ActivityKind.liveStream, id: 'shroud', label: 'shroud'),
        ],
      ));
      addTearDown(activity.dispose);

      await tester.pumpWidget(host(
        ActivityPill(activity: activity, onStop: (_) {}),
      ));

      expect(find.text('2 downloading · 1 playing'), findsOneWidget);
    });

    testWidgets('names the single item rather than counting it',
        (tester) async {
      final activity = ValueNotifier(ActivitySnapshot(
        downloading: [download('1', progress: 0.42)],
        queued: const [],
        playing: const [],
      ));
      addTearDown(activity.dispose);

      await tester.pumpWidget(host(
        ActivityPill(activity: activity, onStop: (_) {}),
      ));

      expect(find.text('42% · Download 1'), findsOneWidget);
    });

    testWidgets('compact mode shows only the count', (tester) async {
      final activity = ValueNotifier(ActivitySnapshot(
        downloading: [download('1'), download('2')],
        queued: const [],
        playing: const [],
      ));
      addTearDown(activity.dispose);

      await tester.pumpWidget(host(
        ActivityPill(activity: activity, onStop: (_) {}, compact: true),
      ));

      expect(find.text('2'), findsOneWidget);
      expect(find.text('2 downloading'), findsNothing);
    });

    testWidgets('appears and disappears as activity changes', (tester) async {
      final activity = ValueNotifier(ActivitySnapshot.empty);
      addTearDown(activity.dispose);

      await tester.pumpWidget(host(
        ActivityPill(activity: activity, onStop: (_) {}),
      ));
      expect(tester.getSize(find.byType(ActivityPill)), Size.zero);

      activity.value = ActivitySnapshot(
          downloading: [download('1')], queued: const [], playing: const []);
      await tester.pump();
      expect(tester.getSize(find.byType(ActivityPill)).width, greaterThan(0));

      activity.value = ActivitySnapshot.empty;
      await tester.pump();
      expect(tester.getSize(find.byType(ActivityPill)), Size.zero);
    });
  });

  group('LibraryView live rows', () {
    testWidgets('shows an in-progress download with no cached entries at all',
        (tester) async {
      // Proves the live section is independent of the cached, disk-derived
      // list — which is the whole reason it is a separate section.
      final activity = ValueNotifier(ActivitySnapshot(
        downloading: [download('1', progress: 0.3)],
        queued: [
          const ActivityItem(
              kind: ActivityKind.queued, id: '2', label: 'Download 2'),
        ],
        playing: const [],
      ));
      addTearDown(activity.dispose);
      ActivityItem? stopped;

      await tester.pumpWidget(host(LibraryView(
        entries: const <LibraryEntry>[],
        onRefresh: () {},
        onPlay: (_) {},
        onOpenFolder: (_) {},
        onDelete: (_) {},
        onRemoveFromHistory: (_) {},
        activity: activity,
        onStopActivity: (item) => stopped = item,
      )));

      expect(find.text('IN PROGRESS'), findsOneWidget);
      expect(find.text('DOWNLOADING'), findsOneWidget);
      expect(find.text('QUEUED'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump();
      expect(stopped?.id, '1');
    });

    testWidgets('no live section when nothing is in flight', (tester) async {
      final activity = ValueNotifier(ActivitySnapshot.empty);
      addTearDown(activity.dispose);

      await tester.pumpWidget(host(LibraryView(
        entries: const <LibraryEntry>[],
        onRefresh: () {},
        onPlay: (_) {},
        onOpenFolder: (_) {},
        onDelete: (_) {},
        onRemoveFromHistory: (_) {},
        activity: activity,
      )));

      expect(find.text('IN PROGRESS'), findsNothing);
    });
  });
}
