import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/state/channel_transitions.dart';

/// Went-live and went-offline, as a pure function.
///
/// This decides every "is now LIVE!" toast and feeds auto-play, and it lived
/// inline in the refresh with no test at all.
final DateTime t0 = DateTime(2026, 10, 28, 12);

TwitchChannel ch(String name, {bool live = false, bool observed = true, String? streamId}) {
  final c = TwitchChannel(username: name)
    ..isLive = live
    ..streamId = streamId ?? (live ? 'stream-$name' : null);
  if (observed) c.lastUpdated = t0;
  return c;
}

void main() {
  group('detectLiveTransitions', () {
    test('the first pass of a session announces nothing', () {
      // What is live when the app starts is not news; it is recorded so the
      // next pass does not announce it either.
      final a = ch('a', observed: false);
      final before = snapshotChannels([a]);
      a
        ..isLive = true
        ..lastUpdated = t0;

      final t = detectLiveTransitions(
          channels: [a], before: before, announced: {}, isInitialLoad: true);

      expect(t.wentLive, isEmpty);
      expect(t.announced, {'a'});
    });

    test('offline to live is announced once', () {
      final a = ch('a');
      final before = snapshotChannels([a]);
      a.isLive = true;

      final first = detectLiveTransitions(
          channels: [a], before: before, announced: {}, isInitialLoad: false);
      final second = detectLiveTransitions(
          channels: [a],
          before: snapshotChannels([a]),
          announced: first.announced,
          isInitialLoad: false);

      expect(first.wentLive, [a]);
      expect(second.wentLive, isEmpty);
    });

    test('live to offline is reported, and the next broadcast is news again', () {
      final a = ch('a', live: true);
      var before = snapshotChannels([a]);
      a.isLive = false;
      final ended = detectLiveTransitions(
          channels: [a], before: before, announced: {'a'}, isInitialLoad: false);

      before = snapshotChannels([a]);
      a.isLive = true;
      final again = detectLiveTransitions(
          channels: [a],
          before: before,
          announced: ended.announced,
          isInitialLoad: false);

      expect(ended.wentOffline, [a]);
      expect(ended.announced, isEmpty);
      expect(again.wentLive, [a]);
    });

    test('a channel seen for the first time is a baseline, not an edge', () {
      // A new follow, or a favourite starred from the followed list, may have
      // been live for hours when it is first refreshed.
      final fresh = ch('fresh', observed: false);
      final before = snapshotChannels([fresh]);
      fresh
        ..isLive = true
        ..lastUpdated = t0;

      final t = detectLiveTransitions(
          channels: [fresh], before: before, announced: {}, isInitialLoad: false);

      expect(t.wentLive, isEmpty);
      expect(t.announced, {'fresh'},
          reason: 'recorded, so it is not announced on the next pass either');
    });

    test('a channel added during the pass is a baseline too', () {
      // Not in the snapshot at all: it joined the list while the request was
      // out.
      final added = ch('added', live: true);
      final t = detectLiveTransitions(
          channels: [added],
          before: snapshotChannels(const []),
          announced: {},
          isInitialLoad: false);
      expect(t.wentLive, isEmpty);
    });

    test('a channel seeded as live when it was added is not announced', () {
      final a = ch('a');
      final before = snapshotChannels([a]);
      a.isLive = true;
      final t = detectLiveTransitions(
          channels: [a], before: before, announced: {'a'}, isInitialLoad: false);
      expect(t.wentLive, isEmpty);
    });

    test('a refresh that learned nothing changes nothing', () {
      // Rate limited or failed: the service leaves isLive alone, so a live
      // channel neither drops offline nor comes back as a new broadcast.
      final a = ch('a', live: true);
      final before = snapshotChannels([a]);
      final t = detectLiveTransitions(
          channels: [a], before: before, announced: {'a'}, isInitialLoad: false);
      expect(t.wentLive, isEmpty);
      expect(t.wentOffline, isEmpty);
      expect(t.announced, {'a'});
    });

    test('a broadcast that only seemed to end is not announced again', () {
      // Three failed refreshes drop a live channel offline, though Twitch
      // never said its broadcast ended. When requests work again on the same
      // stream id, it is the broadcast already announced: announcing it again
      // was a duplicate toast and, through auto-play, a relaunch.
      final a = ch('a', live: true, streamId: 's1');
      final seen = detectLiveTransitions(
          channels: [a],
          before: snapshotChannels([a]),
          announced: {},
          isInitialLoad: true);

      var before = snapshotChannels([a]);
      a
        ..isLive = false
        ..streamId = null
        ..errorMessage = 'timed out';
      final dropped = detectLiveTransitions(
          channels: [a],
          before: before,
          announced: seen.announced,
          isInitialLoad: false,
          knownBroadcasts: seen.knownBroadcasts);
      expect(dropped.wentOffline, [a]);

      before = snapshotChannels([a]);
      a
        ..isLive = true
        ..streamId = 's1'
        ..errorMessage = null;
      final back = detectLiveTransitions(
          channels: [a],
          before: before,
          announced: dropped.announced,
          isInitialLoad: false,
          knownBroadcasts: dropped.knownBroadcasts);

      expect(back.wentLive, isEmpty);
      expect(back.announced, {'a'});

      // A new stream id is a new broadcast, however its predecessor ended.
      before = snapshotChannels([a]);
      a
        ..isLive = false
        ..streamId = null;
      final ended = detectLiveTransitions(
          channels: [a],
          before: before,
          announced: back.announced,
          isInitialLoad: false,
          knownBroadcasts: back.knownBroadcasts);
      before = snapshotChannels([a]);
      a
        ..isLive = true
        ..streamId = 's2';
      final next = detectLiveTransitions(
          channels: [a],
          before: before,
          announced: ended.announced,
          isInitialLoad: false,
          knownBroadcasts: ended.knownBroadcasts);
      expect(next.wentLive, [a]);
    });

    test('a broadcast Twitch reported offline is announced again when it '
        'comes back, even on the same stream id', () {
      // A stream that drops and reconnects can come back on its stream id.
      // Remembered across the reported offline, the reconnect came back
      // silently; only failing refreshes keep the broadcast now.
      final a = ch('a', live: true, streamId: 's1');
      final seen = detectLiveTransitions(
          channels: [a],
          before: snapshotChannels([a]),
          announced: {},
          isInitialLoad: true);

      var before = snapshotChannels([a]);
      a
        ..isLive = false
        ..streamId = null; // Twitch: offline - an answer, so no error
      final ended = detectLiveTransitions(
          channels: [a],
          before: before,
          announced: seen.announced,
          isInitialLoad: false,
          knownBroadcasts: seen.knownBroadcasts);
      expect(ended.wentOffline, [a]);
      expect(ended.knownBroadcasts, isEmpty);

      before = snapshotChannels([a]);
      a
        ..isLive = true
        ..streamId = 's1';
      final back = detectLiveTransitions(
          channels: [a],
          before: before,
          announced: ended.announced,
          isInitialLoad: false,
          knownBroadcasts: ended.knownBroadcasts);
      expect(back.wentLive, [a]);
      expect(back.knownBroadcasts, {'a': 's1'});
    });

    test('with no stream id, only a reported offline ends the broadcast', () {
      // DecAPI names no stream id, so nothing tells a broadcast that came
      // back after failing refreshes from a new one; Twitch saying the
      // channel is offline does.
      LiveTransitions step(TwitchChannel a, LiveTransitions last,
          void Function() change) {
        final before = snapshotChannels([a]);
        change();
        return detectLiveTransitions(
            channels: [a],
            before: before,
            announced: last.announced,
            isInitialLoad: false,
            knownBroadcasts: last.knownBroadcasts);
      }

      final a = ch('a', live: true)..streamId = null;
      var t = detectLiveTransitions(
          channels: [a],
          before: snapshotChannels([a]),
          announced: {},
          isInitialLoad: true);

      t = step(a, t, () {
        a
          ..isLive = false
          ..errorMessage = 'DecAPI uptime returned status 503';
      });
      t = step(a, t, () {
        a
          ..isLive = true
          ..errorMessage = null;
      });
      expect(t.wentLive, isEmpty, reason: 'presumed offline, so the same broadcast');

      t = step(a, t, () => a.isLive = false); // Twitch: offline
      t = step(a, t, () => a.isLive = true);
      expect(t.wentLive, [a], reason: 'a reported end, so a new broadcast');
    });

    test('the set passed in is not modified', () {
      final a = ch('a');
      final before = snapshotChannels([a]);
      a.isLive = true;
      final announced = <String>{};
      detectLiveTransitions(
          channels: [a], before: before, announced: announced, isInitialLoad: false);
      expect(announced, isEmpty);
    });
  });

  group('broadcastChanged', () {
    test('going live, going offline and a new broadcast all count', () {
      final a = ch('a');
      var before = ChannelSnapshot.of(a);
      a
        ..isLive = true
        ..streamId = 's1';
      expect(broadcastChanged(before, a), isTrue);

      before = ChannelSnapshot.of(a);
      a.streamId = 's2';
      expect(broadcastChanged(before, a), isTrue,
          reason: 'a restarted stream has a new archive');

      before = ChannelSnapshot.of(a);
      a
        ..isLive = false
        ..streamId = null;
      expect(broadcastChanged(before, a), isTrue);
    });

    test('nothing changed, or nothing was known before', () {
      final a = ch('a', live: true);
      expect(broadcastChanged(ChannelSnapshot.of(a), a), isFalse);
      expect(broadcastChanged(null, a), isFalse);
      final unseen = ch('b', observed: false);
      final before = ChannelSnapshot.of(unseen);
      unseen.isLive = true;
      expect(broadcastChanged(before, unseen), isFalse);
    });
  });

  group('applyWentLiveFallback', () {
    test("Helix's started_at is kept", () {
      // It used to be overwritten with the poll's clock on every
      // offline-to-live edge: "live for" a minute short, and far worse after
      // the PC woke into a stream already an hour old.
      final startedAt = t0.subtract(const Duration(minutes: 55));
      final a = ch('a');
      final before = snapshotChannels([a]);
      a
        ..isLive = true
        ..streamId = 's1'
        ..wentLiveTime = startedAt;

      applyWentLiveFallback([a], before, isInitialLoad: false, now: t0);

      expect(a.wentLiveTime, startedAt);
    });

    test('a channel with no start time gets the moment the edge was seen', () {
      // DecAPI has neither a start time nor a stream id, so whatever an
      // earlier broadcast left behind is stale.
      final earlier = t0.subtract(const Duration(days: 1));
      final a = ch('a')..wentLiveTime = earlier;
      final before = snapshotChannels([a]);
      a.isLive = true;

      applyWentLiveFallback([a], before, isInitialLoad: false, now: t0);

      expect(a.wentLiveTime, t0);
    });

    test('a broadcast back from a presumed offline keeps its start time', () {
      // With no stream id the start time is the auto-play session's key: a
      // new one relaunched the stream the user had closed.
      final earlier = t0.subtract(const Duration(minutes: 40));
      final a = ch('a')
        ..streamId = null
        ..wentLiveTime = earlier
        ..errorMessage = 'timed out';
      final before = snapshotChannels([a]);
      a
        ..isLive = true
        ..errorMessage = null;

      applyWentLiveFallback([a], before, isInitialLoad: false, now: t0);

      expect(a.wentLiveTime, earlier);
    });

    test('the first pass and channels still live are left alone', () {
      final a = ch('a');
      final before = snapshotChannels([a]);
      a.isLive = true;
      applyWentLiveFallback([a], before, isInitialLoad: true, now: t0);
      expect(a.wentLiveTime, isNull);

      final b = ch('b', live: true)..wentLiveTime = null;
      applyWentLiveFallback([b], snapshotChannels([b]), isInitialLoad: false, now: t0);
      expect(b.wentLiveTime, isNull);
    });
  });
}
