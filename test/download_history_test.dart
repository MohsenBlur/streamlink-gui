import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/download_history.dart';
import 'package:streamlink_gui/state/stored_config.dart';

/// The record of every VOD the app downloaded, which keeps auto-download
/// from fetching one again once its file is gone.
void main() {
  final now = DateTime.utc(2026, 10, 28, 12);

  test('a download is noted once, keeping when it first happened', () {
    final history = DownloadHistory();
    expect(history.record('1', now), isTrue);
    expect(history.record('1', now.add(const Duration(days: 3))), isFalse,
        reason: 'nothing new to save');
    expect(history.contains('1'), isTrue);
    expect(history.contains('2'), isFalse);
    expect(history.toJson(), {'1': now.millisecondsSinceEpoch});
  });

  test('a config from before it existed starts it from the seed', () {
    // Every VOD the registry holds: without them the upgrade would fetch each
    // one again the next time retention or the user deleted it.
    final history = DownloadHistory()
      ..restore(null, seed: ['1', '2'], now: now);
    expect(history.contains('1'), isTrue);
    expect(history.contains('2'), isTrue);
  });

  test('a saved one is taken as it is, and the seed left alone', () {
    final saved = {'1': now.millisecondsSinceEpoch};
    final history = DownloadHistory()
      ..record('stale', now)
      ..restore(saved, seed: ['2'], now: now);
    expect(history.toJson(), saved);
  });

  test('an id older than any list the pass reads is dropped', () {
    final history = DownloadHistory()
      ..record('old', now.subtract(DownloadHistory.keepFor))
      ..record('recent', now.subtract(const Duration(days: 30)));
    expect(history.contains('old'), isTrue);

    history.record('new', now.add(const Duration(minutes: 1)));
    expect(history.contains('old'), isFalse);
    expect(history.contains('recent'), isTrue);

    final restored = DownloadHistory()
      ..restore({
        'old': now.subtract(const Duration(days: 91)).millisecondsSinceEpoch,
        'recent': now.millisecondsSinceEpoch,
      }, seed: const [], now: now);
    expect(restored.toJson().keys, ['recent']);
  });

  test('past its size, the oldest go first, a seed in its own order', () {
    final history = DownloadHistory()
      ..addAll([
        for (var i = 0; i < DownloadHistory.maxEntries; i++) 'seed$i',
      ], now.subtract(const Duration(days: 1)));
    history.record('new', now);

    expect(history.length, DownloadHistory.maxEntries);
    expect(history.contains('seed0'), isFalse,
        reason: "the archive's first line is its oldest download");
    expect(history.contains('seed1'), isTrue);
    expect(history.contains('new'), isTrue);
  });

  test('reaches the config and comes back from it', () {
    final history = DownloadHistory()
      ..record('1', now)
      ..record('2', now.add(const Duration(hours: 1)));
    final stored = StoredConfig.parse({'download_history': history.toJson()});
    final back = DownloadHistory()
      ..restore(stored.downloadHistory, seed: const [], now: now);
    expect(back.toJson(), history.toJson());
  });
}
