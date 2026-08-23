import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/download_registry.dart';

/// A fake disk. Anything not listed is absent, and a directory that is not in
/// [dirs] is one we cannot observe at all - the offline-drive case.
class FakeDisk {
  FakeDisk({this.files = const {}, this.dirs = const {}});

  final Set<String> files;
  final Set<String> dirs;

  bool file(String path) => files.contains(path);
  bool dir(String path) => dirs.contains(path);
}

RegistryScanPlan scan(
  FakeDisk disk, {
  Map<String, String> registry = const {},
  Set<String> inFlight = const {},
  Map<String, String> candidates = const {},
}) {
  return planRegistryScan(
    registry: registry,
    inFlightIds: inFlight,
    candidates: candidates,
    fileExists: disk.file,
    directoryExists: disk.dir,
  );
}

void main() {
  group('planRegistryScan', () {
    test('a file that is there stays, and nothing is touched', () {
      final plan = scan(
        FakeDisk(files: {r'D:\vods\a.mp4'}, dirs: {r'D:\vods'}),
        registry: {'1': r'D:\vods\a.mp4'},
      );
      expect(plan.present, {'1'});
      expect(plan.prune, isEmpty);
      expect(plan.stripFromArchive, isEmpty);
      expect(plan.registryChanged, isFalse);
    });

    test('a deleted file in a readable folder is pruned and unarchived', () {
      // Leaving it in yt-dlp's archive would make a re-download exit 0 without
      // producing a file.
      final plan = scan(
        FakeDisk(dirs: {r'D:\vods'}),
        registry: {'1': r'D:\vods\a.mp4'},
      );
      expect(plan.prune, {'1'});
      expect(plan.stripFromArchive, {'1'});
      expect(plan.present, isEmpty);
      expect(plan.registryChanged, isTrue);
    });

    test('an unobservable location is not a deletion', () {
      // The whole point: existsSync() cannot tell "you deleted it" from "that
      // drive letter is not mapped right now", and only one of them may prune.
      final plan = scan(
        FakeDisk(dirs: {r'D:\vods'}),
        registry: {'1': r'E:\archive\a.mp4'},
      );
      expect(plan.unverified, {'1'});
      expect(plan.prune, isEmpty);
      expect(plan.stripFromArchive, isEmpty);
      expect(plan.registryChanged, isFalse);
    });

    test('an in-flight download is never pruned, even with no file yet', () {
      // Regression: the prune re-tested existence without the in-flight guard,
      // so a running re-download erased the archive line of the VOD it was
      // fetching, and lost its registry entry the moment it finished.
      final plan = scan(
        FakeDisk(dirs: {r'D:\vods'}),
        registry: {'1': r'D:\vods\a.mp4'},
        inFlight: {'1'},
      );
      expect(plan.prune, isEmpty);
      expect(plan.stripFromArchive, isEmpty);
      // A partial file is not a download, so no badge either.
      expect(plan.present, isEmpty);
      expect(plan.unverified, isEmpty);
    });

    test('a queued download blocks the prune the same way', () {
      final plan = scan(
        FakeDisk(dirs: {r'D:\vods'}),
        registry: {'1': r'D:\vods\a.mp4', '2': r'D:\vods\b.mp4'},
        inFlight: {'1'},
      );
      expect(plan.prune, {'2'});
    });

    test('the three states are separated in one pass', () {
      final plan = scan(
        FakeDisk(files: {r'D:\vods\d.mp4'}, dirs: {r'D:\vods'}),
        registry: {
          '1': r'D:\vods\a.mp4', // gone, from a folder we can read
          '2': r'E:\gone\b.mp4', // location unobservable
          '3': r'D:\vods\c.mp4', // in flight
          '4': r'D:\vods\d.mp4', // present
        },
        inFlight: {'3'},
      );
      expect(plan.prune, {'1'});
      expect(plan.stripFromArchive, {'1'});
      expect(plan.unverified, {'2'});
      expect(plan.present, {'4'});
    });

    test('a file found on disk is added to the registry', () {
      final plan = scan(
        FakeDisk(files: {r'D:\vods\new.mp4'}, dirs: {r'D:\vods'}),
        candidates: {'9': r'D:\vods\new.mp4'},
      );
      expect(plan.additions, {'9': r'D:\vods\new.mp4'});
      expect(plan.present, {'9'});
      expect(plan.registryChanged, isTrue);
    });

    test('a candidate already recorded at the same path is not re-added', () {
      final plan = scan(
        FakeDisk(files: {r'D:\vods\a.mp4'}, dirs: {r'D:\vods'}),
        registry: {'1': r'D:\vods\a.mp4'},
        candidates: {'1': r'D:\vods\a.mp4'},
      );
      expect(plan.additions, isEmpty);
      expect(plan.registryChanged, isFalse);
    });

    test('a file that moved is re-pointed rather than forgotten', () {
      // Old path gone but the file is where the current settings say it should
      // be: record the new path instead of stripping the archive line.
      final plan = scan(
        FakeDisk(files: {r'D:\new\a.mp4'}, dirs: {r'D:\old', r'D:\new'}),
        registry: {'1': r'D:\old\a.mp4'},
        candidates: {'1': r'D:\new\a.mp4'},
      );
      expect(plan.additions, {'1': r'D:\new\a.mp4'});
      expect(plan.prune, isEmpty);
      expect(plan.stripFromArchive, isEmpty);
      expect(plan.present, {'1'});
    });

    test('a candidate is not adopted while its download is running', () {
      final plan = scan(
        FakeDisk(files: {r'D:\vods\a.mp4'}, dirs: {r'D:\vods'}),
        candidates: {'1': r'D:\vods\a.mp4'},
        inFlight: {'1'},
      );
      expect(plan.additions, isEmpty);
      expect(plan.present, isEmpty);
    });

    test('an empty registry plans nothing', () {
      final plan = scan(FakeDisk());
      expect(plan.registryChanged, isFalse);
      expect(plan.present, isEmpty);
    });

    test('posix paths resolve their parent too', () {
      final plan = scan(
        FakeDisk(dirs: {'/home/me/vods'}),
        registry: {'1': '/home/me/vods/a.mp4'},
      );
      expect(plan.prune, {'1'});
    });
  });
}
