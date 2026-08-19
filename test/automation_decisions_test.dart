import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/state/automation_decisions.dart';

TwitchChannel channel(
  String name, {
  bool autoPlay = true,
  int priority = 0,
  bool live = false,
  String? streamId,
  bool loading = false,
  bool autoDownload = false,
  int keep = 1,
  bool stopAtWatched = true,
  DateTime? wentLive,
}) {
  final c = TwitchChannel(
    username: name,
    autoPlayLive: autoPlay,
    autoPlayPriority: priority,
    autoDownloadVods: autoDownload,
    maxVodKeepCount: keep,
    stopAtLastWatchedVod: stopAtWatched,
  );
  c.isLive = live;
  c.streamId = streamId;
  c.isLoading = loading;
  c.wentLiveTime = wentLive;
  return c;
}

TwitchVideo vod(String id, {required int daysAgo, double? progress, String duration = '2h0m0s'}) {
  return TwitchVideo(
    id: id,
    title: 'VOD $id',
    duration: duration,
    thumbnailUrl: '',
    viewCount: '0',
    publishedAt: DateTime(2026, 1, 30).subtract(Duration(days: daysAgo)),
    watchProgress: progress,
  );
}

void main() {
  group('buildSessionKey', () {
    test('is stable across polls for the same broadcast', () {
      // Regression: the key used to fall back to TwitchChannel.uptime, which is
      // a human-readable string including seconds ("3h 12m 07s"), so it changed
      // on EVERY 60s poll. That defeated "auto-play once per live session"
      // entirely: closing the player relaunched the stream a minute later.
      final c = channel('someone', live: true, streamId: '4567');
      final first = buildSessionKey(c);

      c.uptime = '3h 12m 07s';
      c.viewerCount = '1234';
      c.streamTitle = 'title changed mid-stream';
      final later = buildSessionKey(c);

      expect(later, first);
    });

    test('differs between consecutive broadcasts', () {
      final a = channel('someone', live: true, streamId: '1');
      final b = channel('someone', live: true, streamId: '2');
      expect(buildSessionKey(a), isNot(buildSessionKey(b)));
    });

    test('falls back to wentLiveTime when no stream id is available', () {
      final c = channel('someone', live: true, wentLive: DateTime(2026, 5, 1, 12));
      expect(buildSessionKey(c), contains('someone@'));
      expect(buildSessionKey(c), buildSessionKey(c));
    });

    test('is still stable with neither stream id nor go-live time', () {
      final c = channel('someone', live: true);
      c.uptime = '1h 0m 1s';
      final first = buildSessionKey(c);
      c.uptime = '1h 0m 2s';
      expect(buildSessionKey(c), first);
    });
  });

  group('decideAutoPlay', () {
    AutoPlayDecision decide(
      List<TwitchChannel> channels, {
      Set<String> running = const {},
      Map<String, String> played = const {},
      bool watchingVod = false,
      bool updating = false,
      bool preempt = false,
    }) {
      return decideAutoPlay(
        channels: channels,
        runningChannels: running,
        playedSessions: Map<String, String>.from(played),
        isWatchingVod: watchingVod,
        isUpdateActive: updating,
        preemptLowerPriority: preempt,
      );
    }

    test('launches the highest priority live channel', () {
      final d = decide([
        channel('high', priority: 0, live: true, streamId: 's1'),
        channel('low', priority: 1, live: true, streamId: 's2'),
      ]);
      expect(d.shouldLaunch, isTrue);
      expect(d.channelToPlay!.username, 'high');
    });

    test('skips offline channels and picks the next live one', () {
      final d = decide([
        channel('high', priority: 0, live: false),
        channel('low', priority: 1, live: true, streamId: 's2'),
      ]);
      expect(d.channelToPlay!.username, 'low');
    });

    test('stands down while a VOD is playing', () {
      final d = decide(
        [channel('a', live: true, streamId: 's')],
        watchingVod: true,
      );
      expect(d.shouldLaunch, isFalse);
      expect(d.reason, AutoPlaySkipReason.watchingVod);
    });

    test('stands down during an app update', () {
      final d = decide([channel('a', live: true, streamId: 's')], updating: true);
      expect(d.reason, AutoPlaySkipReason.updateInProgress);
    });

    test('waits while any priority channel is still refreshing', () {
      // Otherwise a lower-priority stream can start before a higher-priority
      // channel is known to be live.
      final d = decide([
        channel('high', priority: 0, loading: true),
        channel('low', priority: 1, live: true, streamId: 's2'),
      ]);
      expect(d.shouldLaunch, isFalse);
      expect(d.reason, AutoPlaySkipReason.stillLoadingLiveStatus);
    });

    test('does not relaunch the same session twice', () {
      final live = channel('a', live: true, streamId: 's1');
      final key = buildSessionKey(live);
      final d = decide([live], played: {'a': key});
      expect(d.shouldLaunch, isFalse);
      expect(d.reason, AutoPlaySkipReason.alreadyPlayedThisSession);
    });

    test('does relaunch for a NEW broadcast of the same channel', () {
      final previous = buildSessionKey(channel('a', live: true, streamId: 'old'));
      final d = decide(
        [channel('a', live: true, streamId: 'new')],
        played: {'a': previous},
      );
      expect(d.shouldLaunch, isTrue);
    });

    test('records the session when the stream is already running', () {
      // So that closing the player does not cause a relaunch next tick.
      final d = decide(
        [channel('a', live: true, streamId: 's1')],
        running: {'a'},
      );
      expect(d.shouldLaunch, isFalse);
      expect(d.reason, AutoPlaySkipReason.alreadyRunning);
      expect(d.sessionKeyToRecord, isNotNull);
    });

    test('yields to a higher priority channel that is already playing', () {
      final d = decide([
        channel('high', priority: 0, live: true, streamId: 's1'),
        channel('low', priority: 1, live: true, streamId: 's2'),
      ], running: {'high'}, played: {'high': buildSessionKey(channel('high', live: true, streamId: 's1'))});
      expect(d.shouldLaunch, isFalse);
    });

    test('preempts lower priority streams only when enabled', () {
      final channels = [
        channel('high', priority: 0, live: true, streamId: 's1'),
        channel('low', priority: 1, live: true, streamId: 's2'),
      ];

      final without = decide(channels, running: {'low'});
      expect(without.channelToPlay!.username, 'high');
      expect(without.channelsToPreempt, isEmpty);

      final with_ = decide(channels, running: {'low'}, preempt: true);
      expect(with_.channelToPlay!.username, 'high');
      expect(with_.channelsToPreempt, ['low']);
    });

    test('ignores channels that do not have auto-play enabled', () {
      final d = decide([channel('a', autoPlay: false, live: true, streamId: 's')]);
      expect(d.shouldLaunch, isFalse);
      expect(d.reason, AutoPlaySkipReason.noPriorityChannels);
    });

    test('reports nothing live when no priority channel is broadcasting', () {
      final d = decide([channel('a', live: false), channel('b', priority: 1, live: false)]);
      expect(d.reason, AutoPlaySkipReason.nothingLive);
    });
  });

  group('selectVodsToAutoDownload', () {
    AppSettings settingsWith(int threshold) =>
        AppSettings(vodWatchExclusionThreshold: threshold, vodDownloadFolder: 'D:/x');

    test('returns unwatched VODs oldest first', () {
      final selected = selectVodsToAutoDownload(
        channel: channel('a', autoDownload: true, keep: 3),
        vods: [vod('new', daysAgo: 1), vod('mid', daysAgo: 2), vod('old', daysAgo: 3)],
        localProgress: const {},
        settings: settingsWith(15),
        isAlreadyHandled: (_) => false,
      );
      expect(selected.map((v) => v.id), ['old', 'mid', 'new']);
    });

    test('honours the per-channel keep count', () {
      final selected = selectVodsToAutoDownload(
        channel: channel('a', autoDownload: true, keep: 2),
        vods: [vod('a1', daysAgo: 1), vod('a2', daysAgo: 2), vod('a3', daysAgo: 3)],
        localProgress: const {},
        settings: settingsWith(15),
        isAlreadyHandled: (_) => false,
      );
      expect(selected, hasLength(2));
    });

    test('the exclusion threshold actually excludes partially watched VODs', () {
      // Regression: the per-channel "stop at last watched" break ran BEFORE the
      // threshold test, so every surviving VOD had progress <= 5% and therefore
      // always passed. With the per-channel option on - its default - moving the
      // exclusion slider changed nothing whatsoever.
      final vods = [vod('watched', daysAgo: 1, progress: 0.40), vod('fresh', daysAgo: 2)];

      // Threshold 15%: the 40%-watched VOD is excluded, and because
      // stopAtLastWatchedVod is on it also stops collection there.
      final strict = selectVodsToAutoDownload(
        channel: channel('a', autoDownload: true, keep: 5, stopAtWatched: true),
        vods: vods,
        localProgress: const {},
        settings: settingsWith(15),
        isAlreadyHandled: (_) => false,
      );
      expect(strict.map((v) => v.id), isEmpty);

      // Threshold 80%: 40% is now under the limit, so it is downloaded again.
      final lenient = selectVodsToAutoDownload(
        channel: channel('a', autoDownload: true, keep: 5, stopAtWatched: true),
        vods: vods,
        localProgress: const {},
        settings: settingsWith(80),
        isAlreadyHandled: (_) => false,
      );
      expect(lenient.map((v) => v.id), ['fresh', 'watched']);
    });

    test('without stopAtLastWatched it keeps scanning past a watched VOD', () {
      final selected = selectVodsToAutoDownload(
        channel: channel('a', autoDownload: true, keep: 5, stopAtWatched: false),
        vods: [vod('watched', daysAgo: 1, progress: 0.9), vod('fresh', daysAgo: 2)],
        localProgress: const {},
        settings: settingsWith(15),
        isAlreadyHandled: (_) => false,
      );
      expect(selected.map((v) => v.id), ['fresh']);
    });

    test('prefers locally tracked progress over the server value', () {
      final selected = selectVodsToAutoDownload(
        channel: channel('a', autoDownload: true, keep: 5, stopAtWatched: false),
        // 2h VOD; 5400s watched locally = 75%, above the 15% threshold.
        vods: [vod('v1', daysAgo: 1, duration: '2h0m0s')],
        localProgress: const {'v1': 5400},
        settings: settingsWith(15),
        isAlreadyHandled: (_) => false,
      );
      expect(selected, isEmpty);
    });

    test('skips VODs already downloaded or in flight', () {
      final selected = selectVodsToAutoDownload(
        channel: channel('a', autoDownload: true, keep: 5),
        vods: [vod('done', daysAgo: 1), vod('todo', daysAgo: 2)],
        localProgress: const {},
        settings: settingsWith(15),
        isAlreadyHandled: (id) => id == 'done',
      );
      expect(selected.map((v) => v.id), ['todo']);
    });

    test('returns nothing for an empty VOD list', () {
      expect(
        selectVodsToAutoDownload(
          channel: channel('a', autoDownload: true),
          vods: const [],
          localProgress: const {},
          settings: settingsWith(15),
          isAlreadyHandled: (_) => false,
        ),
        isEmpty,
      );
    });
  });

  group('parseDurationSeconds', () {
    test('parses Twitch duration strings', () {
      expect(parseDurationSeconds('1h2m3s'), 3723);
      expect(parseDurationSeconds('45m'), 2700);
      expect(parseDurationSeconds('30s'), 30);
      expect(parseDurationSeconds('2h'), 7200);
      expect(parseDurationSeconds(''), 0);
      expect(parseDurationSeconds('garbage'), 0);
    });
  });
}
