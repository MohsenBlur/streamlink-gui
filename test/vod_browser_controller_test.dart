import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/state/channels_controller.dart';
import 'package:streamlink_gui/state/vod_browser_controller.dart';
import 'package:streamlink_gui/state/vod_cache.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';

import 'support/fake_helix.dart';

/// The open channel's VOD grid, against a scripted Twitch through the real
/// service.
///
/// The reported bug: a channel's list did not update - not for a new VOD,
/// not for a stream starting - unless the user clicked another channel and
/// back. The list was fetched on selection, on Load more and on a token
/// recovery, and never again.
void main() {
  late FakeHelix twitch;
  late Map<String, int> progress;
  late List<(String, List<String>)> announced;

  setUp(() {
    twitch = FakeHelix();
    progress = <String, int>{};
    announced = <(String, List<String>)>[];
  });

  VodBrowserController browserFor({VodCache? cache, AppSettings? settings}) {
    final browser = VodBrowserController(
      api: twitch.service(),
      settings: () => settings ?? FakeHelix.settings,
      localProgress: () => progress,
      cache: cache,
      clock: () => twitch.now,
    );
    browser.onNewVods = (channel, vods, _) =>
        announced.add((channel.username, [for (final v in vods) v.id]));
    addTearDown(browser.dispose);
    return browser;
  }

  void later(Duration d) => twitch.now = twitch.now.add(d);

  group('the open channel keeps up without being re-selected', () {
    test('a VOD published while the channel is open appears on the next refresh', () async {
      final old = twitch.addVideo('shroud', publishedAt: twitch.now.subtract(const Duration(days: 1)));
      final shroud = FakeHelix.channel('shroud');
      final browser = browserFor();
      await browser.open(shroud);
      expect(idsOf(browser.vods), [old]);

      later(const Duration(minutes: 5));
      final fresh = twitch.addVideo('shroud');
      final outcome = await browser.refresh();

      expect(idsOf(browser.vods), [fresh, old]);
      expect(outcome!.changedVisible, isTrue);
      expect(browser.isLoading, isFalse, reason: 'silent: no spinner');
      expect(browser.isRefreshing, isFalse);
    });

    test('a stream going live, then ending, reaches the open grid within one poll', () async {
      // The whole path main.dart wires: the poll notices the open channel's
      // broadcast changed, which refreshes the grid.
      twitch.addVideo('shroud', publishedAt: twitch.now.subtract(const Duration(days: 1)));
      final shroud = FakeHelix.channel('shroud');
      final browser = browserFor();
      final channels = ChannelsController(
        api: twitch.service(),
        settings: () => FakeHelix.settings,
        favorites: [shroud],
        selected: () => shroud,
        clock: () => twitch.now,
      );
      addTearDown(channels.dispose);
      final refreshes = <Future<void>>[];
      channels.onPass = (pass) {
        if (pass.selectedBroadcastChanged) {
          refreshes.add(browser.refresh(
              endedBroadcastStart: shroud.isLive ? null : shroud.wentLiveTime));
        }
      };
      await channels.refresh(isInitialLoad: true);
      await browser.open(shroud);
      expect(browser.vods, hasLength(1));

      later(const Duration(minutes: 1));
      twitch.goLive('shroud', title: 'Ranked');
      await channels.tick();
      await Future.wait(refreshes);
      expect(browser.vods.first.title, 'Ranked',
          reason: "the in-progress archive is in the grid, not only the header's LIVE");

      later(const Duration(hours: 2));
      final archive = browser.vods.first.id;
      twitch.updateVideo('shroud', archive, duration: '2h0m0s');
      twitch.goOffline('shroud');
      await channels.tick();
      await Future.wait(refreshes);
      expect(browser.vods.first.duration, '2h0m0s',
          reason: 'the finished VOD, not the duration frozen at selection');
    });

    test('the pages loaded with Load more, and their cursor, survive a refresh', () async {
      twitch.backfill('shroud', 30); // two pages of 20 and 10
      final shroud = FakeHelix.channel('shroud');
      final browser = browserFor();
      await browser.open(shroud);
      await browser.loadMore();
      expect(browser.vods, hasLength(30));
      expect(browser.cursor, isNull);

      later(const Duration(minutes: 5));
      final fresh = twitch.addVideo('shroud');
      await browser.refresh();

      expect(browser.vods, hasLength(31));
      expect(browser.vods.first.id, fresh);
      expect(browser.cursor, isNull, reason: 'still at the end of the archive');
    });

    test('a refresh that finds nothing new changes nothing on screen', () async {
      twitch.addVideo('shroud');
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));
      final shown = browser.vods;

      final outcome = await browser.refresh();

      expect(outcome!.changedVisible, isFalse);
      expect(idsOf(browser.vods), idsOf(shown));
    });

    test('a background refresh waits until the list is old enough', () async {
      twitch.addVideo('shroud');
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));
      twitch.requests.clear();

      later(const Duration(seconds: 30));
      await browser.refreshIfOlderThan(VodBrowserController.staleAfter);
      expect(twitch.to('/helix/videos'), isEmpty);

      later(const Duration(seconds: 31));
      await browser.refreshIfOlderThan(VodBrowserController.staleAfter);
      expect(twitch.to('/helix/videos'), hasLength(1));
    });

    test('a refresh asked for while one is out joins it', () async {
      twitch.addVideo('shroud');
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));
      twitch.requests.clear();

      twitch.holdVideos = Completer<void>();
      final background = browser.refresh();
      final manual = browser.refresh(silent: false);
      await settle();
      expect(browser.isRefreshing, isTrue,
          reason: 'the button asked, so the toolbar shows it running');
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      await Future.wait([background, manual]);

      expect(twitch.to('/helix/videos'), hasLength(1));
      expect(browser.isRefreshing, isFalse);
    });
  });

  group('selection', () {
    test('a fetch overtaken by another selection is still cached', () async {
      twitch.addVideo('a');
      twitch.addVideo('b');
      final browser = browserFor();

      twitch.holdVideos = Completer<void>();
      final first = browser.open(FakeHelix.channel('a'));
      final second = browser.open(FakeHelix.channel('b'));
      await settle();
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      expect(await first, isNull, reason: 'it no longer reaches the grid');
      await second;

      expect(browser.channel!.username, 'b');
      expect(browser.cache.read('a'), hasLength(1),
          reason: 'fresh data for a, which used to be thrown away');
    });

    test('a cached list shows at once, and is replaced by the first page', () async {
      final cache = VodCache(clock: () => twitch.now);
      final browser = browserFor(cache: cache);
      final old = twitch.addVideo('a', publishedAt: twitch.now.subtract(const Duration(days: 2)));
      await browser.open(FakeHelix.channel('a'));
      await browser.open(FakeHelix.channel('b'));

      later(const Duration(hours: 1));
      final fresh = twitch.addVideo('a');
      twitch.holdVideos = Completer<void>();
      final opening = browser.open(FakeHelix.channel('a'));
      expect(idsOf(browser.vods), [old], reason: 'the cache, instantly');
      expect(browser.isLoading, isFalse, reason: 'no spinner over a cached list');
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      await opening;

      expect(idsOf(browser.vods), [fresh, old]);
    });
  });

  group('when a refresh fails', () {
    test('over an old list, the grid says how old it is', () async {
      twitch.addVideo('shroud');
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));
      final fetchedAt = browser.fetchedAt;

      later(const Duration(minutes: 10));
      twitch.failVideos = true;
      await browser.refresh();

      expect(browser.vods, hasLength(1), reason: 'the list stays');
      expect(browser.error, isNull);
      expect(browser.stale, isNotNull);
      expect(browser.stale!.since, fetchedAt);

      twitch.failVideos = false;
      await browser.refresh();
      expect(browser.stale, isNull, reason: 'cleared by the next success');
    });

    test('over a list fetched moments ago, it says nothing', () async {
      twitch.addVideo('shroud');
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));

      later(const Duration(seconds: 10));
      twitch.failVideos = true;
      await browser.refresh();

      expect(browser.stale, isNull);
    });

    test('one the user asked for says so, however new the list', () async {
      // "Check for new VODs" over a list under a minute old just stopped its
      // spinner, which reads as "nothing new".
      twitch.addVideo('shroud');
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));
      final fetchedAt = browser.fetchedAt;

      later(const Duration(seconds: 10));
      twitch.failVideos = true;
      await browser.refresh(silent: false);

      expect(browser.stale, isNotNull);
      expect(browser.stale!.since, fetchedAt);
      expect(browser.isRefreshing, isFalse);
    });

    test('so does one the user asked for while a background one was out',
        () async {
      twitch.addVideo('shroud');
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));

      later(const Duration(seconds: 10));
      twitch.failVideos = true;
      twitch.holdVideos = Completer<void>();
      final background = browser.refresh();
      final manual = browser.refresh(silent: false);
      await settle();
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      await Future.wait([background, manual]);

      expect(twitch.to('/helix/videos'), hasLength(2),
          reason: 'the open and the one shared refresh');
      expect(browser.stale, isNotNull);
    });

    test('over nothing, the error is shown', () async {
      twitch.failVideos = true;
      final browser = browserFor();
      await browser.open(FakeHelix.channel('shroud'));
      expect(browser.error, isNotNull);
      expect(browser.isLoading, isFalse);
    });
  });

  group('lists fetched elsewhere', () {
    test('the auto-download pass feeds the open grid and the cache', () async {
      twitch.addVideo('shroud', publishedAt: twitch.now.subtract(const Duration(days: 1)));
      final shroud = FakeHelix.channel('shroud');
      final browser = browserFor();
      await browser.open(shroud);
      expect(browser.vods.single.games, ['Chess']);

      later(const Duration(minutes: 1));
      final fresh = twitch.addVideo('shroud');
      final fetchedAt = twitch.now;
      final result = await twitch.service().fetchVodsForChannel(
            channel: shroud,
            settings: FakeHelix.settings,
            localVodsProgress: progress,
            fetchGames: false,
          );
      // The service fills games in from its static cache even when told to
      // skip them, and the open above seeded it - so as it came back, this
      // list never tested the carry-over. Without games, as the pass's list
      // is when that cache is cold (a games lookup that failed, say).
      for (final vod in result.vods) {
        vod.games = const [];
      }
      expect(result.vods.last.games, isEmpty, reason: 'precondition');
      final changed =
          browser.ingest(shroud, result, fetchedAt: fetchedAt, detailed: false);

      expect(changed, isTrue);
      expect(browser.vods.first.id, fresh);
      expect(browser.vods.last.games, ['Chess'],
          reason: 'a fetch that skipped games does not strip them');
      expect(browser.cache.read('shroud'), hasLength(2));
    });

    test('an answer older than the list on screen does not overwrite it', () async {
      twitch.addVideo('shroud');
      final shroud = FakeHelix.channel('shroud');
      final browser = browserFor();
      final staleAt = twitch.now;
      final stale = await twitch.service().fetchVodsForChannel(
          channel: shroud, settings: FakeHelix.settings, localVodsProgress: progress);

      later(const Duration(minutes: 1));
      final fresh = twitch.addVideo('shroud');
      await browser.open(shroud);
      browser.ingest(shroud, stale, fetchedAt: staleAt);

      expect(browser.vods.first.id, fresh);
    });
  });

  group('new VODs', () {
    test('a broadcast that ends is announced once, and a baseline never is', () async {
      twitch.addVideo('shroud', publishedAt: twitch.now.subtract(const Duration(days: 1)));
      final shroud = FakeHelix.channel('shroud');
      final browser = browserFor();
      await browser.open(shroud);
      expect(announced, isEmpty, reason: 'the first list is a baseline');

      twitch.goLive('shroud');
      shroud
        ..isLive = true
        ..wentLiveTime = twitch.now;
      later(const Duration(minutes: 5));
      await browser.refresh();
      expect(announced, isEmpty, reason: 'still live: the went-live toast covers it');

      later(const Duration(hours: 2));
      twitch.goOffline('shroud');
      shroud.isLive = false;
      await browser.refresh();
      await browser.refresh(silent: false);

      expect(announced, hasLength(1));
      expect(announced.single.$1, 'shroud');
    });

    test('a favourite that ended off screen is found by its stream-end check', () async {
      final start = twitch.now.subtract(const Duration(hours: 3));
      final vodId = twitch.addVideo('summit1g', publishedAt: start);
      final summit = FakeHelix.channel('summit1g')..wentLiveTime = start;
      final browser = browserFor();

      await browser.checkForNewVods(summit, endedBroadcastStart: start);

      expect(announced, hasLength(1));
      expect(announced.single.$1, 'summit1g');
      expect(announced.single.$2, [vodId]);
      expect(browser.cache.read('summit1g'), hasLength(1));
      expect(twitch.to('/gql'), isEmpty, reason: 'the cheap check skips games');
    });

    test('a broadcast end that joins the first fetch still finds its VOD',
        () async {
      // The poll reports the end while the channel's very first list is on
      // its way. The refresh joins that fetch, and used to drop the start it
      // carried, so the list became a baseline and announced nothing.
      final start = twitch.now.subtract(const Duration(hours: 3));
      final vodId = twitch.addVideo('summit1g', publishedAt: start);
      final summit = FakeHelix.channel('summit1g')..wentLiveTime = start;
      final browser = browserFor();

      twitch.holdVideos = Completer<void>();
      final opening = browser.open(summit);
      await settle();
      final ended = browser.refresh(endedBroadcastStart: start);
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      await Future.wait([opening, ended]);

      expect(twitch.to('/helix/videos'), hasLength(1),
          reason: 'joined, not fetched twice');
      expect(announced, hasLength(1));
      expect(announced.single.$2, [vodId]);
    });

    test('two broadcast ends that join one first fetch find both VODs',
        () async {
      // Each refresh that joined the fetch put its own start in, so the
      // second end's later start hid the first broadcast's VOD.
      final first = twitch.now.subtract(const Duration(hours: 6));
      final second = twitch.now.subtract(const Duration(hours: 2));
      final older = twitch.addVideo('summit1g', publishedAt: first);
      final newer = twitch.addVideo('summit1g', publishedAt: second);
      final summit = FakeHelix.channel('summit1g');
      final browser = browserFor();

      twitch.holdVideos = Completer<void>();
      final opening = browser.open(summit);
      await settle();
      final firstEnd = browser.refresh(endedBroadcastStart: first);
      final secondEnd = browser.refresh(endedBroadcastStart: second);
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      await Future.wait([opening, firstEnd, secondEnd]);

      expect(twitch.to('/helix/videos'), hasLength(1));
      expect(announced, hasLength(1));
      expect(announced.single.$2, [newer, older]);
    });
  });

  group('prefetch', () {
    test('fills the cache once, and again only after the TTL', () async {
      for (final name in ['a', 'b']) {
        twitch.addVideo(name);
      }
      final browser = browserFor();
      final channels = [FakeHelix.channel('a'), FakeHelix.channel('b')];

      await browser.prefetch(channels, open: null);
      expect(twitch.to('/helix/videos'), hasLength(2));

      twitch.requests.clear();
      later(const Duration(minutes: 5));
      await browser.prefetch(channels, open: null);
      expect(twitch.to('/helix/videos'), isEmpty);

      later(VodCache.ttl);
      await browser.prefetch(channels, open: null);
      expect(twitch.to('/helix/videos'), hasLength(2),
          reason: 'a list from hours ago is not a cache hit');
    });

    test('a list is not read again just because ten minutes passed', () async {
      // At a ten-minute TTL the prefetch re-read every favourite's list that
      // often, around the clock, for lists nobody had opened.
      twitch.addVideo('a');
      final browser = browserFor();
      final channels = [FakeHelix.channel('a')];
      await browser.prefetch(channels, open: null);
      twitch.requests.clear();

      for (var i = 0; i < 2; i++) {
        later(const Duration(minutes: 11));
        await browser.prefetch(channels, open: null);
      }
      expect(twitch.to('/helix/videos'), isEmpty);
    });

    test('reads no watch positions, and leaves the open channel alone',
        () async {
      final withBrowserToken = AppSettings(
        twitchOauthToken: 'oauth:account-token',
        twitchWebOauthToken: 'oauth:browser-token',
      );
      List<Object> positionLookups() => [
            for (final r in twitch.to('/gql'))
              if (r.headers['Authorization'] != null) r,
          ];
      for (final name in ['a', 'b', 'open']) {
        twitch.addVideo(name);
      }
      final browser = browserFor(settings: withBrowserToken);
      final open = FakeHelix.channel('open');
      await browser.open(open);
      expect(positionLookups(), hasLength(1),
          reason: 'opening a channel does read them (and the fake sees it)');
      // Old enough for the prefetch, were it not on screen.
      later(VodCache.ttl);
      twitch.requests.clear();

      await browser.prefetch(
          [FakeHelix.channel('a'), FakeHelix.channel('b'), open],
          open: open);

      expect(twitch.to('/helix/videos'), hasLength(2),
          reason: 'the open channel is kept current by its own refresh');
      expect(positionLookups(), isEmpty,
          reason: 'one GQL request per VOD, for lists nobody has opened');
    });

    test('reads the channel it still holds once the screen has none open',
        () async {
      // "Go to dashboard" leaves no channel open on the screen, whose
      // refreshes then stop, while this still holds the last one. Skipping
      // what it held left that channel to no refresh at all.
      twitch.addVideo('last');
      final browser = browserFor();
      final last = FakeHelix.channel('last');
      await browser.open(last);
      later(VodCache.ttl);
      twitch.requests.clear();

      await browser.prefetch([last], open: null);
      expect(twitch.to('/helix/videos'), hasLength(1));

      later(VodCache.ttl);
      twitch.requests.clear();
      await browser.prefetch([last], open: last);
      expect(twitch.to('/helix/videos'), isEmpty,
          reason: 'open on the screen, it is the refreshes\' again');
    });

    test('a favourite whose broadcast started or ended is read again',
        () async {
      // Its archive gained (or finished) a VOD, however young its list is.
      twitch.addVideo('a');
      twitch.addVideo('b');
      final a = FakeHelix.channel('a')..lastUpdated = twitch.now;
      final b = FakeHelix.channel('b')..lastUpdated = twitch.now;
      final browser = browserFor();
      await browser.prefetch([a, b], open: null);
      twitch.requests.clear();

      later(const Duration(minutes: 1));
      a
        ..isLive = true
        ..streamId = 'broadcast-1';
      await browser.prefetch([a, b], open: null);
      expect(twitch.to('/helix/videos'), hasLength(1), reason: 'a only');

      twitch.requests.clear();
      later(const Duration(minutes: 1));
      await browser.prefetch([a, b], open: null);
      expect(twitch.to('/helix/videos'), isEmpty,
          reason: 'its list is from this broadcast now');

      a.isLive = false;
      await browser.prefetch([a, b], open: null);
      expect(twitch.to('/helix/videos'), hasLength(1),
          reason: 'and again once it ends');
    });

    test('a broadcast that starts while its list is being read is read again',
        () async {
      // The list was counted as this broadcast's because the broadcast had
      // started by the time the answer landed, though the request went out
      // before it: the VOD it began stayed out of the cache for the TTL.
      twitch.addVideo('a');
      final a = FakeHelix.channel('a')..lastUpdated = twitch.now;
      final browser = browserFor();

      twitch.holdVideos = Completer<void>();
      final reading = browser.prefetch([a], open: null);
      await settle();
      a
        ..isLive = true
        ..streamId = 'broadcast-1';
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      await reading;
      twitch.requests.clear();

      later(const Duration(minutes: 1));
      await browser.prefetch([a], open: null);
      expect(twitch.to('/helix/videos'), hasLength(1));

      twitch.requests.clear();
      await browser.prefetch([a], open: null);
      expect(twitch.to('/helix/videos'), isEmpty,
          reason: 'read during the broadcast, it is current');
    });

    test("leaves a channel to the stream-end check that is reading it",
        () async {
      twitch.addVideo('a');
      final a = FakeHelix.channel('a')..lastUpdated = twitch.now;
      final browser = browserFor();
      await browser.prefetch([a], open: null);
      twitch.requests.clear();

      a
        ..isLive = false
        ..streamId = 'ended';
      twitch.holdVideos = Completer<void>();
      final check = browser.checkForNewVods(a, endedBroadcastStart: twitch.now);
      final prefetch = browser.prefetch([a], open: null);
      await settle();
      twitch.holdVideos!.complete();
      twitch.holdVideos = null;
      await Future.wait([check, prefetch]);

      expect(twitch.to('/helix/videos'), hasLength(1));
    });
  });

  test('load more de-duplicates a VOD repeated across the page boundary', () async {
    twitch.backfill('shroud', 25);
    final browser = browserFor();
    await browser.open(FakeHelix.channel('shroud'));
    // A VOD published between the two requests shifts page two by one.
    twitch.addVideo('shroud');
    await browser.loadMore();

    final ids = idsOf(browser.vods);
    expect(ids.toSet(), hasLength(ids.length));
    expect(browser.vods, hasLength(25));
  });

  group('which tokens the background refreshes run with', () {
    test('a token missing the follows scope still keeps the grid current', () async {
      // helix/videos needs no scope. Gating the cadence and the tray restore
      // on isUsable left this account's grid exactly as stale as the bug.
      const missingScope = TwitchAuthStatus(
        state: TwitchAuthState.invalid,
        fault: TwitchAuthFault.missingScope,
      );
      expect(missingScope.isUsable, isFalse);
      expect(backgroundVodRefreshAllowed(missingScope), isTrue);
    });

    test('so does one not yet checked, being checked, or out of reach', () {
      for (final state in [
        TwitchAuthState.unverified,
        TwitchAuthState.checking,
        TwitchAuthState.unreachable,
        TwitchAuthState.valid,
      ]) {
        expect(backgroundVodRefreshAllowed(TwitchAuthStatus(state: state)), isTrue,
            reason: '$state');
      }
    });

    test('a token Helix refuses, or none at all, is left alone', () {
      for (final fault in [TwitchAuthFault.revoked, TwitchAuthFault.clientIdMismatch]) {
        expect(
            backgroundVodRefreshAllowed(
                TwitchAuthStatus(state: TwitchAuthState.invalid, fault: fault)),
            isFalse,
            reason: '$fault');
      }
      expect(backgroundVodRefreshAllowed(TwitchAuthStatus.absent), isFalse);
    });
  });

  test('a disposed browser ignores a fetch that lands afterwards', () async {
    twitch.addVideo('shroud');
    final browser = VodBrowserController(
      api: twitch.service(),
      settings: () => FakeHelix.settings,
      localProgress: () => progress,
      clock: () => twitch.now,
    );
    twitch.holdVideos = Completer<void>();
    final opening = browser.open(FakeHelix.channel('shroud'));
    browser.dispose();
    twitch.holdVideos!.complete();
    expect(await opening, isNull);
  });
}
