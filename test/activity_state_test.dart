import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/activity_state.dart';

ActivitySnapshot build({
  Iterable<String> taskIds = const [],
  List<String> queue = const [],
  Set<String> started = const {},
  Map<String, String> titles = const {},
  Map<String, double> progress = const {},
  Map<String, String> statuses = const {},
  Set<String> playingVods = const {},
  Set<String> channels = const {},
  Map<String, String> vodTitles = const {},
}) {
  return buildActivitySnapshot(
    downloadTaskIds: taskIds,
    downloadQueue: queue,
    startedIds: started,
    downloadTitles: titles,
    downloadProgress: progress,
    downloadStatuses: statuses,
    playingVodIds: playingVods,
    runningChannels: channels,
    vodTitles: vodTitles,
  );
}

void main() {
  group('buildActivitySnapshot', () {
    test('idle produces nothing, so the pill hides', () {
      final s = build();
      expect(s.isIdle, isTrue);
      expect(s.total, 0);
      expect(s.all, isEmpty);
    });

    test('splits running downloads from queued ones', () {
      // A is running; B and C are queued. All three carry a task entry, and
      // the running one also still sits at the head of the queue.
      final s = build(
        taskIds: ['A', 'B', 'C'],
        queue: ['A', 'B', 'C'],
        started: {'A'},
        titles: {'A': 'First', 'B': 'Second', 'C': 'Third'},
        progress: {'A': 0.42},
      );
      expect(s.downloading.map((i) => i.id), ['A']);
      expect(s.queued.map((i) => i.id), ['B', 'C']);
      expect(s.downloading.single.progress, 0.42);
      expect(s.total, 3);
    });

    test('an active download is listed exactly once', () {
      final s = build(taskIds: ['A'], queue: ['A'], started: {'A'});
      expect(s.all.where((i) => i.id == 'A'), hasLength(1));
    });

    test('queued order follows the queue, not the task map', () {
      final s = build(taskIds: ['C', 'B'], queue: ['B', 'C']);
      expect(s.queued.map((i) => i.id), ['B', 'C']);
    });

    test('playing streams and VODs both surface', () {
      final s = build(
        playingVods: {'999'},
        channels: {'shroud'},
        vodTitles: {'999': 'Some VOD'},
      );
      expect(s.playing, hasLength(2));
      expect(
          s.playing.map((i) => i.kind),
          containsAll([ActivityKind.liveStream, ActivityKind.playingVod]));
    });

    test('a VOD both downloading and playing yields two distinct items', () {
      // Two real processes; they must be separately stoppable.
      final s = build(
        taskIds: ['77'],
        queue: ['77'],
        started: {'77'},
        playingVods: {'77'},
      );
      expect(s.total, 2);
      final keys = s.all.map((i) => i.logKey).toSet();
      expect(keys, {'dl-77', '77'});
    });

    test('missing titles fall back to the id', () {
      final s = build(taskIds: ['42'], queue: ['42'], started: {'42'});
      expect(s.downloading.single.label, 'VOD 42');
    });

    test('mean progress averages only running downloads', () {
      final s = build(
        taskIds: ['A', 'B', 'C'],
        queue: ['A', 'B', 'C'],
        started: {'A', 'B'},
        progress: {'A': 0.2, 'B': 0.6},
      );
      expect(s.meanDownloadProgress, closeTo(0.4, 1e-9));
    });

    test('mean progress is null when nothing is running', () {
      expect(build(taskIds: ['A'], queue: ['A']).meanDownloadProgress, isNull);
    });
  });

  group('ActivityItem.logKey', () {
    test('matches the keys PlayerService registers', () {
      expect(
          const ActivityItem(kind: ActivityKind.downloading, id: '5', label: '')
              .logKey,
          'dl-5');
      expect(
          const ActivityItem(kind: ActivityKind.queued, id: '5', label: '')
              .logKey,
          'dl-5');
      expect(
          const ActivityItem(kind: ActivityKind.playingVod, id: '5', label: '')
              .logKey,
          '5');
      // liveStreamKey lowercases the channel.
      expect(
          const ActivityItem(
                  kind: ActivityKind.liveStream, id: 'Shroud', label: '')
              .logKey,
          'stream_shroud');
    });

    test('isDownload covers both download kinds only', () {
      expect(
          const ActivityItem(kind: ActivityKind.queued, id: '1', label: '')
              .isDownload,
          isTrue);
      expect(
          const ActivityItem(kind: ActivityKind.liveStream, id: 'x', label: '')
              .isDownload,
          isFalse);
    });
  });

  group('progressTickIsVisible', () {
    test('the first sample always rebuilds', () {
      expect(
          progressTickIsVisible(
              previousBucket: null,
              progress: 0.0,
              previousStatus: null,
              status: 'Starting...'),
          isTrue);
    });

    test('sub-percent movement is collapsed', () {
      expect(
          progressTickIsVisible(
              previousBucket: 42,
              progress: 0.4219,
              previousStatus: 'x',
              status: 'x'),
          isFalse);
    });

    test('crossing a percent rebuilds', () {
      expect(
          progressTickIsVisible(
              previousBucket: 42,
              progress: 0.43,
              previousStatus: 'x',
              status: 'x'),
          isTrue);
    });

    test('a status change always rebuilds, even at the same percent', () {
      // "Queued" -> "Starting..." -> "Finalizing file..." carry no percentage.
      expect(
          progressTickIsVisible(
              previousBucket: 100,
              progress: 1.0,
              previousStatus: 'Downloading',
              status: 'Finalizing file...'),
          isTrue);
    });
  });
  group('shouldReportPlaybackFailure', () {
    test('a deliberate stop is never a failure, whatever the exit code', () {
      // Regression: stopping playback from the activity popover runs taskkill,
      // which exits non-zero, and every stop reported "Playback failed".
      expect(
          shouldReportPlaybackFailure(exitCode: 1, userInitiated: true), isFalse);
      expect(
          shouldReportPlaybackFailure(exitCode: -1, userInitiated: true), isFalse);
    });

    test('an unexpected non-zero exit still reports', () {
      expect(
          shouldReportPlaybackFailure(exitCode: 1, userInitiated: false), isTrue);
      // -1 is what the service reports when the player never launched.
      expect(
          shouldReportPlaybackFailure(exitCode: -1, userInitiated: false), isTrue);
    });

    test('a clean exit is never a failure', () {
      expect(
          shouldReportPlaybackFailure(exitCode: 0, userInitiated: false), isFalse);
      expect(
          shouldReportPlaybackFailure(exitCode: 0, userInitiated: true), isFalse);
    });
  });
}
