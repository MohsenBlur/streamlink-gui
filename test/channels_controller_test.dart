import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/state/channels_controller.dart';

import 'support/fake_helix.dart';

/// The channel poll, against a scripted Twitch through the real service.
///
/// Everything here lived inline in `_MainScreenState` with no tests: the
/// went-live detection behind every toast and auto-play, the pass that could
/// run twice at once, the followed-list reload that replaced every object.
void main() {
  late FakeHelix twitch;
  late List<ChannelsPass> passes;
  late int notifications;

  setUp(() {
    twitch = FakeHelix();
    passes = <ChannelsPass>[];
    notifications = 0;
  });

  ChannelsController controllerFor(
    List<TwitchChannel> favorites, {
    TwitchChannel? Function()? selected,
  }) {
    final controller = ChannelsController(
      api: twitch.service(),
      settings: () => FakeHelix.settings,
      favorites: favorites,
      selected: selected,
      clock: () => twitch.now,
    );
    controller.onPass = passes.add;
    controller.addListener(() => notifications++);
    addTearDown(controller.dispose);
    return controller;
  }

  group('the poll', () {
    test('a channel going live shows within one poll, with one repaint', () async {
      twitch.user('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);
      expect(shroud.isLive, isFalse);

      twitch.goLive('shroud');
      notifications = 0;
      await controller.tick();

      expect(shroud.isLive, isTrue);
      expect(shroud.streamTitle, 'live now');
      expect(notifications, 1,
          reason: 'one notification per pass, not per channel - and not '
              'dependent on the open channel being among them');
      expect(passes.last.favoritesWentLive, [shroud]);
    });

    test('the first pass records what is already live without announcing it', () async {
      twitch.goLive('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);

      await controller.refresh(isInitialLoad: true);
      await controller.tick();

      expect(shroud.isLive, isTrue);
      expect(passes.every((p) => p.favoritesWentLive.isEmpty), isTrue);
      expect(controller.liveFavorites, {'shroud'});
    });

    test('a stream that ends is reported as having gone offline', () async {
      twitch.goLive('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);

      twitch.goOffline('shroud');
      await controller.tick();

      expect(shroud.isLive, isFalse);
      expect(passes.last.favoritesWentOffline, [shroud]);
    });

    test("the broadcast's own start time is kept", () async {
      final startedAt = twitch.now.subtract(const Duration(minutes: 55));
      twitch.user('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);

      twitch.goLive('shroud', at: startedAt);
      await controller.tick();

      expect(shroud.wentLiveTime, startedAt.toLocal(),
          reason: 'not the moment the poll noticed');
    });

    test('favourites and followed channels cost one batched request', () async {
      for (final name in ['a', 'b', 'c', 'd']) {
        twitch.user(name);
      }
      twitch.followed.addAll(['c', 'd', 'a']);
      final controller = controllerFor([FakeHelix.channel('a'), FakeHelix.channel('b')]);
      await controller.loadFollowed();
      twitch.requests.clear();

      await controller.tick();

      expect(twitch.to('/helix/streams'), hasLength(1));
      expect(twitch.to('/helix/channels/followers'), isEmpty,
          reason: 'follower counts are not part of the poll');
    });
  });

  group('failing refreshes', () {
    test('a live channel back after three failed refreshes is not announced '
        'again', () async {
      // Three failures in a row drop it offline; the broadcast never ended.
      // Its return on the same stream id announced it a second time.
      twitch.goLive('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);
      final streamId = shroud.streamId;

      twitch.revokedTokens.add('account-token');
      for (var i = 0; i < 3; i++) {
        await controller.refresh(force: true);
        twitch.now = twitch.now.add(const Duration(seconds: 5));
      }
      expect(shroud.isLive, isFalse);
      expect(passes.last.favoritesWentOffline, [shroud]);

      twitch.revokedTokens.clear();
      await controller.tick();

      expect(shroud.isLive, isTrue);
      expect(shroud.streamId, streamId);
      expect(passes.last.favoritesWentLive, isEmpty);
    });

    test('a new broadcast after the outage is announced', () async {
      twitch.goLive('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);

      twitch.revokedTokens.add('account-token');
      for (var i = 0; i < 3; i++) {
        await controller.refresh(force: true);
        twitch.now = twitch.now.add(const Duration(minutes: 1));
      }
      twitch
        ..goOffline('shroud')
        ..goLive('shroud', at: twitch.now)
        ..revokedTokens.clear();
      await controller.tick();

      expect(passes.last.favoritesWentLive, [shroud]);
    });
  });

  group('rate limiting', () {
    test('a rate-limited pass does not flip a live channel offline', () async {
      twitch.goLive('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);
      expect(shroud.isLive, isTrue);

      twitch.rateLimitStreams = true;
      for (var i = 0; i < 4; i++) {
        await controller.refresh(force: true);
        twitch.now = twitch.now.add(const Duration(minutes: 1));
      }

      expect(shroud.isLive, isTrue,
          reason: 'four refused passes are not four failures');
      expect(shroud.consecutiveFailures, 0);
      expect(passes.every((p) => p.favoritesWentOffline.isEmpty), isTrue);

      // And when Twitch answers again, it is not a brand-new broadcast.
      twitch.rateLimitStreams = false;
      twitch.now = twitch.now.add(const Duration(minutes: 5));
      await controller.tick();
      expect(passes.last.favoritesWentLive, isEmpty);
    });

    test('the timer skips its pass while Twitch is backing the app off', () async {
      twitch.user('shroud');
      final controller = controllerFor([FakeHelix.channel('shroud')]);
      await controller.refresh(isInitialLoad: true);

      twitch.rateLimitStreams = true;
      await controller.tick(); // the 429; Retry-After: 30
      twitch.requests.clear();
      passes.clear();

      await controller.tick();
      await controller.refreshIfOlderThan(Duration.zero);
      expect(twitch.requests, isEmpty, reason: 'a pass now would only be refused');
      // The service refuses locally, so the request count alone cannot tell a
      // skipped pass from a refused one; the side effects can.
      expect(passes, isEmpty,
          reason: 'no pass, so no automation or prefetch run on a refused answer');

      twitch.rateLimitStreams = false;
      twitch.now = twitch.now.add(const Duration(seconds: 31));
      await controller.tick();
      expect(twitch.to('/helix/streams'), hasLength(1));
    });
  });

  group('coalescing', () {
    test('callers that arrive during a pass share it', () async {
      twitch.user('shroud');
      final controller = controllerFor([FakeHelix.channel('shroud')]);
      await controller.refresh(isInitialLoad: true);
      twitch.requests.clear();
      passes.clear();

      twitch.holdStreams = Completer<void>();
      final first = controller.tick();
      final second = controller.tick();
      final third = controller.refreshIfOlderThan(Duration.zero);
      await settle();
      twitch.holdStreams!.complete();
      twitch.holdStreams = null;
      await Future.wait([first, second, third]);

      expect(twitch.to('/helix/streams'), hasLength(1));
      expect(passes, hasLength(1),
          reason: 'side effects run once per pass, not once per caller');
    });

    test('a refresh the user asked for runs once more after the current pass', () async {
      twitch.user('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);
      twitch.requests.clear();
      passes.clear();

      twitch.holdStreams = Completer<void>();
      final automatic = controller.tick();
      await settle();
      // The answer already on its way may predate the reason for asking.
      twitch.goLive('shroud');
      final manual = controller.refresh(force: true);
      final manualAgain = controller.refresh(force: true);
      twitch.holdStreams!.complete();
      twitch.holdStreams = null;
      await Future.wait([automatic, manual, manualAgain]);

      expect(twitch.to('/helix/streams'), hasLength(2),
          reason: 'one rerun, shared by both forced requests');
      expect(passes, hasLength(2));
      expect(shroud.isLive, isTrue);
    });

    test('a rerun queued before dispose sends nothing after it', () async {
      twitch.user('shroud');
      // Not controllerFor: this one is disposed by the test itself.
      final controller = ChannelsController(
        api: twitch.service(),
        settings: () => FakeHelix.settings,
        favorites: [FakeHelix.channel('shroud')],
        clock: () => twitch.now,
      );
      await controller.refresh(isInitialLoad: true);
      twitch.requests.clear();

      twitch.holdStreams = Completer<void>();
      final running = controller.tick();
      await settle();
      final rerun = controller.refresh(force: true);
      controller.dispose();
      twitch.holdStreams!.complete();
      twitch.holdStreams = null;
      await Future.wait([running, rerun]);
      await settle();

      expect(twitch.to('/helix/streams'), hasLength(1),
          reason: 'only the pass already out when the screen went');
    });

    test('an initial load is never folded into an ordinary pass', () async {
      twitch.goLive('shroud');
      final favorites = <TwitchChannel>[];
      final controller = controllerFor(favorites);

      twitch.holdStreams = Completer<void>();
      final early = controller.tick();
      await settle();
      // Startup finishes loading the config while that pass is out.
      favorites.add(FakeHelix.channel('shroud'));
      final initial = controller.refresh(isInitialLoad: true);
      twitch.holdStreams!.complete();
      twitch.holdStreams = null;
      await Future.wait([early, initial]);

      expect(passes.map((p) => p.isInitialLoad), [false, true]);
      await controller.tick();
      expect(passes.expand((p) => p.favoritesWentLive), isEmpty,
          reason: 'a favourite already live at startup is not announced');
    });

    test('the lists can change while a pass is out', () async {
      // Starring a channel while the pass awaited used to throw
      // ConcurrentModificationError and skip the rest of the pass.
      twitch.user('a');
      twitch.user('b');
      final favorites = [FakeHelix.channel('a')];
      final controller = controllerFor(favorites);
      await controller.refresh(isInitialLoad: true);

      twitch.holdStreams = Completer<void>();
      final pass = controller.tick();
      await settle();
      favorites.add(FakeHelix.channel('b'));
      favorites.removeAt(0);
      twitch.holdStreams!.complete();
      twitch.holdStreams = null;

      await expectLater(pass, completes);
      expect(passes, hasLength(2));
    });
  });

  group('the followed list', () {
    test('a reload keeps the objects of channels still followed', () async {
      twitch.goLive('a');
      twitch.followed.addAll(['a', 'b']);
      final controller = controllerFor(const []);
      await controller.loadFollowed();
      final a = controller.followed.firstWhere((c) => c.username == 'a');
      expect(a.isLive, isTrue);
      expect(a.avatarUrl, isNotNull);

      twitch.followed
        ..remove('b')
        ..add('c');
      await controller.loadFollowed();

      expect(controller.followed.map((c) => c.username), ['a', 'c']);
      expect(identical(controller.followed.first, a), isTrue,
          reason: 'its avatar, live state, and any reference to it survive');
    });

    test('a new follow that is already live is not announced', () async {
      twitch.followed.add('a');
      final controller = controllerFor(const []);
      await controller.loadFollowed();

      twitch.goLive('fresh');
      twitch.followed.add('fresh');
      await controller.loadFollowed();

      expect(passes.expand((p) => p.followedWentLive), isEmpty);
    });

    test('a followed channel going live is reported, unless it is a favourite', () async {
      twitch.user('fav');
      twitch.user('other');
      twitch.followed.addAll(['fav', 'other']);
      final controller = controllerFor([FakeHelix.channel('fav')]);
      await controller.refresh(isInitialLoad: true);
      await controller.loadFollowed();

      twitch.goLive('fav');
      twitch.goLive('other');
      await controller.tick();

      expect(passes.last.favoritesWentLive.map((c) => c.username), ['fav']);
      expect(passes.last.followedWentLive.map((c) => c.username), ['other'],
          reason: 'the favourite is announced as a favourite, once');
    });

    test('the background reload comes round after its interval', () async {
      twitch.followed.add('a');
      final controller = controllerFor(const []);
      expect(controller.isFollowedReloadDue, isFalse,
          reason: 'never before a first successful load');
      await controller.loadFollowed();
      expect(controller.isFollowedReloadDue, isFalse);

      twitch.now = twitch.now.add(ChannelsController.followedReloadInterval);
      expect(controller.isFollowedReloadDue, isTrue);
    });

    test("clearing drops a load still out for the old account", () async {
      twitch.followed.add('a');
      final controller = controllerFor(const []);
      twitch.holdFollowed = Completer<void>();
      final stale = controller.loadFollowed();
      await settle();

      controller.clearFollowed();
      twitch.holdFollowed!.complete();
      twitch.holdFollowed = null;

      expect(await stale, isNull);
      expect(controller.followed, isEmpty);
      expect(controller.isLoadingFollowed, isFalse);

      // A load for the new account is not joined to the stale one.
      expect(await controller.loadFollowed(), isNotNull);
      expect(controller.followed.map((c) => c.username), ['a']);
    });

    test('the open channel is polled even once it is in neither list', () async {
      twitch.user('gone');
      final gone = FakeHelix.channel('gone');
      final controller = controllerFor(const [], selected: () => gone);

      twitch.goLive('gone');
      await controller.refresh(force: true);

      expect(gone.isLive, isTrue);
      expect(passes.last.selected, same(gone));
    });

    test('the open channel resolves to the object the poll keeps current', () async {
      twitch.user('a');
      twitch.followed.add('a');
      final favorite = FakeHelix.channel('a');
      final controller = controllerFor([favorite]);
      await controller.loadFollowed();
      final followedTwin = controller.followed.single;

      expect(identical(followedTwin, favorite), isFalse);
      expect(controller.canonical(followedTwin), same(favorite));
      expect(controller.canonical(FakeHelix.channel('A')), same(favorite));
      final stranger = FakeHelix.channel('nobody');
      expect(controller.canonical(stranger), same(stranger));
    });

    test('a broadcast change on the open channel is reported', () async {
      twitch.user('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud], selected: () => shroud);
      await controller.refresh(isInitialLoad: true);
      expect(passes.last.selectedBroadcastChanged, isFalse);

      twitch.goLive('shroud');
      await controller.tick();
      expect(passes.last.selectedBroadcastChanged, isTrue);

      await controller.tick();
      expect(passes.last.selectedBroadcastChanged, isFalse);

      twitch.goOffline('shroud');
      await controller.tick();
      expect(passes.last.selectedBroadcastChanged, isTrue);
    });
  });

  group('adding a favourite', () {
    test('a second Enter while the lookup runs adds nothing', () async {
      twitch.user('shroud');
      final favorites = <TwitchChannel>[];
      final controller = controllerFor(favorites);
      twitch.holdStreams = Completer<void>();

      final first = controller.addFavorite('shroud');
      await settle();
      expect(controller.checkAdd('shroud'), AddCheck.pending);
      final second = await controller.addFavorite('shroud');
      expect(second.channel, isNull);
      expect(second.check, AddCheck.pending);

      twitch.holdStreams!.complete();
      twitch.holdStreams = null;
      expect((await first).channel, isNotNull);
      expect(favorites, hasLength(1));
      expect(controller.hasPendingAdds, isFalse);
    });

    test('the name is checked again once the lookup returns', () async {
      // Starred from the Followed tab while the lookup ran.
      twitch.user('shroud');
      final favorites = <TwitchChannel>[];
      final controller = controllerFor(favorites);
      twitch.holdStreams = Completer<void>();

      final adding = controller.addFavorite('shroud');
      await settle();
      favorites.add(FakeHelix.channel('shroud'));
      twitch.holdStreams!.complete();
      twitch.holdStreams = null;

      final outcome = await adding;
      expect(outcome.channel, isNull);
      expect(outcome.check, AddCheck.duplicate);
      expect(favorites, hasLength(1));
    });

    test('a name that cannot be a login is refused without a request', () {
      final controller = controllerFor(<TwitchChannel>[]);
      expect(controller.checkAdd('foo bar'), AddCheck.invalidName);
      expect(controller.checkAdd('foo&login=bar'), AddCheck.invalidName);
      expect(controller.checkAdd(''), AddCheck.empty);
      expect(twitch.requests, isEmpty);
    });

    test('an unknown user is refused with the reason', () async {
      final favorites = <TwitchChannel>[];
      final controller = controllerFor(favorites);
      final outcome = await controller.addFavorite('nosuchuser');
      expect(outcome.channel, isNull);
      expect(outcome.error, contains('not found'));
      expect(favorites, isEmpty);
    });

    test('a channel added mid-broadcast is not announced as going live', () async {
      twitch.user('a');
      final favorites = [FakeHelix.channel('a')];
      final controller = controllerFor(favorites);
      await controller.refresh(isInitialLoad: true);

      twitch.goLive('shroud');
      await controller.addFavorite('shroud');
      await controller.tick();

      expect(passes.last.favoritesWentLive, isEmpty);
    });
  });

  group('details', () {
    test("the open channel's follower count is refreshed on its own clock", () async {
      twitch.user('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);

      expect(controller.detailsDue(shroud), isTrue);
      await controller.refreshDetails(shroud);
      expect(shroud.followerCount, isNotNull);
      expect(controller.detailsDue(shroud), isFalse);

      twitch.now = twitch.now.add(ChannelsController.detailsInterval);
      expect(controller.detailsDue(shroud), isTrue);
    });

    test('a broadcast change found by it is reported', () async {
      twitch.user('shroud');
      final shroud = FakeHelix.channel('shroud');
      final controller = controllerFor([shroud]);
      await controller.refresh(isInitialLoad: true);

      twitch.goLive('shroud');
      expect(await controller.refreshDetails(shroud), isTrue);
      expect(await controller.refreshDetails(shroud), isFalse);
    });
  });
}
