import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/download_view_state.dart';

void main() {
  group('splitDownloadIds', () {
    test('running head of the queue lists as active only', () {
      // Service reality: id A is downloading (process exists) but still sits
      // at the queue head; its task entry says a progress string.
      final split = splitDownloadIds(
        taskIds: ['A', 'B', 'C'],
        queueIds: ['A', 'B', 'C'],
        startedIds: {'A'},
      );
      expect(split.active, ['A']);
      expect(split.queued, ['B', 'C']);
    });

    test('queued-only ids never show as active despite a task entry', () {
      // queueVodDownload writes activeDownloadTasks[id]='Queued' immediately.
      final split = splitDownloadIds(
        taskIds: ['B'],
        queueIds: ['B'],
        startedIds: {},
      );
      expect(split.active, isEmpty);
      expect(split.queued, ['B']);
    });

    test('three queued downloads show exactly 1 active + 2 queued', () {
      final split = splitDownloadIds(
        taskIds: ['A', 'B', 'C'],
        queueIds: ['A', 'B', 'C'],
        startedIds: {'A'},
      );
      expect(split.active.length + split.queued.length, 3);
      expect(split.active, hasLength(1));
      expect(split.queued, hasLength(2));
    });

    test('no double listing in either direction', () {
      final split = splitDownloadIds(
        taskIds: ['A', 'B'],
        queueIds: ['A', 'B'],
        startedIds: {'A'},
      );
      final all = [...split.active, ...split.queued];
      expect(all.toSet().length, all.length);
    });

    test('queued order follows the queue, not the task map', () {
      final split = splitDownloadIds(
        taskIds: ['C', 'B'],
        queueIds: ['B', 'C'],
        startedIds: {},
      );
      expect(split.queued, ['B', 'C']);
    });

    test('id only in queue without a task entry still surfaces', () {
      final split = splitDownloadIds(
        taskIds: [],
        queueIds: ['X'],
        startedIds: {},
      );
      expect(split.queued, ['X']);
    });

    test('empty state', () {
      final split = splitDownloadIds(taskIds: [], queueIds: [], startedIds: {});
      expect(split.active, isEmpty);
      expect(split.queued, isEmpty);
    });
  });
}
