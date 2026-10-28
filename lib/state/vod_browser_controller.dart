import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../models/twitch_channel.dart';
import '../models/twitch_video.dart';
import '../services/twitch_api_service.dart';
import '../utils/twitch_auth_status.dart';
import 'channel_transitions.dart';
import 'vod_cache.dart';
import 'vod_merge.dart';

/// How a fetch that reached the grid ended.
class VodFetchOutcome {
  const VodFetchOutcome({
    required this.changedVisible,
    this.isWebTokenExpired = false,
  });

  /// Whether the list on screen changed.
  final bool changedVisible;

  /// Twitch refused the browser token while reading watch positions.
  final bool isWebTokenExpired;
}

/// A refresh failed, and the list on screen is an older one.
class StaleVodList {
  const StaleVodList({required this.since, required this.reason});

  /// When the list on screen was fetched.
  final DateTime since;

  /// Why the refresh failed, fit for the UI.
  final String reason;
}

/// Whether the open list's background refreshes (the few-minute cadence,
/// coming back from the tray) are worth trying with the account token in
/// [helix].
///
/// Not [TwitchAuthStatus.isUsable]. A token missing `user:read:follows` is
/// `invalid` for good - the followed list needs that scope - yet helix/videos
/// asks for none and answers it, so gating on isUsable left that account's
/// grid as stale as before the refreshes existed. Unverified, checking and
/// unreachable mean "we don't know", and trying is what puts the "couldn't
/// refresh" note over a list that has gone old. Only a token Helix is known
/// to refuse (revoked, or minted for another Client ID) is left alone: it
/// would collect a 401 every few minutes, and fixing it refreshes the list
/// anyway.
bool backgroundVodRefreshAllowed(TwitchAuthStatus helix) {
  switch (helix.state) {
    case TwitchAuthState.absent:
      return false;
    case TwitchAuthState.invalid:
      return helix.fault == TwitchAuthFault.missingScope;
    case TwitchAuthState.unverified:
    case TwitchAuthState.checking:
    case TwitchAuthState.valid:
    case TwitchAuthState.unreachable:
      return true;
  }
}

/// The VOD grid's list for the open channel, its "Load more" cursor, the
/// per-channel cache behind it, and the refreshes that keep it current.
///
/// The list was fetched in exactly three places - selecting a channel, Load
/// more, and the token starting to work again - so a VOD that appeared while
/// a channel was open, or an in-progress broadcast's growing duration, only
/// showed after clicking another channel and back. [refresh] fetches the
/// first page again and merges it in by id ([mergeFirstPage]), so the pages
/// loaded with Load more, the cursor, the scroll position and the selection
/// all survive it.
class VodBrowserController extends ChangeNotifier {
  VodBrowserController({
    required TwitchApiService api,
    required AppSettings Function() settings,
    required Map<String, int> Function() localProgress,
    VodCache? cache,
    NewVodDetector? detector,
    DateTime Function()? clock,
  })  : _api = api,
        _settings = settings,
        _localProgress = localProgress,
        _now = clock ?? DateTime.now,
        cache = cache ?? VodCache(clock: clock),
        _detector = detector ?? NewVodDetector();

  /// How often the open channel's list is refreshed while the window is on
  /// screen.
  static const Duration visibleRefreshInterval = Duration(minutes: 4);

  /// A list older than this is refreshed when the window comes back into
  /// view, and is called out as old when a refresh over it fails.
  static const Duration staleAfter = Duration(seconds: 60);

  /// Favourites prefetched in the background, so opening one is instant.
  static const int prefetchLimit = 10;

  final TwitchApiService _api;
  final AppSettings Function() _settings;
  final Map<String, int> Function() _localProgress;
  final DateTime Function() _now;
  final NewVodDetector _detector;

  final VodCache cache;

  /// A VOD became available on [channel]: a broadcast that ended, or one
  /// published while the app was watching. Never fired for the first list
  /// seen for a channel, which is a baseline (see [NewVodDetector]).
  /// [firstPage] is the page they were found in, newest first, which is what
  /// the auto-download pass chooses from.
  void Function(TwitchChannel channel, List<TwitchVideo> vods,
      List<TwitchVideo> firstPage)? onNewVods;

  /// The channel whose list this is, or null before one is opened.
  TwitchChannel? get channel => _channel;
  TwitchChannel? _channel;

  /// The list on screen. Callers may update entries in place (a watch
  /// position), but never hold the list across a refresh: it is replaced.
  List<TwitchVideo> get vods => _vods;
  List<TwitchVideo> _vods = <TwitchVideo>[];

  /// Continues [vods] with "Load more"; null when there is nothing more or
  /// the first page has not arrived yet.
  String? get cursor => _cursor;
  String? _cursor;

  /// Pages on screen: 0 until the first page arrives (a cached list may be
  /// showing meanwhile), then one more per Load more.
  int _pagesLoaded = 0;

  /// A fetch the grid shows a spinner for: opening a channel with nothing
  /// cached, or Load more.
  bool get isLoading => _isLoadingFirst || _isLoadingMore;
  bool _isLoadingFirst = false;
  bool _isLoadingMore = false;

  /// A refresh the user asked for. The list stays on screen meanwhile.
  bool get isRefreshing => _isRefreshing;
  bool _isRefreshing = false;

  /// Why the list could not be loaded at all. Only set while [vods] is
  /// empty: over a list, a failure is [stale] instead.
  String? get error => _error;
  String? _error;
  set error(String? value) {
    if (value == _error) return;
    _error = value;
    _notify();
  }

  /// Set when the last refresh failed and the list on screen is more than
  /// [staleAfter] old - or of any age, when the user asked for that refresh.
  /// A failed fetch over a cached list used to say nothing at all, so a list
  /// from hours ago passed for a current one.
  StaleVodList? get stale => _stale;
  StaleVodList? _stale;

  /// When the list on screen was requested from Twitch.
  DateTime? get fetchedAt => _fetchedAt;
  DateTime? _fetchedAt;

  bool _disposed = false;

  /// Bumped whenever a different channel is opened; a fetch started under an
  /// older value may only reach the cache.
  int _session = 0;
  int _firstPageRequest = 0;
  int _loadMoreRequest = 0;
  Future<VodFetchOutcome?>? _firstPage;
  int _firstPageInFlight = -1;
  int _firstPageSession = -1;

  /// What the first-page fetch in flight looks for when it lands. A refresh
  /// that joins the fetch adds its own ask to it.
  _FirstPageAsk? _firstPageAsk;

  /// Whether [channel]'s list is the one this holds.
  bool isShowing(TwitchChannel channel) =>
      _channel != null && _sameChannel(_channel!, channel);

  /// Opens [channel]: shows its cached list at once, then fetches the first
  /// page. With [fetch] false (no account token) the list is simply emptied.
  Future<VodFetchOutcome?> open(TwitchChannel channel, {bool fetch = true}) {
    _session++;
    _channel = channel;
    final cached = fetch ? cache.read(channel.username) : null;
    // A copy (VodCache.read makes one): this list is updated in place.
    _vods = cached ?? <TwitchVideo>[];
    _cursor = null;
    _pagesLoaded = 0;
    _error = null;
    _stale = null;
    _fetchedAt = cached == null ? null : cache.fetchedAt(channel.username);
    _isRefreshing = false;
    _isLoadingFirst = fetch && cached == null;
    _isLoadingMore = false;
    _notify();
    if (!fetch) return Future<VodFetchOutcome?>.value();
    // No refresh spinner: an empty list shows the grid's own loading state,
    // and a cached one is worth reading while the fetch runs.
    return _startFirstPage(showSpinner: false);
  }

  /// Fetches the open channel's first page again and merges it in.
  ///
  /// [silent] (the timer, a window coming back, a broadcast changing) leaves
  /// the spinner alone; otherwise [isRefreshing] is set while it runs. A
  /// fetch of the first page already under way is joined rather than
  /// repeated. [endedBroadcastStart] is the start of a broadcast that just
  /// ended on this channel, for [onNewVods].
  Future<VodFetchOutcome?> refresh({
    bool silent = true,
    DateTime? endedBroadcastStart,
  }) {
    if (_channel == null) return Future<VodFetchOutcome?>.value();
    final running = _firstPage;
    if (running != null &&
        _firstPageInFlight == _firstPageRequest &&
        _firstPageSession == _session) {
      if (!silent) _startSpinner();
      // Joined, so the fetch it joins carries the broadcast to look for. It
      // was dropped here, and when that fetch was the channel's first one -
      // a broadcast ending while the channel was just being opened - its
      // list became the baseline and the VOD was never announced.
      _firstPageAsk?.lookFor(endedBroadcastStart);
      return running;
    }
    return _startFirstPage(
        showSpinner: !silent, endedBroadcastStart: endedBroadcastStart);
  }

  /// A silent [refresh], unless the list on screen is younger than [maxAge].
  Future<VodFetchOutcome?> refreshIfOlderThan(Duration maxAge) {
    final at = _fetchedAt;
    if (_channel == null ||
        _api.helixRateLimitedUntil != null ||
        (at != null && _now().difference(at) < maxAge)) {
      return Future<VodFetchOutcome?>.value();
    }
    return refresh();
  }

  Future<VodFetchOutcome?> _startFirstPage({
    required bool showSpinner,
    DateTime? endedBroadcastStart,
  }) {
    final request = ++_firstPageRequest;
    _firstPageInFlight = request;
    _firstPageSession = _session;
    final ask = _firstPageAsk = _FirstPageAsk(endedBroadcastStart);
    final future = _runFirstPage(request, showSpinner: showSpinner, ask: ask);
    _firstPage = future;
    return future;
  }

  Future<VodFetchOutcome?> _runFirstPage(
    int request, {
    required bool showSpinner,
    required _FirstPageAsk ask,
  }) async {
    final channel = _channel!;
    final session = _session;
    bool isCurrent() => session == _session && request == _firstPageRequest;
    final startedAt = _now();
    final listedAs = ChannelSnapshot.of(channel);
    if (showSpinner) _startSpinner();
    try {
      final result = await _api.fetchVodsForChannel(
        channel: channel,
        settings: _settings(),
        localVodsProgress: _localProgress(),
      );
      if (_disposed) return null;
      // Absorbed whatever became of the selection meanwhile: a fetch
      // overtaken by a click on another channel is still the freshest list
      // for its own channel, and used to be thrown away before it was cached.
      final changed = _absorb(channel, result,
          fetchedAt: startedAt,
          listedAs: listedAs,
          detailed: true,
          visible: isCurrent(),
          endedBroadcastStart: ask.endedBroadcastStart);
      if (!isCurrent()) return null;
      return VodFetchOutcome(
        changedVisible: changed,
        isWebTokenExpired: result.isWebTokenExpired,
      );
    } catch (e) {
      if (_disposed || !isCurrent()) return null;
      _recordFailure(e);
      return null;
    } finally {
      if (_firstPageInFlight == request) {
        _firstPage = null;
        _firstPageInFlight = -1;
        _firstPageAsk = null;
      }
      if (!_disposed && isCurrent()) {
        _isLoadingFirst = false;
        _isRefreshing = false;
        _notify();
      }
    }
  }

  /// Appends the next page.
  Future<VodFetchOutcome?> loadMore() async {
    final channel = _channel;
    final after = _cursor;
    if (channel == null || after == null || after.isEmpty || isLoading) {
      return null;
    }
    final session = _session;
    final request = ++_loadMoreRequest;
    bool isCurrent() => session == _session && request == _loadMoreRequest;
    _isLoadingMore = true;
    _error = null;
    _notify();
    try {
      final result = await _api.fetchVodsForChannel(
        channel: channel,
        settings: _settings(),
        localVodsProgress: _localProgress(),
        afterCursor: after,
      );
      if (_disposed || !isCurrent()) return null;
      _vods = appendVodPage(_vods, result.vods);
      _cursor = result.nextCursor;
      _pagesLoaded++;
      cache.store(channel.username, _vods, fetchedAt: _fetchedAt);
      return VodFetchOutcome(
        changedVisible: true,
        isWebTokenExpired: result.isWebTokenExpired,
      );
    } catch (e) {
      if (_disposed || !isCurrent()) return null;
      if (_vods.isEmpty) _error = describeTwitchError(e);
      return null;
    } finally {
      if (!_disposed && isCurrent()) {
        _isLoadingMore = false;
        _notify();
      }
    }
  }

  /// Takes in a first page fetched for [channel] somewhere else - the
  /// auto-download pass, a broadcast-ended check - so the cache and, when
  /// [channel] is open, the grid get what the app already paid for.
  ///
  /// [detailed] is false for a fetch that skipped the per-VOD game lookup:
  /// games already known are kept, and the list does not count as freshly
  /// fetched for [visibleRefreshInterval], so the next full refresh still
  /// comes round to fill them in.
  ///
  /// [listedAs] is [channel]'s broadcast as it was when the request began;
  /// without it, as it is now.
  bool ingest(
    TwitchChannel channel,
    VodsFetchResult result, {
    required DateTime fetchedAt,
    bool detailed = true,
    DateTime? endedBroadcastStart,
    ChannelSnapshot? listedAs,
  }) {
    final shown = _fetchedAt;
    final visible = isShowing(channel) &&
        (shown == null || !fetchedAt.isBefore(shown));
    final changed = _absorb(channel, result,
        fetchedAt: fetchedAt,
        listedAs: listedAs ?? ChannelSnapshot.of(channel),
        detailed: detailed,
        visible: visible,
        endedBroadcastStart: endedBroadcastStart);
    if (visible) _notify();
    return changed;
  }

  bool _prefetching = false;

  /// Each channel's broadcast as it was when the request for its cached list
  /// began, by clean username: a list fetched before a broadcast started or
  /// ended is missing that broadcast's VOD, however young it is. It used to
  /// be taken when the answer landed, so a broadcast that started or ended
  /// while the request was out counted as listed, and the list without its
  /// VOD passed for current for the whole of the cache's TTL.
  final Map<String, ChannelSnapshot> _listedAs = <String, ChannelSnapshot>{};

  /// Clean usernames whose list [checkForNewVods] is fetching right now.
  final Set<String> _checking = <String>{};

  /// Fetches the lists of up to [prefetchLimit] of [channels] that have
  /// nothing cached, only something older than [VodCache.ttl], or a list
  /// from before their broadcast last started or ended. One pass at a time,
  /// one channel after another.
  ///
  /// Called after every poll, so this is the background's steady cost: it
  /// used to re-read every favourite's list each ten minutes, with one GQL
  /// request per VOD for the browser token's watch positions - about twenty a
  /// minute, for lists nobody had opened. Those positions are skipped now
  /// (opening a channel fetches its first page, positions and all), the open
  /// channel is left to [refresh], and so is a channel [checkForNewVods] is
  /// already fetching.
  ///
  /// [open] is the channel the screen has open, or null when it shows none.
  /// Only that one is left to [refresh]: the screen refreshes the channel it
  /// has open, while this controller goes on holding the last one opened
  /// after the screen goes back to the dashboard. Skipping whatever it held
  /// left that channel to no refresh at all until another one was opened.
  Future<void> prefetch(Iterable<TwitchChannel> channels,
      {required TwitchChannel? open}) async {
    if (_prefetching || _settings().twitchOauthToken.trim().isEmpty) return;
    _prefetching = true;
    try {
      final refreshed = open != null && isShowing(open) ? open : null;
      for (final channel in channels.take(prefetchLimit).toList()) {
        if (_disposed || _api.helixRateLimitedUntil != null) return;
        final key = _key(channel.username);
        if (refreshed != null && _sameChannel(refreshed, channel)) continue;
        if (_checking.contains(key)) continue;
        if (cache.isFresh(channel.username) &&
            !broadcastChanged(_listedAs[key], channel)) {
          continue;
        }
        final startedAt = _now();
        final listedAs = ChannelSnapshot.of(channel);
        try {
          final result = await _api.fetchVodsForChannel(
            channel: channel,
            settings: _settings(),
            localVodsProgress: _localProgress(),
            fetchWatchProgress: false,
          );
          if (_disposed) return;
          // Not detailed: should the channel have been opened meanwhile, a
          // list without watch positions must not count as its refresh.
          ingest(channel, result,
              fetchedAt: startedAt, listedAs: listedAs, detailed: false);
        } catch (_) {}
      }
    } finally {
      _prefetching = false;
    }
  }

  /// Looks for the VOD of a broadcast that just ended on [channel], which is
  /// not the open one (that one is [refresh]ed). Cheap: no game lookups.
  Future<void> checkForNewVods(
    TwitchChannel channel, {
    DateTime? endedBroadcastStart,
  }) async {
    if (_settings().twitchOauthToken.trim().isEmpty) return;
    final key = _key(channel.username);
    final startedAt = _now();
    final listedAs = ChannelSnapshot.of(channel);
    _checking.add(key);
    try {
      final result = await _api.fetchVodsForChannel(
        channel: channel,
        settings: _settings(),
        localVodsProgress: _localProgress(),
        fetchGames: false,
      );
      if (_disposed) return;
      ingest(channel, result,
          fetchedAt: startedAt,
          listedAs: listedAs,
          detailed: false,
          endedBroadcastStart: endedBroadcastStart);
    } catch (_) {
    } finally {
      _checking.remove(key);
    }
  }

  /// Folds a first page into the cache, the new-VOD check and - when
  /// [visible] - the list on screen. Returns whether the list on screen
  /// changed. Does not notify.
  bool _absorb(
    TwitchChannel channel,
    VodsFetchResult result, {
    required DateTime fetchedAt,
    required ChannelSnapshot listedAs,
    required bool detailed,
    required bool visible,
    DateTime? endedBroadcastStart,
  }) {
    var changed = false;
    if (visible) {
      final merged = mergeFirstPage(
        current: _vods,
        currentCursor: _cursor,
        hasLoadedMore: _pagesLoaded > 1,
        fresh: result.vods,
        freshCursor: result.nextCursor,
      );
      changed = merged.changed;
      _vods = merged.vods;
      _cursor = merged.cursor;
      if (_pagesLoaded == 0) _pagesLoaded = 1;
      if (detailed) _fetchedAt = fetchedAt;
      _error = null;
      _stale = null;
      cache.store(channel.username, _vods, fetchedAt: fetchedAt);
    } else {
      final cached = cache.read(channel.username);
      cache.store(
        channel.username,
        cached == null
            ? result.vods
            : mergeFirstPage(
                current: cached,
                currentCursor: null,
                hasLoadedMore: true,
                fresh: result.vods,
                freshCursor: result.nextCursor,
              ).vods,
        fetchedAt: fetchedAt,
      );
    }
    _listedAs[_key(channel.username)] = listedAs;

    final appeared = _detector.observe(
      channel.username,
      result.vods,
      isLive: channel.isLive,
      liveSince: channel.wentLiveTime,
      endedBroadcastStart: endedBroadcastStart,
    );
    if (appeared.isNotEmpty) {
      try {
        onNewVods?.call(channel, appeared, result.vods);
      } catch (e, stack) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: e,
          stack: stack,
          library: 'vod browser controller',
          context: ErrorDescription('while announcing new VODs'),
        ));
      }
    }
    return changed;
  }

  /// A refresh the user asked for shows that it is running: over an empty
  /// list in the grid's own loading state, over a list in the toolbar.
  void _startSpinner() {
    if (isLoading || _isRefreshing) return;
    if (_vods.isEmpty) {
      _isLoadingFirst = true;
    } else {
      _isRefreshing = true;
    }
    _notify();
  }

  void _recordFailure(Object e) {
    final reason = describeTwitchError(e);
    if (_vods.isEmpty) {
      _error = reason;
      return;
    }
    // A refresh the user asked for (the toolbar spinner is up) says it
    // failed however new the list is. Over one under a minute old it used to
    // say nothing: the spinner stopped, which reads as "nothing new".
    if (_isRefreshing) {
      final since = _fetchedAt ?? cache.fetchedAt(_channel!.username);
      if (since != null) _stale = StaleVodList(since: since, reason: reason);
      return;
    }
    final since = _fetchedAt;
    if (since != null && _now().difference(since) >= staleAfter) {
      _stale = StaleVodList(since: since, reason: reason);
    }
  }

  static bool _sameChannel(TwitchChannel a, TwitchChannel b) =>
      identical(a, b) || _key(a.username) == _key(b.username);

  static String _key(String username) => username.toLowerCase().trim();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    onNewVods = null;
    super.dispose();
  }
}

/// One first-page fetch's instructions for when its answer lands. Mutable,
/// and one per fetch, so a refresh that joins the fetch reaches that fetch
/// and no later one.
class _FirstPageAsk {
  _FirstPageAsk(this.endedBroadcastStart);

  /// The start of a broadcast that ended on the channel (see
  /// [NewVodDetector.observe]).
  DateTime? endedBroadcastStart;

  /// One more ended broadcast to look for; the earliest start is kept. On a
  /// channel's first list everything dated from that start on is announced,
  /// so the earliest covers each broadcast that ended while the fetch was
  /// out. The latest used to win, and two ends inside one fetch announced
  /// only the second one's VOD.
  void lookFor(DateTime? start) {
    if (start == null) return;
    final current = endedBroadcastStart;
    if (current == null || start.isBefore(current)) {
      endedBroadcastStart = start;
    }
  }
}
