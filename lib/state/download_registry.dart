/// Deciding what the downloaded-VOD registry should contain after a disk scan.
///
/// The registry maps a Twitch VOD id to the absolute path of its downloaded
/// file, and it is kept in step with yt-dlp's `--download-archive`: leaving a
/// deleted VOD in that archive makes a later re-download exit 0 immediately
/// without producing a file.
///
/// Pure so the rules can be tested. Both the scan's damage and its correctness
/// depend on distinguishing three states that a plain `existsSync()` collapses
/// into two: the file is there, the file is gone, and *we cannot currently see
/// where it would be*. Only the second one may prune.
library;

/// What a scan concluded, as data. Nothing here has been applied yet.
class RegistryScanPlan {
  const RegistryScanPlan({
    required this.present,
    required this.unverified,
    required this.prune,
    required this.stripFromArchive,
    required this.additions,
  });

  /// Ids whose file was seen on disk.
  final Set<String> present;

  /// Ids whose location could not be observed - an offline external drive, a
  /// disconnected network share, a folder that has been moved. Not proof of
  /// deletion, so these keep both their registry entry and their archive line.
  final Set<String> unverified;

  /// Ids to drop from the registry: the file is genuinely absent from a
  /// directory we could actually read.
  final Set<String> prune;

  /// Ids to remove from the yt-dlp archive. A subset of [prune] - an entry is
  /// only forgotten when we are sure it is gone.
  final Set<String> stripFromArchive;

  /// Newly discovered files to record, id to absolute path.
  final Map<String, String> additions;

  bool get registryChanged => prune.isNotEmpty || additions.isNotEmpty;
}

/// Plans a registry scan.
///
/// [inFlightIds] are downloads that are running or queued. Their file does not
/// exist yet, or exists only as a partial, so they are never pruned and never
/// counted as present - which also keeps a re-download from erasing the
/// archive line of the very VOD it is fetching.
///
/// [candidates] are ids resolved to a path by the caller (the current channel's
/// VODs against the configured download folder), used to pick up files that
/// arrived without going through this app.
///
/// [fileExists] and [directoryExists] are injected; both must answer false
/// rather than throw when a path is unreachable.
RegistryScanPlan planRegistryScan({
  required Map<String, String> registry,
  required Set<String> inFlightIds,
  required bool Function(String path) fileExists,
  required bool Function(String path) directoryExists,
  Map<String, String> candidates = const {},
}) {
  final present = <String>{};
  final unverified = <String>{};
  final prune = <String>{};

  registry.forEach((vodId, filePath) {
    if (inFlightIds.contains(vodId)) return;

    if (fileExists(filePath)) {
      present.add(vodId);
      return;
    }

    // The file is not there. Before concluding it was deleted, check that we
    // can see the directory it would live in. `existsSync()` returns false for
    // "drive letter no longer mapped" exactly as it does for "you deleted it",
    // and acting on that difference is the whole point of this pass.
    if (directoryExists(_parentOf(filePath))) {
      prune.add(vodId);
    } else {
      unverified.add(vodId);
    }
  });

  final additions = <String, String>{};
  candidates.forEach((vodId, filePath) {
    if (present.contains(vodId) || unverified.contains(vodId)) return;
    if (inFlightIds.contains(vodId)) return;
    if (!fileExists(filePath)) return;

    present.add(vodId);
    prune.remove(vodId); // the file moved rather than vanished
    if (registry[vodId] != filePath) additions[vodId] = filePath;
  });

  return RegistryScanPlan(
    present: present,
    unverified: unverified,
    prune: prune,
    stripFromArchive: prune,
    additions: additions,
  );
}

/// The containing directory of [path], without depending on `package:path`
/// (this library stays free of imports so it can be reasoned about in isolation).
String _parentOf(String path) {
  var end = path.length;
  // Ignore any trailing separators so `C:\a\b\` yields `C:\a`, not `C:\a\b`.
  while (end > 0 && _isSeparator(path[end - 1])) {
    end--;
  }
  for (var i = end - 1; i >= 0; i--) {
    if (_isSeparator(path[i])) {
      // Keep the separator for a root such as `C:\` or `/`.
      final cut = i == 0 ? 1 : i;
      return path.substring(0, cut);
    }
  }
  return '.'; // a bare filename: the current directory
}

bool _isSeparator(String c) => c == r'\' || c == '/';
