import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/services/automation_service.dart';
import 'package:streamlink_gui/services/twitch_api_service.dart'
    show VodsFetchResult;

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
  Rig() {
    settings.vodDownloadFolder = r'D:\VODs';
  }

  final List<TwitchChannel> favorites = [];
  final AppSettings settings = AppSettings();
  final Set<String> running = {};
  bool watchingVod = false;
  bool updateActive = false;

  final Map<String, List<TwitchVideo>> vodsByChannel = {};
  final Set<String> failingChannels = {};
  final Set<String> handled = {};

  /// When set, every VOD fetch waits on it.
  Completer<void>? fetchGate;

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
    localProgress: () => const {},
    isVodHandled: handled.contains,
    queueDownload: (v, c, {overrideDisablePostProcessing}) => queued.add(
        (vod: v.id, channel: c.username, fast: overrideDisablePostProcessing)),
    showNotification: (title, body) async {
      if (notificationsFail) throw Exception('toast failed');
      notifications.add(title);
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

    test('skips VODs already handled', () async {
      final rig = Rig()..handled.add('v1');
      rig.favorites.add(channel('a', autoPlay: false, autoDownload: true, keep: 2));
      rig.vodsByChannel['a'] = [vod('v2', daysAgo: 1), vod('v1', daysAgo: 2)];
      await rig.service.runPass();
      expect(rig.queued.map((q) => q.vod), ['v2']);
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
      rig.service.onVodsFetched = (c, result) {
        rig.handedBack.add('${c.username}:${result.vods.length}');
        throw StateError('cache broke');
      };
      await rig.service.runPass();
      expect(rig.handedBack, ['empty:0', 'full:1']);
      expect(rig.queued.map((q) => q.vod), ['v1']);
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
        localProgress: () => const {},
        isVodHandled: (_) => false,
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
