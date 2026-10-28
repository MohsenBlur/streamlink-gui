import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../services/oauth_loopback_server.dart';
import '../services/twitch_api_service.dart';
import '../utils/twitch_auth_status.dart';
import 'channels_controller.dart';
import 'twitch_auth_notifier.dart';

/// Makes a sign-in listener; [OAuthLoopbackServer.new] in the app.
typedef SignInServerFactory = OAuthLoopbackServer Function(
    {required int port, required String clientId});

/// The account token: signing in with Connect Account, probing the token,
/// the account it belongs to, the followed list it loads, and what has to
/// be fetched again when a rejected token starts working.
///
/// Moved out of the main screen as it was, with the reconnect banner's
/// dismissal. The verdicts themselves are [TwitchAuth]'s (a global the API
/// service reports 401s to); this is what the app does about them.
class AccountController extends ChangeNotifier {
  AccountController({
    required TwitchApiService api,
    required ChannelsController channels,
    required TwitchAuth auth,
    required AppSettings Function() settings,
    required SignInServerFactory signInServer,
    required Future<void> Function(String url) openLink,
    required Future<void> Function() save,
    required bool Function() mounted,
    required bool Function() startupComplete,
    required Future<void> Function() refreshChannels,
    required VoidCallback refreshOpenVods,
    required VoidCallback followedLoaded,
    required void Function(String message, {required bool isError})
        showMessage,
  })  : _api = api,
        _channels = channels,
        _auth = auth,
        _settings = settings,
        _signInServer = signInServer,
        _openLink = openLink,
        _save = save,
        _mounted = mounted,
        _startupComplete = startupComplete,
        _refreshChannels = refreshChannels,
        _refreshOpenVods = refreshOpenVods,
        _followedLoaded = followedLoaded,
        _showMessage = showMessage;

  final TwitchApiService _api;
  final ChannelsController _channels;
  final TwitchAuth _auth;
  final AppSettings Function() _settings;
  final SignInServerFactory _signInServer;

  /// Opens [url] in the browser.
  final Future<void> Function(String url) _openLink;

  /// Writes the config now.
  final Future<void> Function() _save;
  final bool Function() _mounted;

  /// Startup has loaded the channels and fetched everything once.
  final bool Function() _startupComplete;

  /// One refresh of every channel's live state.
  final Future<void> Function() _refreshChannels;

  /// Fetches the open channel's VOD list again, clearing its error.
  final VoidCallback _refreshOpenVods;

  /// A followed list arrived: the open channel follows its streamer to the
  /// object the poll now keeps current.
  final VoidCallback _followedLoaded;
  final void Function(String message, {required bool isError}) _showMessage;

  OAuthLoopbackServer? _server;
  String? _login;
  String? _avatar;

  /// Whether the account token was usable at the last notification. With
  /// [_startupComplete], it identifies a RECOVERY - the moment a rejected
  /// token starts working again.
  bool _lastUsable = false;

  /// Dismissal of the reconnect banner, reset whenever the reason changes so
  /// a dismissed "expired" does not also hide a later "wrong Client ID".
  bool _bannerDismissed = false;
  TwitchAuthFault _dismissedFault = TwitchAuthFault.none;

  bool _attached = false;
  bool _disposed = false;

  /// The account the followed list was loaded for, and its avatar.
  String? get login => _login;
  String? get avatar => _avatar;

  /// Starts following the token's status.
  void attach() {
    if (_attached) return;
    _attached = true;
    _auth.helix.addListener(_onStatusChanged);
  }

  /// Re-fetches what a rejected token left stale.
  ///
  /// Reconnecting reloaded the FOLLOWED list and nothing else, so every
  /// favourite kept the error text stamped on it while the token was dead -
  /// "Helix Stream API error: status 401" sat on the selected channel until
  /// the one-minute favourites poll happened to clear it, minutes after the
  /// account was working again. The data was stale, not wrong, which is the
  /// worst kind of wrong to show someone who has just fixed the problem.
  void _onStatusChanged() {
    final usable = _auth.helix.value.isUsable;
    final recovered = usable && !_lastUsable;
    _lastUsable = usable;

    if (usable && _bannerDismissed) {
      // A dismissal covers the rejection it was shown for. Without this, one
      // dismissal would silence every future rejection carrying the same
      // reason, for the life of the process.
      _bannerDismissed = false;
      _dismissedFault = TwitchAuthFault.none;
    }

    if (!recovered || !_startupComplete()) return;
    unawaited(_refreshChannels());
    unawaited(loadFollowed());
    // ...and the open channel's VOD list, which is fetched per selection and
    // would otherwise keep its 401 until the user clicked away and back.
    _refreshOpenVods();
  }

  /// Whether the reconnect banner shows for [status].
  ///
  /// A different problem is a different message: a dismissal covers the
  /// reason it was shown for, not the topic, so a new reason lifts it.
  bool showsBanner(TwitchAuthStatus status) {
    if (status.needsReconnect &&
        _bannerDismissed &&
        status.fault != _dismissedFault) {
      _bannerDismissed = false;
    }
    return status.needsReconnect && !_bannerDismissed;
  }

  /// The reconnect banner was dismissed while it showed [fault].
  void dismissBanner(TwitchAuthFault fault) {
    _bannerDismissed = true;
    _dismissedFault = fault;
    _notify();
  }

  /// Connect Account: signs in through Twitch in the browser.
  ///
  /// The listener itself (state check, timeout, single-shot result) is
  /// OAuthLoopbackServer; this only starts it and applies what comes back.
  Future<void> signIn() async {
    // A second Connect replaces the first sign-in rather than racing it: the
    // older one's result arrives as cancelled and is ignored below.
    final previous = _server;
    _server = null;
    await previous?.close();

    final settings = _settings();
    final server = _signInServer(
      port: settings.localServerPort,
      clientId: settings.twitchClientId,
    );
    try {
      await server.start();
    } catch (e) {
      _showMessage('Failed to start local login server: ${describeTwitchError(e)}', isError: true);
      return;
    }
    _server = server;
    _showMessage('OAuth server started on port ${server.boundPort}. Opening browser...', isError: false);
    await _openLink(server.authorizeUrl);

    final result = await server.result;
    // Replaced by a newer sign-in, or the screen is gone.
    if (!identical(_server, server) || !_mounted()) return;
    _server = null;

    switch (result.outcome) {
      case OAuthLoopbackOutcome.token:
        await _acceptToken(result.accessToken!, mintedBy: server.clientId);
      case OAuthLoopbackOutcome.denied:
        _showMessage('Twitch did not connect the account: ${result.error}', isError: true);
      case OAuthLoopbackOutcome.timedOut:
        _showMessage(
            'The Twitch sign-in timed out. Click Connect Account to try again.',
            isError: false);
      case OAuthLoopbackOutcome.cancelled:
        break;
    }
  }

  Future<void> _acceptToken(String token, {required String mintedBy}) async {
    final settings = _settings();
    settings.twitchOauthToken = 'oauth:$token';
    // Record WHICH client minted it. Without this, editing the Client ID
    // field later produces a 401 the app would have to guess at, and it
    // would guess "expired" - sending the user through a reconnect that
    // cannot fix a mismatch. The Client ID the sign-in actually used, never
    // blank: the raw field was recorded before, which is empty when the
    // public fallback signed in, and an empty mint switches the mismatch
    // pre-check off.
    settings.twitchTokenClientId = mintedBy;
    _notify();
    await _save();
    final saved = _settings();
    _auth.setHelix(statusForToken(saved.twitchOauthToken,
        mintedClientId: saved.twitchTokenClientId));
    _showMessage('Twitch account connected successfully!', isError: false);
    // No explicit reload here: the probe publishes the new status, and
    // _onStatusChanged refreshes both lists off that transition. Calling it
    // here too fetched the followed list twice on every reconnect.
    await probe(force: true);
  }

  /// Loads the followed list (see ChannelsController.loadFollowed: coalesced,
  /// reconciled into the existing objects, live state in one batched pass).
  ///
  /// [background] is the periodic reload, so a new follow on twitch.tv turns
  /// up without a restart. It reports nothing but a refused token: an
  /// unattended reload that hit a network blip is not worth interrupting
  /// anyone for, and the previous list stays in place.
  Future<void> loadFollowed({bool background = false}) async {
    try {
      final result = await _channels.loadFollowed();
      if (!_mounted() || result == null) return;
      _login = result.userLogin;
      _avatar = result.userAvatar;
      _followedLoaded();
      _notify();
      if (!result.isComplete && !background) {
        // Not silent: a failed later page used to shorten the list without a
        // word. reconcileWith kept what it did not reach, so nothing went.
        final why = result.pageError == null
            ? ''
            : ': ${describeTwitchError(result.pageError!)}';
        _showMessage(
            'Showing ${_channels.followed.length} followed channels; Twitch '
            'did not return the rest$why',
            isError: true);
      }
    } catch (e) {
      if (!_mounted()) return;
      if (e is TwitchApiException && e.isAuthFailure) {
        // The banner does the talking, and it offers the one button that
        // actually fixes this. A snackbar cannot: it scrolls away, it has no
        // remedy on it, and it used to carry a raw JSON body.
        unawaited(probe(force: true));
      } else if (!background) {
        _showMessage(
            'Could not load followed channels: ${describeTwitchError(e)}',
            isError: true);
      }
    }
  }

  /// There is no account token any more: no account to show.
  void signedOut() {
    _login = null;
    _avatar = null;
    _notify();
  }

  /// Probes the account token and publishes the verdict.
  ///
  /// [force] re-probes even when the status is already known, which is what a
  /// Helix 401 and a fresh OAuth capture both need.
  Future<void> probe({bool force = false}) async {
    final settings = _settings();
    final token = settings.twitchOauthToken.trim();
    if (token.isEmpty) {
      _auth.setHelix(TwitchAuthStatus.absent);
      return;
    }
    final current = _auth.helix.value;
    if (!force && current.state == TwitchAuthState.valid) return;

    // A mismatch between the token's mint and the configured Client ID is
    // detectable with no request at all, which matters on an offline launch.
    final minted = settings.twitchTokenClientId.trim();
    // The effective one, as a sign-in records it: a blank field signs in,
    // and sends every request, with the public client.
    final configured =
        OAuthLoopbackServer.effectiveClientId(settings.twitchClientId);
    if (minted.isNotEmpty && minted != configured) {
      _auth.setHelix(TwitchAuthStatus(
        state: TwitchAuthState.invalid,
        fault: TwitchAuthFault.clientIdMismatch,
        login: current.login,
        tokenClientId: minted,
        checkedAt: DateTime.now(),
      ));
      return;
    }

    _auth.setHelix(statusChecking(current));
    final status = await _api.validateHelixToken(token, settings.twitchClientId);
    _auth.recordHelixProbe(status);
    if (_mounted()) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // A listener on a global notifier outlives the screen otherwise.
    if (_attached) _auth.helix.removeListener(_onStatusChanged);
    _server?.close();
    super.dispose();
  }
}
