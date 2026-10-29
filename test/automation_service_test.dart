import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/automation_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart'
    show VodsFetchResult;
import 'package:streamlink_gui/state/download_history.dart';
import 'package:streamlink_gui/state/vod_browser_controller.dart';

import 'support/fake_helix.dart';

TwitchChannel channel(
  String name, {
  bool autoPlay = true,
  int priority = 0,
  bool live = false,
  String? streamId,
  bool autoDownload = false,
  bool fast = false,
  int keep = 1,
}) {
  final c = TwitchChannel(
    username: name,
    autoPlayLive: autoPlay,
    autoPlayPriority: priority,
    autoDownloadVods: autoDownload,
    autoDownloadFastDownload: fast,
    maxVodKeepCount: keep,
  );
  c.isLive = live;
  c.streamId = streamId;
  return c;
}

TwitchVideo vod(String id, {required int daysAgo}) => TwitchVideo(
      id: id,
      title: 'VOD $id',
      duration: '2h0m0s',
      thumbnailUrl: '',
      viewCount: '0',
      publishedAt: DateTime(2026, 1, 30).subtract(Duration(days: daysAgo)),
    );

/// The screen, as the service sees it: plain state plus a record of every
/// effect the service asked for.
class Rig {
  Rig({this.allPositionsEvery = const Duration(minutes: 30)}) {
    settings.vodDownloadFolder = r'D:\VODs';
  }

  final Duration allPositionsEvery;

  final List<TwitchChannel> favorites = [];
  final AppSettings settings = AppSettings();
  final Set<String> running = {};
  bool watchingVod = false;
  bool updateActive = false;

  final Map<String, List<TwitchVideo>> vodsByChannel = {};
  final Set<String> failingChannels = {};
  final Set<String> handled = {};
  final DownloadHistory history = DownloadHistory();

  /// Positions recorded in the app, in seconds.
  final Map<String, int> local = {};

  /// How far into each VOD the user is on Twitch; read only on request,
  /// one lookup per VOD, as the browser token's GQL query does.
  final Map<String, double> onTwitch = {};
  final List<String> positionLookups = [];
  DateTime now = DateTime(2026, 1, 30, 12);

  /// When set, every VOD fetch waits on it.
  Completer<void>? fetchGate;

  /// Why the download folder cannot be used; null when it can.
  String? folderProblem;
  int folderChecks = 0;

  final List<String> played = [];
  final List<String> stopped = [];
  final List<String> fetched = [];
  final List<({String vod, String channel, bool? fast})> queued = [];
  final List<String> notifications = [];
  final List<String> handedBack = [];
  final List<String> log = [];
  bool notificationsFail = false;

  late final AutomationService service = AutomationService(
    favorites: () => favorites,
    settings: () => settings,
    runningChannels: () => running,
    isWatchingVod: () => watchingVod,
    isUpdateActive: () => updateActive,
    playLive: (c) {
      played.add(c.username);
      running.add(c.username);
    },
    stopLive: (name) {
      stopped.add(name);
      running.removeWhere((r) => r.toLowerCase() == name);
    },
    fetchVods: (c) async {
      fetched.add(c.username);
      await fetchGate?.future;
      if (failingChannels.contains(c.username)) {
        throw Exception('helix down');
      }
      return VodsFetchResult(vods: vodsByChannel[c.username] ?? const []);
    },
    readWatchProgress: (vods) async {
      for (final v in vods) {
        positionLookups.add(v.id);
        final progress = onTwitch[v.id];
        if (progress != null) v.watchProgress = progress;
      }
    },
    allPositionsEvery: allPositionsEvery,
    clock: () => now,
    localProgress: () => local,
    isVodHandled: handled.contains,
    wasDownloaded: history.contains,
    queueDownload: (v, c, {overrideDisablePostProcessing}) => queued.add(
        (vod: v.id, channel: c.username, fast: overrideDisablePostProcessing)),
    showNotification: (title, body) async {
      if (notificationsFail) throw Exception('toast failed');
      notifications.add(title);
    },
    folderProblem: (_) {
      folderChecks++;
      return folderProblem;
    },
    log: log.add,
  );
}

void main() {
  group('auto-play', () {
    test('launches the live favourite once per broadcast', () async {
      final rig = Rig();
      rig.favorites.add(channel('alpha', live: true, streamId: '1'));

      await rig.service.runPass();
      expect(rig.played, ['alpha']);
      expect(rig.notifications, ['Auto-Playing Live Stream']);

      // The user closes the player; the same broadcast is not relaunched.
      rig.running.clear();
      await rig.service.runPass();
      expect(rig.played, ['alpha']);

      // A new broadcast is.
      rig.favorites.single.streamId = '2';
      await rig.service.runPass();
      expect(rig.played, ['alpha', 'alpha']);
    });

    test('a channel that went offline is forgotten, so its next broadcast '
        'plays even with the same key', () async {
      final rig = Rig();
      final alpha = channel('alpha', live: true);
      rig.favorites.add(alpha);
      await rig.service.runPass();
      rig.running.clear();

      alpha.isLive = false;
      await rig.service.runPass();
      expect(rig.service.playedSessions, isEmpty);

      alpha.isLive = true;
      await rig.service.runPass();
      expect(rig.played, ['alpha', 'alpha']);
    });

    test('a broadcast whose refreshes failed for a while is not relaunched '
        'when they work again', () async {
      // Three failed refreshes show a live channel offline, though Twitch
      // never said so. Forgetting its session then launched the same
      // broadcast again, unasked, the user having closed the player.
      final rig = Rig();
      final alpha = channel('alpha', live: true, streamId: '1');
      rig.favorites.add(alpha);
      await rig.service.runPass();
      rig.running.clear();

      alpha
        ..isLive = false
        ..streamId = null
        ..errorMessage = 'timed out';
      await rig.service.runPass();
      alpha
        ..isLive = true
        ..streamId = '1'
        ..errorMessage = null;
      await rig.service.runPass();

      expect(rig.played, ['alpha']);
      expect(rig.notifications, ['Auto-Playing Live Stream']);
    });

    test('nor is one keyed by its stream id that Twitch briefly reported '
        'offline', () async {
      final rig = Rig();
      final alpha = channel('alpha', live: true, streamId: '1');
      rig.favorites.add(alpha);
      await rig.service.runPass();
      rig.running.clear();

      alpha
        ..isLive = false
        ..streamId = null;
      await rig.service.runPass();
      alpha
        ..isLive = true
        ..streamId = '1';
      await rig.service.runPass();
      expect(rig.played, ['alpha']);

      // Removing the favourite still forgets it.
      rig.favorites.clear();
      await rig.service.runPass();
      expect(rig.service.playedSessions, isEmpty);
    });

    test('an already-running stream is remembered, not relaunched after it '
        'is closed', () async {
      final rig = Rig();
      rig.favorites.add(channel('Alpha', live: true, streamId: '9'));
      rig.running.add('ALPHA ');

      await rig.service.runPass();
      expect(rig.played, isEmpty);
      expect(rig.service.playedSessions, {'alpha': 'alpha#9'});

      rig.running.clear();
      await rig.service.runPass();
      expect(rig.played, isEmpty);
    });

    test('lower-priority streams are stopped when preemption is on', () async {
      final rig = Rig()..settings.autoPlayPreemptLowerPriority = true;
      rig.favorites
        ..add(channel('top', priority: 0, live: true, streamId: '1'))
        ..add(channel('low', priority: 1, live: true, streamId: '2'));
      rig.running.add('low');

      await rig.service.runPass();
      expect(rig.stopped, ['low']);
      expect(rig.played, ['top']);
    });

    test('stands down while a VOD is watched or an update runs', () async {
      final rig = Rig();
      rig.favorites.add(channel('alpha', live: true, streamId: '1'));

      rig.watchingVod = true;
      await rig.service.runPass();
      rig.watchingVod = false;
      rig.updateActive = true;
      await rig.service.runPass();
      expect(rig.played, isEmpty);
      expect(rig.log, contains('[Auto-Play] No action: watchingVod'));
      expect(rig.log, contains('[Auto-Play] No action: updateInProgress'));

      rig.updateActive = false;
      await rig.service.runPass();
      expect(rig.played, ['alpha']);
    });

    test('no notification when they are off, and a failing one breaks '
        'nothing', () async {
      final rig = Rig()..settings.notifyAutoPlay = false;
      rig.favorites.add(channel('alpha',
          live: true, streamId: '1', autoDownload: true));
      rig.vodsByChannel['alpha'] = [vod('v1', daysAgo: 1)];
      await rig.service.runPass();
      expect(rig.played, ['alpha']);
      expect(rig.notifications, ['Auto-Downloading VOD']);

      final failing = Rig()..notificationsFail = true;
      failing.favorites.add(channel('alpha',
          live: true, streamId: '1', autoDownload: true));
      failing.vodsByChannel['alpha'] = [vod('v1', daysAgo: 1)];
      await failing.service.runPass();
      expect(failing.played, ['alpha']);
      expect(failing.queued.map((q) => q.vod), ['v1'],
          reason: 'the download pass still runs after a failed toast');
      expect(failing.log.where((l) => l.contains('Notification Error')),
          hasLength(2));
    });

    test('forgetChannel lets a re-added favourite play again', () async {
      final rig = Rig();
      rig.favorites.add(channel('alpha', live: true, streamId: '1'));
      await rig.service.runPass();
      rig.running.clear();

      rig.service.forgetChannel(' Alpha');
      await rig.service.runPass();
      expect(rig.played, ['alpha', 'alpha']);
    });
  });

  group('auto-download', () {
    test('queues the oldest unhandled VODs in the window, fast only when the '
        'channel opts in', () async {
      final rig = Rig();
      rig.favorites
        ..add(channel('fast', autoPlay: false, autoDownload: true, fast: true,
            keep: 2))
        ..add(channel('slow', autoPlay: false, autoDownload: true, keep: 1));
      rig.vodsByChannel['fast'] = [
        vod('f3', daysAgo: 1),
        vod('f2', daysAgo: 2),
        vod('f1', daysAgo: 3),
      ];
      rig.vodsByChannel['slow'] = [vod('s1', daysAgo: 1)];

      await rig.service.runPass();
      expect(rig.queued, [
        (vod: 'f1', channel: 'fast', fast: true),
        (vod: 'f2', channel: 'fast', fast: true),
        (vod: 's1', channel: 'slow', fast: null),
      ]);
    });

    test('a folder that cannot be used queues nothing, and is logged once',
        () async {
      // An unplugged drive: every VOD the pass queued failed at once, and the
      // next pass queued them again - two toasts each, every minute.
      final rig = Rig()..folderProblem = 'The device is not ready.';
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true, keep: 2));
      rig.vodsByChannel['a'] = [vod('v2', daysAgo: 1), vod('v1', daysAgo: 2)];

      await rig.service.runPass();
      await rig.service.runPass();
      expect(rig.queued, isEmpty);
      expect(rig.notifications, isEmpty);
      expect(rig.log.where((l) => l.contains('cannot be used')), hasLength(1));
      expect(rig.folderChecks, 2, reason: 'once a pass, not once a VOD');

      rig.folderProblem = null;
      await rig.service.runPass();
      expect(rig.queued.map((q) => q.vod), ['v1', 'v2']);
    });

    test('nothing to queue, nothing to check', () async {
      final rig = Rig()..handled.add('v1');
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true));
      rig.vodsByChannel['a'] = [vod('v1', daysAgo: 1)];
      await rig.service.runPass();
      expect(rig.folderChecks, 0);
    });

    test('a VOD whose download failed is tried again later, not every pass, '
        'and announced once', () async {
      // A failure is recorded nowhere: the next pass, a minute later, queued
      // it again, and a download that kept failing did so every minute.
      final rig = Rig();
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true));
      rig.vodsByChannel['a'] = [vod('v1', daysAgo: 1)];

      await rig.service.runPass(); // queued; it fails: in no list afterwards
      rig.now = rig.now.add(const Duration(minutes: 1));
      await rig.service.runPass();
      expect(rig.queued.map((q) => q.vod), ['v1']);

      rig.now = rig.now.add(AutomationService.retryAfterFailure.first);
      await rig.service.runPass();
      expect(rig.queued.map((q) => q.vod), ['v1', 'v1']);
      expect(rig.notifications, ['Auto-Downloading VOD'],
          reason: 'the retry is not news; its failure had a toast of its own');

      rig.now = rig.now.add(AutomationService.retryAfterFailure.first);
      await rig.service.runPass();
      expect(rig.queued, hasLength(2), reason: 'backing off');
    });

    test('skips VODs already handled', () async {
      final rig = Rig()..handled.add('v1');
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true, keep: 2));
      rig.vodsByChannel['a'] = [vod('v2', daysAgo: 1), vod('v1', daysAgo: 2)];
      await rig.service.runPass();
      expect(rig.queued.map((q) => q.vod), ['v2']);
    });

    group('a VOD downloaded once', () {
      // Deleting a download takes its archive line out too, so nothing but
      // the download history remembers it once its file is gone.
      final at = DateTime(2026, 1, 30);

      /// Each download the pass queued completes, as the screen records it:
      /// on disk (handled) and in the history. Then retention keeps the
      /// newest [keep] on disk, and the scan forgets the rest.
      void downloadsComplete(Rig rig, List<String> onDisk, int done,
          {required int keep}) {
        for (final q in rig.queued.skip(done)) {
          onDisk.add(q.vod);
          rig.handled.add(q.vod);
          rig.history.record(q.vod, at);
        }
        while (onDisk.length > keep) {
          rig.handled.remove(onDisk.removeAt(0));
        }
      }

      test('is not fetched again when retention keeps fewer than the window',
          () async {
        // Three VODs in the window, two kept on disk: retention deleted the
        // oldest, the pass found it missing and fetched it again, and
        // retention deleted the next - every pass.
        final rig = Rig();
        rig.favorites
            .add(channel('a', autoPlay: false, autoDownload: true, keep: 3));
        rig.vodsByChannel['a'] = [
          vod('v3', daysAgo: 1),
          vod('v2', daysAgo: 2),
          vod('v1', daysAgo: 3),
        ];
        final onDisk = <String>[];
        for (var pass = 0; pass < 5; pass++) {
          final done = rig.queued.length;
          await rig.service.runPass();
          downloadsComplete(rig, onDisk, done, keep: 2);
        }
        expect(rig.queued.map((q) => q.vod), ['v1', 'v2', 'v3'],
            reason: 'each once, over five passes');
      });

      test('is not fetched again after the user deletes it', () async {
        // Unwatched and still inside its window, it came straight back.
        final rig = Rig();
        rig.favorites
            .add(channel('a', autoPlay: false, autoDownload: true, keep: 2));
        rig.vodsByChannel['a'] = [vod('v2', daysAgo: 1), vod('v1', daysAgo: 2)];
        final onDisk = <String>[];
        await rig.service.runPass();
        downloadsComplete(rig, onDisk, 0, keep: 2);
        expect(rig.queued.map((q) => q.vod), ['v1', 'v2']);

        rig.handled.remove('v1');
        await rig.service.runPass();
        await rig.service.runPass();
        expect(rig.queued.map((q) => q.vod), ['v1', 'v2']);
      });

      test('still holds its place in the window', () async {
        // Counted as kept, as when it was on disk: the window does not move
        // on to a newer VOD because an older one was deleted.
        final rig = Rig()..history.record('v1', at);
        rig.favorites
            .add(channel('a', autoPlay: false, autoDownload: true, keep: 1));
        rig.vodsByChannel['a'] = [vod('v2', daysAgo: 1), vod('v1', daysAgo: 2)];
        await rig.service.runPass();
        expect(rig.queued, isEmpty);
      });
    });

    test('a VOD whose download the user cancelled is left alone, and the '
        'window does not move on past it', () async {
      // The cancel was recorded nowhere, so the next pass queued the VOD
      // again. The screen records it in the history now (PlayerEvents); a
      // newer VOD starting in its place a minute later would read as the
      // cancel not having worked either.
      final rig = Rig();
      rig.favorites
          .add(channel('a', autoPlay: false, autoDownload: true, keep: 1));
      rig.vodsByChannel['a'] = [vod('v2', daysAgo: 1), vod('v1', daysAgo: 2)];
      await rig.service.runPass();
      expect(rig.queued.map((q) => q.vod), ['v1']);

      // Cancelled: no longer queued, and recorded as the screen does.
      rig.history.record('v1', DateTime(2026, 1, 30));
      for (var pass = 0; pass < 3; pass++) {
        await rig.service.runPass();
      }
      expect(rig.queued.map((q) => q.vod), ['v1'], reason: 'three passes on');
    });

    test('does nothing, not even a fetch, without a download folder', () async {
      final rig = Rig()..settings.vodDownloadFolder = '  ';
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true));
      await rig.service.runPass();
      expect(rig.fetched, isEmpty);
      expect(rig.log,
          contains('[Auto-Download] Skipped: no VOD download folder configured.'));
    });

    test('one channel failing does not stop the next', () async {
      final rig = Rig()..failingChannels.add('a');
      rig.favorites
        ..add(channel('a', autoPlay: false, autoDownload: true))
        ..add(channel('b', autoPlay: false, autoDownload: true));
      rig.vodsByChannel['b'] = [vod('b1', daysAgo: 1)];
      await rig.service.runPass();
      expect(rig.fetched, ['a', 'b']);
      expect(rig.queued.map((q) => q.vod), ['b1']);
      expect(rig.log.any((l) => l.startsWith('[Auto-Download Error] Failed for @a')),
          isTrue);
    });

    test('hands every fetched list back, empty ones too, and a throwing '
        'hand-off stops nothing', () async {
      final rig = Rig();
      rig.favorites
        ..add(channel('empty', autoPlay: false, autoDownload: true))
        ..add(channel('full', autoPlay: false, autoDownload: true));
      rig.vodsByChannel['full'] = [vod('v1', daysAgo: 1)];
      rig.service.onVodsFetched = (c, result, fetchedAt) {
        rig.handedBack.add('${c.username}:${result.vods.length}');
        throw StateError('cache broke');
      };
      await rig.service.runPass();
      expect(rig.handedBack, ['empty:0', 'full:1']);
      expect(rig.queued.map((q) => q.vod), ['v1']);
    });

    test('a list handed back is stamped with when its request began, not '
        'when it arrived', () async {
      // The VOD browser orders what it is given by that stamp: a list
      // stamped on arrival would beat a user's refresh that began after this
      // request and finished before it, and put the older list on screen.
      final rig = Rig()..fetchGate = Completer<void>();
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true));
      rig.vodsByChannel['a'] = [vod('v1', daysAgo: 1)];
      final stamps = <DateTime>[];
      rig.service.onVodsFetched = (c, result, fetchedAt) => stamps.add(fetchedAt);

      final pass = rig.service.runPass();
      await pumpEventQueue();
      expect(rig.fetched, ['a'], reason: 'the request is under way');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final answeredAt = DateTime.now();
      rig.fetchGate!.complete();
      await pass;

      expect(stamps, hasLength(1));
      expect(stamps.single.isBefore(answeredAt), isTrue);
    });
  });

  group('the "New VOD" toast beside auto-download', () {
    /// A favourite that auto-downloads, whose last VOD has been watched, so
    /// the window auto-download keeps is whatever comes after it.
    (Rig, TwitchChannel, TwitchVideo, TwitchVideo) watchedThenNew() {
      final rig = Rig();
      final a = channel('a', autoPlay: false, autoDownload: true);
      rig.favorites.add(a);
      final watched = vod('v1', daysAgo: 2)..watchProgress = 1.0;
      final fresh = vod('v2', daysAgo: 1);
      return (rig, a, watched, fresh);
    }

    test('one toast for a VOD the pass downloads, not two', () async {
      // The order main.dart wires: the pass hands its list to the VOD
      // browser, whose new-VOD check fires before anything is queued.
      final (rig, _, watched, fresh) = watchedThenNew();
      final browser = VodBrowserController(
        api: FakeHelix().service(),
        settings: () => rig.settings,
        localProgress: () => <String, int>{},
      );
      addTearDown(browser.dispose);
      browser.onNewVods = (c, vods, page) {
        if (rig.service.newVodsToAnnounce(c, vods, page).isNotEmpty) {
          rig.notifications.add('New VOD from ${c.username}');
        }
      };
      rig.service.onVodsFetched = (c, result, fetchedAt) =>
          browser.ingest(c, result, fetchedAt: fetchedAt, detailed: false);

      rig.vodsByChannel['a'] = [watched];
      await rig.service.runPass();
      expect(rig.notifications, isEmpty, reason: 'the first list is a baseline');

      rig.vodsByChannel['a'] = [fresh, watched];
      await rig.service.runPass();

      expect(rig.queued.map((q) => q.vod), ['v2']);
      expect(rig.notifications, ['Auto-Downloading VOD']);
    });

    test('a VOD the pass does not take is still announced', () {
      // Keep 1, nothing watched: the window is the OLDEST unwatched VOD.
      final rig = Rig();
      final a = channel('a', autoPlay: false, autoDownload: true);
      final older = vod('v1', daysAgo: 2);
      final fresh = vod('v2', daysAgo: 1);
      expect(rig.service.newVodsToAnnounce(a, [fresh], [fresh, older]),
          [fresh]);
    });

    test('nothing is left out when the pass would not announce it', () {
      final (rig, a, watched, fresh) = watchedThenNew();
      final page = [fresh, watched];
      expect(rig.service.newVodsToAnnounce(a, [fresh], page), isEmpty,
          reason: 'precondition: the pass would take it and say so');

      rig.settings.notifyAutoDownloadStart = false;
      expect(rig.service.newVodsToAnnounce(a, [fresh], page), [fresh],
          reason: 'its toasts are off');

      rig.settings
        ..notifyAutoDownloadStart = true
        ..vodDownloadFolder = '';
      expect(rig.service.newVodsToAnnounce(a, [fresh], page), [fresh],
          reason: 'no folder, so the pass is skipped');

      rig.settings.vodDownloadFolder = r'D:\VODs';
      a.autoDownloadVods = false;
      expect(rig.service.newVodsToAnnounce(a, [fresh], page), [fresh],
          reason: 'not an auto-download favourite');
    });
  });

  group("the auto-download pass's watch positions", () {
    // One GQL request per VOD, every pass, for every auto-download favourite
    // with a browser token: twenty a minute each, nearly all for VODs the
    // pass was never going to queue.
    void sixVods(Rig rig, {required int keep}) {
      rig.favorites
          .add(channel('a', autoPlay: false, autoDownload: true, keep: keep));
      rig.vodsByChannel['a'] = [
        for (var i = 6; i >= 1; i--) vod('v$i', daysAgo: 7 - i),
      ];
    }

    test('are read for the VODs it would queue, and all of them now and then',
        () async {
      final rig = Rig();
      sixVods(rig, keep: 2);
      await rig.service.runPass();
      expect(rig.positionLookups, hasLength(6), reason: 'the first pass');
      expect(rig.queued.map((q) => q.vod), ['v1', 'v2']);
      rig.handled.addAll(['v1', 'v2']);

      rig.positionLookups.clear();
      for (var pass = 0; pass < 5; pass++) {
        rig.now = rig.now.add(const Duration(minutes: 1));
        await rig.service.runPass();
      }
      expect(rig.positionLookups, isEmpty,
          reason: 'nothing to queue, so nothing to read');

      // Watched in the app, the window moves on to one new to it.
      rig.local['v1'] = 7200;
      rig.now = rig.now.add(const Duration(minutes: 1));
      await rig.service.runPass();
      expect(rig.positionLookups, ['v3']);
      expect(rig.queued.map((q) => q.vod), ['v1', 'v2', 'v3']);
      rig.handled.add('v3');

      // Watching on Twitch moves the window too, so every VOD is read again
      // once in a while.
      rig.positionLookups.clear();
      rig.now = rig.now.add(const Duration(minutes: 30));
      await rig.service.runPass();
      expect(rig.positionLookups, hasLength(6));
    });

    test('decide what reading every position decided', () async {
      // The oldest in the window was watched in the app, and the two after
      // it on Twitch: each turns out watched only once it is read, which
      // moves the window on to one more VOD to read.
      final rigs = [Rig(), Rig(allPositionsEvery: Duration.zero)];
      for (final rig in rigs) {
        sixVods(rig, keep: 1);
        rig.handled.add('v1');
        await rig.service.runPass();
        expect(rig.queued, isEmpty);
        rig.positionLookups.clear();

        rig.local['v1'] = 7200;
        rig.onTwitch
          ..['v2'] = 0.95
          ..['v3'] = 0.95;
        rig.now = rig.now.add(const Duration(minutes: 1));
        await rig.service.runPass();
      }
      final [onlyQueued, everyVod] = rigs;
      expect(onlyQueued.queued.map((q) => q.vod), ['v4']);
      expect(everyVod.queued.map((q) => q.vod), ['v4']);
      expect(onlyQueued.positionLookups, ['v2', 'v3', 'v4']);
      expect(everyVod.positionLookups, hasLength(6));
    });
  });

  group('one pass at a time', () {
    test('a pass started while one awaits VOD lists does nothing', () async {
      final rig = Rig()..fetchGate = Completer<void>();
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true));
      rig.vodsByChannel['a'] = [vod('v1', daysAgo: 1)];

      final first = rig.service.runPass();
      await pumpEventQueue();
      expect(rig.service.isPassRunning, isTrue);

      await rig.service.runPass();
      expect(rig.fetched, ['a'], reason: 'the second pass returned at once');

      rig.fetchGate!.complete();
      await first;
      expect(rig.service.isPassRunning, isFalse);
      expect(rig.queued.map((q) => q.vod), ['v1'],
          reason: 'queued once, not once per overlapping pass');

      // And the next pass after it runs normally.
      rig.fetchGate = null;
      await rig.service.runPass();
      expect(rig.fetched, ['a', 'a']);
    });

    test('a pass that throws still releases the guard', () async {
      var explode = true;
      final service = AutomationService(
        favorites: () => explode ? throw StateError('boom') : const [],
        settings: AppSettings.new,
        runningChannels: () => const [],
        isWatchingVod: () => false,
        isUpdateActive: () => false,
        playLive: (_) {},
        stopLive: (_) {},
        fetchVods: (_) async => VodsFetchResult(vods: const []),
        readWatchProgress: (_) async {},
        localProgress: () => const {},
        isVodHandled: (_) => false,
        wasDownloaded: (_) => false,
        queueDownload: (v, c, {overrideDisablePostProcessing}) {},
        showNotification: (_, _) async {},
        log: (_) {},
      );
      await expectLater(service.runPass(), throwsStateError);
      expect(service.isPassRunning, isFalse);
      explode = false;
      await service.runPass();
    });
  });
}
