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
