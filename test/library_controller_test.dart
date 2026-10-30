import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/state/library_controller.dart';
import 'package:streamlink_gui/state/library_entries.dart';

/// The Library's state on its own; the screen's use of it is
/// main_screen_library_test, and building the rows library_entries_test.
void main() {
  late Map<String, String> registry;
  late List<String> calls;
  late Set<String> onDisk;
  bool? answer;
  late LibraryController library;

  setUp(() {
    registry = {'1': r'D:\vods\alpha\One - 1.mp4'};
    calls = [];
    onDisk = {r'D:\vods\alpha\One - 1.mp4'};
    answer = true;
    library = LibraryController(
      registry: () => registry,
      recents: () => const <TwitchVideo>[],
      localProgress: () => const <String, int>{},
      channelNames: () => const <String, String>{},
      downloadRoot: () => r'D:\vods',
      rescan: () => calls.add('rescan'),
      play: (video, channel) => calls.add('play ${video.id} in "$channel"'),
      deleteDownload: (id, channel) async {
        calls.add('delete $id in "$channel"');
        registry.remove(id);
      },
      confirmDelete: (title) async {
        calls.add('confirm $title');
        return answer;
      },
      forget: (id) async => calls.add('forget $id'),
      statFile: (path) => onDisk.contains(path)
          ? (size: 10, modified: DateTime.utc(2026, 10, 1))
          : null,
    );
  });

  test('opens with a rescan and fresh rows; closing keeps them', () {
    var notified = 0;
    library.addListener(() => notified++);
    expect(library.isOpen, isFalse);
    library.open();
    expect(calls, ['rescan']);
    expect(library.isOpen, isTrue);
    expect([for (final e in library.entries) e.title], ['One']);
    expect(notified, greaterThan(0));

    library.close();
    expect(library.isOpen, isFalse);
    final before = notified;
    library.close();
    expect(notified, before, reason: 'closing a closed Library is nothing');
  });

  test('a change underneath is shown only while it is open', () {
    registry['2'] = r'D:\vods\alpha\Two - 2.mp4';
    onDisk.add(registry['2']!);
    library.refreshIfOpen();
    expect(library.entries, isEmpty, reason: 'no stat while closed');
    library.open();
    expect(library.entries, hasLength(2));
  });

  test('deletes only on a yes; a dismissed confirm is not one', () async {
    library.open();
    final entry = library.entries.single;
    answer = null;
    await library.delete(entry);
    expect(calls, ['rescan', 'confirm One']);

    answer = true;
    onDisk.clear();
    await library.delete(entry);
    expect(calls.last, 'delete 1 in "alpha"');
    expect(library.entries, isEmpty);
  });

  test('a registry-only row plays with what the row knows', () {
    library.open();
    library.play(library.entries.single);
    expect(calls.last, 'play 1 in "alpha"');
    library.play(const LibraryEntry(
        vodId: '3', title: 'Loose file', channel: null, filePath: r'D:\x.mp4'));
    expect(calls.last, 'play 3 in ""',
        reason: 'no channel folder is the download root itself');
  });

  test('a removal that lands after dispose rebuilds nothing', () async {
    library.open();
    final entry = library.entries.single;
    final removal = library.removeFromHistory(entry);
    library.dispose();
    await removal;
    expect(calls.last, 'forget 1');
  });
}
