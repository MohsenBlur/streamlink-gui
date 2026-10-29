import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../models/twitch_video.dart';
import '../services/storage_service.dart';
import '../services/twitch_api_service.dart';
import 'activity_state.dart';
import 'settings_repository.dart';
import 'watch_progress_store.dart';

/// Where every VOD got to, and which ones are being watched.
///
/// The watch positions in two shapes: the durable [WatchProgressStore] (the
/// furthest point ever reached, a short undo trail, and the guard that stops
/// a player which came up in the wrong place from writing over a good
/// position), and the flat `id -> seconds` copy every reader already used,
/// which is still written into channels_config.json so an older build finds
/// positions where it expects them. With them, the recently-watched list
/// and the VODs playing right now.
///
/// Moved out of the main screen as it was. When the files are written is
/// [SettingsRepository]'s business; what goes into them, and what a position
/// a player reports does on its way there, is this.
class WatchHistoryController extends ChangeNotifier {
  WatchHistoryController({
    required StorageService storage,
    required SettingsRepository repository,
    required TwitchApiService api,
    required AppSettings Function() settings,
    required List<TwitchVideo> Function() openVods,
    void Function(String vodId, String line)? log,
    void Function(Object error, StackTrace stack)? onLoadError,
    DateTime Function()? clock,
  })  : _storage = storage,
        _repository = repository,
        _api = api,
        _settings = settings,
        _openVods = openVods,
        _log = log,
        _onLoadError = onLoadError,
        _now = clock ?? DateTime.now;

  final StorageService _storage;
  final SettingsRepository _repository;
  final TwitchApiService _api;
  final AppSettings Function() _settings;

  /// The VOD list on screen, whose cards show a position as it moves.
  final List<TwitchVideo> Function() _openVods;
  final void Function(String vodId, String line)? _log;
  final void Function(Object error, StackTrace stack)? _onLoadError;
  final DateTime Function() _now;

  /// How long after a VOD starts behind its furthest point the jump back is
  /// offered (see [offerFurthestPosition]).
  static const Duration offerDelay = Duration(seconds: 6);

  WatchProgressStore _store = WatchProgressStore();
  Map<String, int> _flat = {};
  List<TwitchVideo> _recents = [];
  final Map<String, TwitchVideo> _playing = {};

  /// The last whole percent rebuilt for each playing VOD's progress, so a
  /// watch-position tick repaints only when something on screen would change.
  final Map<String, int> _buckets = {};

  bool _disposed = false;

  /// The durable record, which the sidecar file holds.
  WatchProgressStore get store => _store;

  /// The flat view, `id -> seconds`, derived from [store]: what every reader
  /// of a position uses, and the copy the config keeps.
  Map<String, int> get flat => _flat;

  /// Recently watched, newest first.
  List<TwitchVideo> get recents => _recents;

  /// The VODs being watched, by id. Only a player stopping clears an entry
  /// ([playbackStopped]), or a launch that never got going ([launchFailed]).
  Map<String, TwitchVideo> get playing => UnmodifiableMapView(_playing);

  /// True while a VOD is being watched.
  bool get isWatching => _playing.isNotEmpty;

  /// The flat copy the config holds, read at the first load. The sidecar,
  /// read next ([load]), is laid over it.
  void restoreFlat(Map<String, int> progress) {
    _flat = progress;
    _store = WatchProgressStore.fromJson(
        progress.map((k, v) => MapEntry(k, v as dynamic)));
  }

  /// Reads watch_progress.json and the recently-watched list into memory,
  /// then lets them be written - unless either is there but could not be
  /// read, when neither may be (see StorageReadFailure) until a later [load]
  /// reads them.
  Future<void> load() async {
    var read = true;
    try {
      // The sidecar is authoritative where it has an entry: it carries the
      // furthest point and the undo trail, which the flat compatibility copy
      // in the config cannot express.
      final sidecar = await _storage.loadWatchProgress();
      if (sidecar.isNotEmpty) {
        final merged = <String, dynamic>{
          ..._store.toJson(),
          ...sidecar,
        };
        _store = WatchProgressStore.fromJson(merged);
        _flat = _store.toFlatMap();
      }

      final recents = await _storage.loadRecentWatchedVods();
      if (!_disposed) {
        _recents = recents
            .map(TwitchVideo.tryFromJson)
            .whereType<TwitchVideo>()
            .toList();
        notifyListeners();
      }
    } on StorageReadFailure catch (e, st) {
      // Opened anyway, the next save rewrote the sidecar from the flat copy:
      // every furthest point and undo trail, gone.
      read = false;
      _onLoadError?.call(e, st);
    } catch (e, st) {
      // Both readers already fall back to empty on a damaged file; this is
      // for anything else, which must not stop the channels loading after it.
      _onLoadError?.call(e, st);
    } finally {
      if (read) _repository.markHistoryLoaded();
    }
  }

  /// [vod] is starting to play.
  void startPlaying(TwitchVideo vod) => _playing[vod.id] = vod;

  /// [vodId]'s launch failed before the service could arrange the stop
  /// callback that would otherwise clear it.
  void launchFailed(String vodId) => _playing.remove(vodId);

  /// The player for [key] stopped.
  ///
  /// The map of playing VODs was written when a VOD started and never
  /// cleared anywhere, so the first VOD played in a session made it
  /// permanently non-empty - and the automation guard that consults it then
  /// returned early on every subsequent pass, silently killing BOTH priority
  /// auto-play and VOD auto-download until the app was restarted.
  void playbackStopped(String key) {
    _playing.remove(key);
    // The position playback stopped at is the one to keep, so it is written
    // now rather than when the progress delay runs out.
    _buckets.remove(key);
    unawaited(_repository.flushProgress());
  }

  /// A position a playing VOD reported; answers whether it was kept.
  ///
  /// One chokepoint, and it can say no. A relaunched player that came up at
  /// the top of a five-hour VOD used to write its way over the stored
  /// position within seconds - here and on Twitch, where max(local, remote)
  /// cannot undo it. Answering false is what keeps it off Twitch: the
  /// tracker pushes only the positions kept here.
  bool record(String vodId, int position, double progress, int sessionAgeMs) {
    final result = _store.record(vodId, position,
        nowMs: _now().millisecondsSinceEpoch, sessionAgeMs: sessionAgeMs);
    if (!result.accepted) {
      if (result.outcome == ProgressWriteOutcome.rejectedSuspectRegression &&
          !_disposed) {
        _log?.call(
            vodId,
            '[System] Ignored a watch position of ${position}s: it is far behind '
            'the furthest point reached (${result.entry.best}s) and arrived in the '
            'first seconds of this session, which is what a failed resume looks '
            'like.');
      }
      return false;
    }
    if (_disposed) return true;

    // Every tick updates the state; only a tick that changes something on
    // screen notifies. This rebuilt the whole screen - the grid, the
    // carousel and all - every two seconds for as long as anything played,
    // while the cards draw progress to a whole percent.
    var visible = progressTickIsVisible(
      previousBucket: _buckets[vodId],
      progress: progress,
      previousStatus: null,
      status: null,
    );
    _buckets[vodId] = (progress * 100).floor();

    _flat[vodId] = position;
    final open = _openVods();
    final idx = open.indexWhere((v) => v.id == vodId);
    if (idx != -1) {
      open[idx].watchPosition = position;
      open[idx].watchProgress = progress;
    }

    final video = _playing[vodId];
    if (video != null) {
      video.watchPosition = position;
      video.watchProgress = progress;

      // Moving it to the front happens once per session; after that it is
      // already there, and nothing about the order changes.
      if (_recents.isEmpty || !identical(_recents.first, video)) {
        visible = true;
        _recents.removeWhere((v) => v.id == vodId);
        _recents.insert(0, video);

        final max = _settings().maxRecentlyWatched;
        if (_recents.length > max) {
          _recents = _recents.take(max).toList();
        }
      }
    }
    if (visible) notifyListeners();
    // Written within the repository's progress delay rather than on every
    // tick, and at once when the player stops ([playbackStopped]).
    _repository.noteProgress(recents: video != null);
    return true;
  }

  /// Calls [offer] with the furthest point reached, when [vod] starts
  /// playing behind it.
  ///
  /// Deferred rather than immediate: the player needs a moment to come up
  /// and register its control port before a seek can land, and the message
  /// is useless before there is something to seek. [stillPlaying] is asked
  /// then, at fire time.
  void offerFurthestPosition(
    TwitchVideo vod, {
    required bool Function() stillPlaying,
    required void Function(int best) offer,
  }) {
    if (_store[vod.id]?.hasRecoverablePosition != true) return;

    Future<void>.delayed(offerDelay, () {
      if (_disposed) return;
      if (!stillPlaying()) return;
      // Re-read at fire time, not before the wait. The session writes its own
      // position as soon as it has landed, so by now playback may already be
      // past the furthest point - in which case there is nothing to offer and
      // saying otherwise would just be noise.
      final entry = _store[vod.id];
      if (entry == null || !entry.hasRecoverablePosition) return;
      offer(entry.best);
    });
  }

  /// Marks [vods] watched, to their full length, or unwatched, back to the
  /// start; answers how many. Pushed to Twitch with a browser token, as a
  /// courtesy: the write that matters is the local one.
  int mark(Iterable<TwitchVideo> vods, {required bool watched}) {
    // No browser token required. Refusing without one blocked the whole
    // feature to protect a sync that Twitch rejects anyway; a token, when
    // present, is used opportunistically.
    final webToken = _settings().twitchWebOauthToken.trim();
    var count = 0;
    for (final vod in vods) {
      final target = watched ? _api.parseDurationToSeconds(vod.duration) : 0;
      _flat[vod.id] = target;
      // An explicit user action, so it may move the furthest point too -
      // "mark unwatched" has to genuinely mean unwatched.
      if (target <= 0) {
        _store.clear(vod.id);
      } else {
        _store.record(vod.id, target,
            nowMs: _now().millisecondsSinceEpoch,
            sessionAgeMs: kSessionGraceSeconds * 1000 + 1);
      }
      vod.watchPosition = target;
      vod.watchProgress = watched ? 1.0 : 0.0;
      count++;

      if (webToken.isNotEmpty) {
        try {
          _api
              .syncSingleVODProgressDirect(vod.id, target, webToken)
              .catchError((_) {});
        } catch (_) {}
      }
    }
    if (count > 0) _notify();
    return count;
  }

  /// What to tell the user after [mark] marked [count] VODs.
  ///
  /// Careful with this wording. Local progress is merged as max(local,
  /// remote) on the next fetch, so marking WATCHED sticks - it only ever
  /// raises the position - while marking UNWATCHED sets it to 0 and is
  /// silently overwritten by the remote position on the next fetch whenever
  /// a browser token is present. Claiming a clean local update would just
  /// replace one over-claim with another.
  String markedMessage(int count, {required bool watched}) {
    final hasBrowserToken = _settings().twitchWebOauthToken.trim().isNotEmpty;
    if (!watched && hasBrowserToken) {
      return 'Marked $count VODs unwatched here. Twitch still has a '
          'position for them, so this may come back on the next refresh.';
    }
    // Either way round: an Unwatched with no browser token said it had
    // marked them watched.
    return 'Marked $count VODs ${watched ? 'watched' : 'unwatched'} '
        'here. Twitch does not accept watch history from third-party '
        'apps, so this stays local.';
  }

  /// Every position goes, here and - with a browser token - on Twitch.
  Future<void> clearAll() async {
    _flat.clear();
    _store.clearAll();
    final open = _openVods();
    for (final vod in open) {
      // Both fields, not just the percentage: zeroing watchProgress while
      // leaving watchPosition was an internally inconsistent state, and a
      // play derives progress FROM position - so a lone position would
      // resurrect the "progress" this action exists to clear.
      vod.watchProgress = 0.0;
      vod.watchPosition = 0;
    }
    _notify();
    await _repository.saveNow();

    // Best-effort push of the reset to Twitch, else the remote max-merge
    // restores the old positions on the next fetch and the clear appears
    // not to have worked. Mirrors [mark].
    String webToken = _settings().twitchWebOauthToken.trim();
    if (webToken.startsWith('oauth:')) webToken = webToken.substring(6);
    if (webToken.isNotEmpty) {
      for (final vod in open) {
        try {
          await _api.syncSingleVODProgressDirect(vod.id, 0, webToken);
        } catch (_) {
          break; // one failure means the rest will fail the same way
        }
      }
    }
  }

  /// [vodId] leaves the recently-watched list, and its position goes with it.
  Future<void> forget(String vodId) async {
    _recents.removeWhere((v) => v.id == vodId);
    _flat.remove(vodId);
    _store.clear(vodId);
    _notify();
    // All three files, through the repository: the list was written straight
    // through the storage service, round the gate that keeps it from being
    // written before it has been read.
    await _repository.saveNow(recents: true);
  }

  /// `H:MM:SS`, or `MM:SS` under an hour, for a position in a message.
  static String clockLabel(int totalSeconds) {
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final sec = totalSeconds % 60;
    String two(int v) => v < 10 ? '0$v' : '$v';
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
