import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart';
import 'package:streamlink_gui/state/settings_repository.dart';
import 'package:streamlink_gui/state/watch_history_controller.dart';

import 'support/memory_storage.dart';

/// The watch history on its own: the screen's use of it is
/// main_screen_watch_test, and the store's rules watch_progress_store_test.
void main() {
  late MemoryStorageService storage;
  late SettingsRepository repository;
  late AppSettings settings;
  late List<TwitchVideo> open;
  late List<String> logged;
  late WatchHistoryController history;
  final now = DateTime.utc(2026, 10, 28, 12);

  TwitchVideo vod(String id, {String duration = '1h0m0s'}) => TwitchVideo(
        id: id,
        title: 'VOD $id',
        duration: duration,
        thumbnailUrl: '',
        viewCount: '0',
        publishedAt: DateTime.utc(2026, 10, 1),
      );

  setUp(() {
    storage = MemoryStorageService();
    settings = AppSettings();
    open = [];
    logged = [];
    late final WatchHistoryController created;
    repository = SettingsRepository(
      writeConfig: () async {},
      writeProgress: () => storage.saveWatchProgress(created.store.toJson()),
      writeRecents: () => storage.saveRecentWatchedVods(
          created.recents.map((v) => v.toJson()).toList()),
    );
    created = history = WatchHistoryController(
      storage: storage,
      repository: repository,
      api: TwitchApiService(),
      settings: () => settings,
      openVods: () => open,
      log: (id, line) => logged.add('$id: $line'),
      clock: () => now,
    );
  });

  tearDown(() {
    repository.dispose();
    storage.dispose();
  });

  test('the sidecar is laid over the config\'s flat copy where it has an '
      'entry', () async {
    history.restoreFlat({'1': 600, '2': 30});
    storage.watchProgress = {
      '1': {'p': 600, 'u': 0, 'b': 7200, 'ba': 0, 'r': <dynamic>[]},
    };
    await history.load();
    expect(history.store['1']!.best, 7200);
    expect(history.store['2']!.position, 30, reason: 'only in the config');
    expect(history.flat, {'1': 600, '2': 30});
    expect(repository.historyLoaded, isTrue);
  });

  test('a sidecar that is there but cannot be read is not written over',
      () async {
    // Held open by a backup client at launch, it read as "nothing", the gate
    // opened, and the next save rewrote it from the flat copy: every
    // furthest point and undo trail, gone for good.
    history.restoreFlat({'1': 600});
    storage.historyReadFailure =
        StorageReadFailure('watch_progress.json', 'in use');
    await history.load();
    expect(repository.historyLoaded, isFalse);

    await repository.flushNow();
    expect(storage.progressWrites, 0);

    storage.historyReadFailure = null;
    await history.load();
    expect(repository.historyLoaded, isTrue, reason: 'read at last');
  });

  test('reading it tells what shows it, with the recents in', () async {
    // The welcome screen's Continue watching repaints with this controller
    // alone; until a read said so, it showed an empty strip.
    storage.recents = [vod('1').toJson()];
    final seen = <List<String>>[];
    history.addListener(
        () => seen.add([for (final v in history.recents) v.id]));
    await history.load();
    expect(seen, [
      ['1'],
    ]);
  });

  test('a VOD forgotten before the history is read is written once it has '
      'been, not over it', () async {
    storage.recents = [vod('1').toJson(), vod('2').toJson()];
    await history.forget('9');
    expect(storage.recentsWrites, 0,
        reason: 'the list on disk has not been read yet');

    await history.load();
    await pumpEventQueue();
    expect(storage.recentsWrites, 1);
    expect([for (final r in storage.recents) r['id']], ['1', '2']);

    await history.forget('1');
    expect([for (final r in storage.recents) r['id']], ['2']);
  });

  group('a reported position', () {
    test('moves a playing VOD to the front of the recents, once, and keeps '
        'the list to its length', () async {
      settings.maxRecentlyWatched = 2;
      storage.recents = [vod('1').toJson(), vod('2').toJson()];
      await history.load();
      final playing = vod('3');
      final card = vod('3');
      open.add(card);
      history.startPlaying(playing);
      var notified = 0;
      history.addListener(() => notified++);

      expect(history.record('3', 900, 0.25, 120000), isTrue);
      expect([for (final v in history.recents) v.id], ['3', '1']);
      expect(identical(history.recents.first, playing), isTrue);
      expect(card.watchPosition, 900, reason: 'the card on screen moves too');
      expect(history.flat['3'], 900);
      expect(notified, 1);

      // Same whole percent, already at the front: nothing on screen changes.
      expect(history.record('3', 902, 0.2505, 122000), isTrue);
      expect(notified, 1);
      expect(history.record('3', 940, 0.261, 160000), isTrue);
      expect(notified, 2);
    });

    test('that looks like a failed resume is refused and logged', () {
      history.record('3', 7200, 0.66, 600000);
      expect(history.record('3', 4, 0.0, 3000), isFalse);
      expect(history.store['3']!.position, 7200);
      expect(logged.single, contains('Ignored a watch position of 4s'));
    });

    test('after dispose is kept but announces nothing', () {
      final open = vod('3');
      history.startPlaying(open);
      history.dispose();
      expect(history.record('3', 300, 0.1, 120000), isTrue);
      expect(history.recents, isEmpty);
    });
  });

  test('stopping releases the playing VOD and writes the position now',
      () async {
    await history.load();
    history.startPlaying(vod('3'));
    expect(history.isWatching, isTrue);
    history.record('3', 300, 0.1, 120000);
    expect(storage.progressWrites, 0, reason: 'within the progress delay');

    history.playbackStopped('3');
    await pumpEventQueue();
    expect(history.isWatching, isFalse);
    expect(storage.progressWrites, 1);
    expect(storage.watchProgress['3'], containsPair('p', 300));
  });

  group('the furthest point', () {
    testWidgets('is offered after the delay, read again then', (tester) async {
      history.restoreFlat({});
      history.record('3', 7200, 0.6, 600000);
      history.record('3', 600, 0.05, 600000);
      var playing = true;
      final offers = <int>[];
      history.offerFurthestPosition(vod('3'),
          stillPlaying: () => playing, offer: offers.add);
      await tester.pump(WatchHistoryController.offerDelay -
          const Duration(milliseconds: 1));
      expect(offers, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(offers, [7200]);

      // Stopped by then, or past it by then: nothing.
      playing = false;
      history.offerFurthestPosition(vod('3'),
          stillPlaying: () => playing, offer: offers.add);
      await tester.pump(WatchHistoryController.offerDelay);
      playing = true;
      history.offerFurthestPosition(vod('3'),
          stillPlaying: () => playing, offer: offers.add);
      history.record('3', 7300, 0.61, 600000);
      await tester.pump(WatchHistoryController.offerDelay);
      expect(offers, [7200]);
      // Its progress-delay timer, which fake time would otherwise leave
      // pending.
      repository.dispose();
    });

    testWidgets('is not offered once the history has gone with its screen',
        (tester) async {
      // The message itself is the screen's to drop, but nothing should be
      // asked of a player or a screen after that.
      history.restoreFlat({});
      history.record('3', 7200, 0.6, 600000);
      history.record('3', 600, 0.05, 600000);
      var asked = 0;
      final offers = <int>[];
      history.offerFurthestPosition(vod('3'), stillPlaying: () {
        asked++;
        return true;
      }, offer: offers.add);
      history.dispose();
      await tester.pump(WatchHistoryController.offerDelay);
      expect(asked, 0);
      expect(offers, isEmpty);
      // Its progress-delay timer, which fake time would otherwise leave
      // pending.
      repository.dispose();
    });

    test('is not offered for a VOD with nothing to go back to', () async {
      history.record('3', 600, 0.05, 600000);
      final offers = <int>[];
      history.offerFurthestPosition(vod('3'),
          stillPlaying: () => true, offer: offers.add);
      await Future<void>.delayed(Duration.zero);
      expect(offers, isEmpty);
    });
  });

  group('marking', () {
    test('watched records the full length; unwatched clears the furthest '
        'point too', () {
      final a = vod('1', duration: '1h0m0s');
      history.record('1', 3000, 0.8, 600000);
      expect(history.mark([a], watched: true), 1);
      expect(history.flat['1'], 3600);
      expect(a.watchProgress, 1.0);

      expect(history.mark([a], watched: false), 1);
      expect(history.store['1'], isNull);
      expect(history.flat['1'], 0);
      expect(a.watchPosition, 0);
    });

    test('says what it did, and when Twitch may undo it', () {
      expect(history.markedMessage(2, watched: false),
          startsWith('Marked 2 VODs unwatched here. Twitch does not accept'));
      expect(history.markedMessage(2, watched: true),
          startsWith('Marked 2 VODs watched here.'));
      settings.twitchWebOauthToken = 'oauth:browser';
      expect(history.markedMessage(2, watched: false),
          contains('may come back on the next refresh'));
    });
  });

  test('clearing takes every position, and the cards on screen', () async {
    await history.load();
    final a = vod('1')
      ..watchPosition = 100
      ..watchProgress = 0.03;
    open.add(a);
    history.record('1', 100, 0.03, 600000);
    history.record('2', 50, 0.01, 600000);
    await history.clearAll();
    expect(history.flat, isEmpty);
    expect(history.store.entries, isEmpty);
    expect(a.watchPosition, 0);
    expect(a.watchProgress, 0.0);
    expect(storage.watchProgress, isEmpty);
  });

  test('clockLabel', () {
    expect(WatchHistoryController.clockLabel(7200), '2:00:00');
    expect(WatchHistoryController.clockLabel(605), '10:05');
  });
}
