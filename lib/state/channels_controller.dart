import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../services/twitch_api_service.dart';
import 'channel_transitions.dart';

/// What one refresh pass found, for the side effects main.dart owns: toasts,
/// automation, the tray, the open channel's VOD list.
///
/// Delivered through [ChannelsController.onPass] once per pass, however many
/// callers shared that pass, so a coalesced refresh can never announce a
/// broadcast or run automation twice.
class ChannelsPass {
  const ChannelsPass({
    required this.isInitialLoad,
    required this.favoritesWentLive,
    required this.favoritesWentOffline,
    required this.followedWentLive,
    required this.selected,
    required this.selectedBroadcastChanged,
    required this.result,
  });

  final bool isInitialLoad;
  final List<TwitchChannel> favoritesWentLive;
  final List<TwitchChannel> favoritesWentOffline;

  /// Followed channels that went live and are not favourites as well; a
  /// favourite is announced as one.
  final List<TwitchChannel> followedWentLive;

  /// The open channel as the object the poll keeps current (see
  /// [ChannelsController.canonical]), or null when none is open.
  final TwitchChannel? selected;

  /// The open channel's broadcast started, ended or was replaced by a new
  /// one, each of which changes what is in its archive.
  final bool selectedBroadcastChanged;

  final ChannelsRefreshResult result;
}

/// Why [ChannelsController.checkAdd] would refuse a name.
enum AddCheck {
  ok,
  empty,

  /// Not something Twitch could have as a login.
  invalidName,

  /// Already a favourite.
  duplicate,

  /// Being added right now: a second Enter while the lookup runs.
  pending,
}

/// How [ChannelsController.addFavorite] ended.
class AddFavoriteOutcome {
  const AddFavoriteOutcome({this.channel, this.check = AddCheck.ok, this.error});

  /// The channel now in the favourites, or null when nothing was added.
  final TwitchChannel? channel;

  /// Set when the name was refused without (or after) the lookup.
  final AddCheck check;

  /// What the lookup said was wrong with it.
  final String? error;
}

/// The favourites and followed channels, and the poll that keeps their live
/// state current.
///
/// Plain Dart so it can be tested: this lived inline in `_MainScreenState`,
/// where the went-live logic, the poll's re-entrancy and the followed-list
/// reload had no tests at all.
///
/// Notifies once at the end of every refresh phase - not after every
/// channel, and not only when the open channel happens to be among them:
/// the sidebar and welcome screen used to repaint after a poll only because
/// an unrelated ten-second timer called setState.
class ChannelsController extends ChangeNotifier {
  ChannelsController({
    required TwitchApiService api,
    required AppSettings Function() settings,
    List<TwitchChannel>? favorites,
    TwitchChannel? Function()? selected,
    DateTime Function()? clock,
  })  : _api = api,
        _settings = settings,
        favorites = favorites ?? <TwitchChannel>[],
        _selected = selected ?? _noSelection,
        _now = clock ?? DateTime.now;

  static TwitchChannel? _noSelection() => null;

  /// How often the followed list is fetched again in the background, so a
  /// channel followed on twitch.tv turns up without a restart.
  static const Duration followedReloadInterval = Duration(minutes: 20);

  /// How long the open channel's follower count is trusted. The batched poll
  /// leaves follower counts out (one request per channel, for a number that
  /// barely moves), so they come from [refreshDetails] instead.
  static const Duration detailsInterval = Duration(minutes: 30);

  final TwitchApiService _api;
  final AppSettings Function() _settings;
  final TwitchChannel? Function() _selected;
  final DateTime Function() _now;

  /// The favourites, in the user's order. The caller may hold and mutate this
  /// same list; the controller only ever adds to it ([addFavorite]).
  final List<TwitchChannel> favorites;

  /// The followed channels. Replaced on every reload, but by
  /// [FollowedChannelsResult.reconcileWith], so a channel that stays followed
  /// keeps its object - its avatar, its live state, and any reference the
  /// caller holds to it.
  List<TwitchChannel> get followed => _followed;
  List<TwitchChannel> _followed = <TwitchChannel>[];

  /// Clean usernames of the favourites known to be live: a broadcast is
  /// announced when its channel joins this set. The caller seeds it for a
  /// channel added mid-broadcast and drops a removed favourite from it.
  Set<String> get liveFavorites => _liveFavorites;
  final Set<String> _liveFavorites = <String>{};
  final Set<String> _liveFollowed = <String>{};

  /// Called once per completed pass.
  void Function(ChannelsPass pass)? onPass;

  /// When the last pass finished.
  DateTime? get lastPassAt => _lastPassAt;
  DateTime? _lastPassAt;

  bool _disposed = false;

  bool get _rateLimited => _api.helixRateLimitedUntil != null;

  // ---------------------------------------------------------------------------
  // The poll

  Future<void>? _inFlight;
  Future<void>? _queued;
  bool _queuedInitial = false;

  /// One pass over every favourite and followed channel (and the open
  /// channel, if it is in neither list any more).
  ///
  /// Coalesced. A pass already running is shared by every caller that
  /// arrives while it runs: two overlapping passes used to count each failed
  /// request twice - so a channel dropped offline after half the intended
  /// tolerance - and let the slower, older answer overwrite the newer state.
  /// [force] (a refresh the user asked for, or the token starting to work
  /// again) cannot make do with an answer that may predate the reason for
  /// asking, so it runs once more after the current pass; any number of
  /// forced requests during one pass share that single rerun. So does
  /// [isInitialLoad], which must never be folded into an ordinary pass.
  Future<void> refresh({bool isInitialLoad = false, bool force = false}) {
    final running = _inFlight;
    if (running != null) {
      if (!force && !isInitialLoad) return running;
      _queuedInitial |= isInitialLoad;
      Future<void> rerun() {
        _queued = null;
        final initial = _queuedInitial;
        _queuedInitial = false;
        return refresh(isInitialLoad: initial);
      }

      return _queued ??=
          running.then((_) => rerun(), onError: (Object _) => rerun());
    }
    final pass = _runPass(isInitialLoad: isInitialLoad);
    _inFlight = pass;
    // Registered before any joiner's callback, and run in that order, so a
    // queued rerun finds the slot free. Handles the error too, so this
    // bookkeeping never surfaces one of its own.
    void release() {
      if (identical(_inFlight, pass)) _inFlight = null;
    }

    pass.then<void>((_) => release(), onError: (Object _) => release());
    return pass;
  }

  /// The one-minute timer's pass.
  ///
  /// Skipped while Twitch is rate limiting: every request would be refused
  /// locally, and refusing them costs a pass of nothing. A refused pass is
  /// harmless otherwise - a rate-limited channel keeps the state it had, it
  /// is never read as offline.
  Future<void> tick() => _rateLimited ? Future<void>.value() : refresh();

  /// A pass, unless the last one finished less than [maxAge] ago.
  Future<void> refreshIfOlderThan(Duration maxAge) {
    final last = _lastPassAt;
    if (_rateLimited || (last != null && _now().difference(last) < maxAge)) {
      return Future<void>.value();
    }
    return refresh();
  }

  Future<void> _runPass({required bool isInitialLoad}) async {
    final settings = _settings();
    final open = _selected();
    // Copies, taken now. The lists can change while the request is out - a
    // star, an add, a followed reload - and walking the live list across an
    // await is what threw ConcurrentModificationError and skipped the rest of
    // the pass (automation, the tray, the followed channels).
    final tracked = <TwitchChannel>[...favorites, ..._followed];
    if (open != null && !tracked.any((c) => identical(c, open))) {
      // A channel unfollowed or un-starred while open is still on screen.
      tracked.add(open);
    }
    final before = snapshotChannels(tracked);

    // One batched call for both lists, so a streamer who is a favourite and
    // followed costs one id slot and both objects agree.
    final result = await _api.refreshLiveStatus(tracked, settings);
    if (_disposed) return;

    applyWentLiveFallback(tracked, before,
        isInitialLoad: isInitialLoad, now: _now());

    final favoriteEdges = detectLiveTransitions(
      channels: List.of(favorites),
      before: before,
      announced: _liveFavorites,
      isInitialLoad: isInitialLoad,
    );
    _liveFavorites
      ..clear()
      ..addAll(favoriteEdges.announced);

    final followedEdges = detectLiveTransitions(
      channels: List.of(_followed),
      before: before,
      announced: _liveFollowed,
      isInitialLoad: isInitialLoad,
    );
    _liveFollowed
      ..clear()
      ..addAll(followedEdges.announced);

    final favoriteNames = {
      for (final c in favorites) c.username.toLowerCase().trim(),
    };
    _lastPassAt = _now();
    _notify();

    final pass = ChannelsPass(
      isInitialLoad: isInitialLoad,
      favoritesWentLive: favoriteEdges.wentLive,
      favoritesWentOffline: favoriteEdges.wentOffline,
      followedWentLive: [
        for (final c in followedEdges.wentLive)
          if (!favoriteNames.contains(c.username.toLowerCase().trim())) c,
      ],
      selected: open == null ? null : canonical(open),
      selectedBroadcastChanged:
          open != null && broadcastChanged(before[open], open),
      result: result,
    );
    try {
      onPass?.call(pass);
    } catch (e, stack) {
      // A failing side effect must not fail the pass every joiner awaits.
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: stack,
        library: 'channels controller',
        context: ErrorDescription('while handling a refresh pass'),
      ));
    }
  }

  /// The object the poll keeps current for [channel]'s streamer: the
  /// favourite, else the followed one, else [channel] itself.
  ///
  /// The open channel used to be whichever object was clicked, and a followed
  /// reload replaced every object, leaving it pointing at one nothing
  /// refreshed any more.
  TwitchChannel canonical(TwitchChannel channel) {
    for (final c in favorites) {
      if (identical(c, channel)) return c;
    }
    final name = channel.username.toLowerCase().trim();
    for (final c in favorites) {
      if (c.username.toLowerCase().trim() == name) return c;
    }
    for (final c in _followed) {
      if (identical(c, channel) || c.username.toLowerCase().trim() == name) {
        return c;
      }
    }
    return channel;
  }

  // ---------------------------------------------------------------------------
  // The followed list

  /// Whether a followed load is running.
  bool get isLoadingFollowed => _isLoadingFollowed;
  bool _isLoadingFollowed = false;

  DateTime? _followedLoadedAt;
  int _followedGeneration = 0;
  Future<FollowedChannelsResult?>? _followedLoad;
  int _followedLoadGeneration = -1;

  /// Whether the followed list is old enough to fetch again in the
  /// background. Never before a first successful load, and never while
  /// rate limited.
  bool get isFollowedReloadDue {
    final at = _followedLoadedAt;
    return at != null &&
        !_isLoadingFollowed &&
        !_rateLimited &&
        _now().difference(at) >= followedReloadInterval;
  }

  /// Fetches the followed list, reconciles it into [followed], then runs a
  /// pass so every channel's live state arrives in one batch.
  ///
  /// The pass is an ordinary one, so a channel whose state the reload
  /// changes is announced like any other - and a newly followed channel,
  /// never refreshed before, is a baseline rather than "just went live".
  ///
  /// Coalesced: a load already running for the current account is shared.
  /// Returns null when [clearFollowed] made the answer obsolete while it was
  /// out (the token was replaced or cleared), so the old account's follows
  /// cannot come back. Throws what the fetch threw.
  Future<FollowedChannelsResult?> loadFollowed() {
    final running = _followedLoad;
    if (running != null && _followedLoadGeneration == _followedGeneration) {
      return running;
    }
    final generation = _followedGeneration;
    _followedLoadGeneration = generation;
    return _followedLoad = _loadFollowed(generation);
  }

  Future<FollowedChannelsResult?> _loadFollowed(int generation) async {
    _isLoadingFollowed = true;
    _notify();
    try {
      final result = await _api.fetchFollowedChannels(_settings());
      if (_disposed || generation != _followedGeneration) return null;
      // Reconciled, not replaced: a partial answer keeps the channels it
      // never reached, and every channel still followed keeps its object.
      _followed = result.reconcileWith(_followed);
      _followedLoadedAt = _now();
      _isLoadingFollowed = false;
      _notify();
      await refresh(force: true);
      return result;
    } finally {
      if (generation == _followedGeneration && _isLoadingFollowed) {
        _isLoadingFollowed = false;
        _notify();
      }
      if (_followedLoadGeneration == generation) _followedLoad = null;
    }
  }

  /// Forgets the followed list: the token was cleared or replaced, so the
  /// list - and any load still out for it - belongs to an account that is no
  /// longer connected.
  void clearFollowed() {
    _followedGeneration++;
    _followed = <TwitchChannel>[];
    _liveFollowed.clear();
    _followedLoadedAt = null;
    _isLoadingFollowed = false;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // One channel's details

  final Map<String, DateTime> _detailsAt = <String, DateTime>{};
  final Set<String> _detailsInFlight = <String>{};

  /// Whether [channel]'s follower count is missing or older than
  /// [detailsInterval].
  bool detailsDue(TwitchChannel channel) {
    if (_rateLimited) return false;
    final key = channel.username.toLowerCase().trim();
    if (_detailsInFlight.contains(key)) return false;
    final at = _detailsAt[key];
    return at == null || _now().difference(at) >= detailsInterval;
  }

  /// Refreshes [channel] completely, follower count included. Returns
  /// whether its broadcast started, ended or changed, which is the cue to
  /// look at its VOD list again.
  Future<bool> refreshDetails(TwitchChannel channel) async {
    final key = channel.username.toLowerCase().trim();
    final before = ChannelSnapshot.of(channel);
    _detailsInFlight.add(key);
    try {
      final outcome = await _api.fetchChannelStats(channel, _settings());
      if (outcome == ChannelRefreshOutcome.updated) _detailsAt[key] = _now();
    } finally {
      _detailsInFlight.remove(key);
    }
    _notify();
    return broadcastChanged(before, channel);
  }

  // ---------------------------------------------------------------------------
  // Adding a favourite

  final Set<String> _pendingAdds = <String>{};

  /// Whether any [addFavorite] is still waiting for Twitch.
  bool get hasPendingAdds => _pendingAdds.isNotEmpty;

  /// Whether [cleanName] (lower-cased and trimmed) can be added right now.
  /// Synchronous, so the caller can refuse a name before showing a spinner.
  AddCheck checkAdd(String cleanName) {
    if (cleanName.isEmpty) return AddCheck.empty;
    if (!isValidTwitchLogin(cleanName)) return AddCheck.invalidName;
    if (favorites.any((c) => c.username == cleanName)) return AddCheck.duplicate;
    if (_pendingAdds.contains(cleanName)) return AddCheck.pending;
    return AddCheck.ok;
  }

  /// Looks [cleanName] up and adds it to [favorites].
  ///
  /// The duplicate check used to run only BEFORE the lookup, so pressing
  /// Enter twice while it ran passed the check twice and stored the channel
  /// twice - and removing one copy then removed both. A name is now pending
  /// for the whole lookup, and checked again once it returns.
  Future<AddFavoriteOutcome> addFavorite(String cleanName) async {
    final check = checkAdd(cleanName);
    if (check != AddCheck.ok) return AddFavoriteOutcome(check: check);
    _pendingAdds.add(cleanName);
    try {
      final channel = TwitchChannel(username: cleanName);
      await _api.fetchChannelStats(channel, _settings());
      final error = channel.errorMessage;
      if (error != null) return AddFavoriteOutcome(error: error);
      if (favorites.any((c) => c.username == cleanName)) {
        return const AddFavoriteOutcome(check: AddCheck.duplicate);
      }
      favorites.add(channel);
      // Joining mid-broadcast is not going live: without this the next pass
      // announced a stream the user was looking at, and could auto-play it.
      if (channel.isLive) _liveFavorites.add(cleanName);
      _detailsAt[cleanName] = _now();
      _notify();
      return AddFavoriteOutcome(channel: channel);
    } finally {
      _pendingAdds.remove(cleanName);
    }
  }

  // ---------------------------------------------------------------------------

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    onPass = null;
    super.dispose();
  }
}
