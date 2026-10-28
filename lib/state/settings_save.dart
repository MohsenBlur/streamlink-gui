import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../services/startup_service.dart';
import '../utils/twitch_auth_status.dart';
import 'twitch_auth_notifier.dart';

/// What a Settings save replaced that something else has to follow.
@immutable
class SettingsChange {
  SettingsChange.between(AppSettings before, AppSettings after)
      : accountTokenChanged = before.twitchOauthToken.trim() !=
            after.twitchOauthToken.trim(),
        clientIdChanged =
            before.twitchClientId.trim() != after.twitchClientId.trim(),
        browserTokenChanged = before.twitchWebOauthToken.trim() !=
            after.twitchWebOauthToken.trim(),
        launchAtStartupChanged = before.launchAtStartup != after.launchAtStartup,
        canvasEngineTurnedOn = after.canvasEngine && !before.canvasEngine;

  /// Another account token, or none.
  final bool accountTokenChanged;
  final bool clientIdChanged;
  final bool browserTokenChanged;
  final bool launchAtStartupChanged;

  /// Simple rendering was turned on.
  final bool canvasEngineTurnedOn;

  /// The pair Helix requests go out with: the account token and the Client
  /// ID it is sent with.
  bool get helixChanged => accountTokenChanged || clientIdChanged;
}

/// Saving Settings, and everything a save sets off.
///
/// Moved out of the main screen's Settings dialog callback as it was. The
/// order matters: the new settings are adopted and written first, and only
/// then does anything act on them - the account status starts again from
/// the new credentials, the Run key and the tray menu follow, and the
/// followed list reloads for the new token or goes with the old one.
class SettingsSaveCoordinator {
  SettingsSaveCoordinator({
    required AppSettings Function() settings,
    required void Function(AppSettings updated) adopt,
    required Future<void> Function() save,
    required bool Function() mounted,
    required TwitchAuth auth,
    required Future<void> Function() probeAccount,
    required VoidCallback forgetFollowed,
    required StartupService startup,
    required VoidCallback rebuildTrayMenu,
    required VoidCallback loadFollowed,
    required VoidCallback signedOut,
    required VoidCallback canvasTurnedOn,
    required void Function(String message) showMessage,
  })  : _settings = settings,
        _adopt = adopt,
        _save = save,
        _mounted = mounted,
        _auth = auth,
        _probeAccount = probeAccount,
        _forgetFollowed = forgetFollowed,
        _startup = startup,
        _rebuildTrayMenu = rebuildTrayMenu,
        _loadFollowed = loadFollowed,
        _signedOut = signedOut,
        _canvasTurnedOn = canvasTurnedOn,
        _showMessage = showMessage;

  final AppSettings Function() _settings;

  /// Makes [updated] the settings everything reads, on screen too.
  final void Function(AppSettings updated) _adopt;

  /// Writes the config now.
  final Future<void> Function() _save;
  final bool Function() _mounted;
  final TwitchAuth _auth;

  /// Probes the account token now (a forced one).
  final Future<void> Function() _probeAccount;

  /// Drops the followed list, and any load still out for it.
  final VoidCallback _forgetFollowed;
  final StartupService _startup;
  final VoidCallback _rebuildTrayMenu;
  final VoidCallback _loadFollowed;

  /// There is no account token any more: no followed list, no account.
  final VoidCallback _signedOut;

  /// Simple rendering was turned on: the surfaces switch to Canvas now.
  final VoidCallback _canvasTurnedOn;
  final void Function(String message) _showMessage;

  Future<void> save(AppSettings updated) async {
    final change = SettingsChange.between(_settings(), updated);
    // Simple rendering takes effect at once when turned on: lit painters
    // repaint through Canvas the moment the engine is disabled. Turning it
    // off needs the shader loaded and self-tested, which happens at launch,
    // so that half waits for the next start.
    if (change.canvasEngineTurnedOn) _canvasTurnedOn();
    _adopt(updated);
    await _save();
    if (!_mounted()) return;
    final settings = _settings();

    // The status described credentials this save just replaced: "Connected
    // as A" stayed up for the session after switching to B, and clearing
    // the token left "Connected". Start again from what is known of the
    // new pair, and probe it now rather than at the next 401. The followed
    // list may be another account's, and so may a load still out for it.
    if (change.helixChanged) {
      _auth.setHelix(statusForToken(settings.twitchOauthToken,
          mintedClientId: settings.twitchTokenClientId));
      unawaited(_probeAccount());
    }
    if (change.browserTokenChanged) {
      _auth.setBrowser(statusForToken(settings.twitchWebOauthToken));
    }
    if (change.accountTokenChanged) _forgetFollowed();

    if (change.launchAtStartupChanged) {
      unawaited(_startup.sync(settings.launchAtStartup));
    }
    // The tray menu preference may have flipped.
    _rebuildTrayMenu();

    if (settings.twitchOauthToken.trim().isNotEmpty) {
      _loadFollowed();
    } else {
      _signedOut();
    }
    _showMessage('Settings saved successfully!');
  }
}
