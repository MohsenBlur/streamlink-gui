import 'dart:convert';
import 'dart:typed_data';

import '../models/app_settings.dart';
import '../utils/dpapi.dart';

/// Turns secret bytes into bytes that are safe to leave on disk, and back.
abstract interface class SecretCipher {
  /// The sealed form of [plain], or null if sealing failed.
  Uint8List? seal(Uint8List plain);

  /// The plaintext of [sealed], or null if it cannot be opened here.
  Uint8List? open(Uint8List sealed);
}

/// Seals with Windows DPAPI for the current user.
class DpapiSecretCipher implements SecretCipher {
  const DpapiSecretCipher();

  /// Ties the blobs to this app: another program asking DPAPI to open them
  /// must also know this. Changing it orphans every sealed token, so it is
  /// versioned with [ConfigSecrets.sealedPrefix] rather than ever edited.
  static final Uint8List _entropy =
      Uint8List.fromList(utf8.encode('TwitchStreamlinkGUI/config-token/v1'));

  @override
  Uint8List? seal(Uint8List plain) => Dpapi.protect(plain, entropy: _entropy);

  @override
  Uint8List? open(Uint8List sealed) =>
      Dpapi.unprotect(sealed, entropy: _entropy);
}

/// Keeps the account tokens in channels_config.json sealed at rest.
///
/// Both tokens used to sit there in plaintext, and the browser one is the
/// twitch.tv `auth-token` session cookie, which acts as the whole account.
/// The file travels further than it looks: AppData sync and backups, copies
/// attached to support requests, and the quarantined `.corrupt-*` copies.
///
/// Only the token values change. A sealed value is `dpapi:v1:<base64>` in
/// the SAME key the plaintext used, never a new key beside a blanked one:
/// `saveConfig` rewrites the file wholesale, so an older build deletes any
/// key it does not know within seconds of starting, and moving the tokens
/// would have wiped them on the first downgrade. In the same key, an older
/// build reads the sealed string as an opaque token. It does not crash and it
/// writes the string back unchanged, so coming back to this build restores
/// the token; while on the older build, Twitch rejects it, so the account
/// shows as rejected until it is reconnected there, which writes a plaintext
/// token this build then seals again.
///
/// Empty tokens stay `''`, so a config with no account is unchanged.
class ConfigSecrets {
  ConfigSecrets(this.cipher);

  /// Null where nothing can seal (off Windows, and under tests unless one
  /// supplies a cipher): tokens are then stored as typed, as every build
  /// before this one did.
  final SecretCipher? cipher;

  static const String sealedPrefix = 'dpapi:v1:';

  static bool isSealed(Object? value) =>
      value is String && value.startsWith(sealedPrefix);

  /// The last sealed form of each token, so an unchanged token is not
  /// re-sealed on every autosave. DPAPI output is salted, so re-sealing would
  /// also rewrite the stored value on every save for no reason.
  final Map<String, ({String plain, String sealed})> _lastSealed = {};

  /// Sealed values found on disk that cannot be opened here, by key.
  ///
  /// They are put back on save, not replaced with the empty token the app is
  /// running with. A config moved from another account or machine, or a
  /// portable install carried between PCs, then simply shows "not
  /// connected" here instead of destroying the token for the place it does
  /// open. Entering a new token replaces it.
  final Map<String, String> _unopenable = {};

  /// Autosaves run every couple of seconds during playback, so a lasting
  /// sealing failure is reported once rather than on each of them.
  bool _reportedSealFailure = false;

  /// A copy of [settingsJson], as written by `AppSettings.toJson`, with every
  /// token in its at-rest form.
  Map<String, dynamic> sealForDisk(Map<String, dynamic> settingsJson) {
    final out = Map<String, dynamic>.from(settingsJson);
    for (final key in AppSettings.secretJsonKeys) {
      final value = settingsJson[key];
      if (value is! String) continue;
      if (value.isEmpty) {
        final kept = _unopenable[key];
        if (kept != null) out[key] = kept;
        continue;
      }
      _unopenable.remove(key);
      out[key] = _seal(key, value);
    }
    return out;
  }

  /// Replaces every sealed token in [settingsJson] with its plaintext, in
  /// place, so the rest of the app only ever sees plaintext.
  ///
  /// Returns the settings as they should now be on disk when this found a
  /// plaintext token it could seal (a config written by an older build), so
  /// the caller can migrate the file at once rather than at the next save;
  /// null when the file needs no rewrite.
  Map<String, dynamic>? openFromDisk(Map<String, dynamic> settingsJson) {
    final onDisk = Map<String, dynamic>.from(settingsJson);
    var needsRewrite = false;
    for (final key in AppSettings.secretJsonKeys) {
      final stored = settingsJson[key];
      if (stored is! String || stored.isEmpty) {
        _unopenable.remove(key);
        continue;
      }

      if (isSealed(stored)) {
        final plain = _open(stored);
        if (plain == null) {
          print('[Config] A stored token cannot be decrypted by this Windows '
              'account; it is kept as it is and treated as not connected.');
          _unopenable[key] = stored;
          settingsJson[key] = '';
        } else {
          _unopenable.remove(key);
          _lastSealed[key] = (plain: plain, sealed: stored);
          settingsJson[key] = plain;
        }
        continue;
      }

      // Plaintext, from a build before sealing or one that could not seal.
      _unopenable.remove(key);
      if (cipher == null) continue;
      final sealed = _seal(key, stored);
      if (sealed != stored) {
        onDisk[key] = sealed;
        needsRewrite = true;
      }
    }
    return needsRewrite ? onDisk : null;
  }

  /// [plain] in its at-rest form, or null where it cannot be sealed. Nothing
  /// is remembered for the next save, unlike [sealForDisk].
  String? sealText(String plain) {
    final active = cipher;
    if (active == null) return null;
    final bytes = active.seal(Uint8List.fromList(utf8.encode(plain)));
    return bytes == null ? null : sealedPrefix + base64.encode(bytes);
  }

  /// [text], a quarantined `.corrupt-*` copy of the config, with each
  /// plaintext token in it sealed; null when it has none, or none can be.
  ///
  /// A copy is a whole config that could not be read back, so it carries
  /// the tokens too: in plaintext when an older build wrote it, or when it
  /// was quarantined before its tokens were ever migrated. It cannot be
  /// parsed - that is why it was quarantined - so this works on the raw
  /// text, swapping each token key's string value for its sealed form and
  /// leaving every other character as it was, for whoever recovers the file
  /// by hand: put back as the config, this build opens the tokens again. A
  /// value the damage cut off at the end of the text is sealed as far as it
  /// goes.
  String? sealTokensInText(String text) {
    var changed = false;
    final sealed = text.replaceAllMapped(_tokenInText, (match) {
      final raw = match[2]!;
      if (raw.isEmpty || isSealed(raw)) return match[0]!;
      final value = sealText(_jsonStringOrRaw(raw));
      if (value == null) return match[0]!;
      changed = true;
      return '${match[1]}$value${match[3]}';
    });
    return changed ? sealed : null;
  }

  /// [text] with every token's value emptied, sealed or not, and every other
  /// character as it was; null when it holds no token that is not already
  /// empty.
  ///
  /// For the config an older build mirrored beside the executable
  /// (`StorageService.scrubStaleConfigMirror`), which can also be a portable
  /// copy's real config, so only the credentials go. Raw text, as in
  /// [sealTokensInText], so a file that does not parse is scrubbed too; a
  /// value cut off by the end of the text stays unterminated.
  static String? blankTokensInText(String text) {
    var changed = false;
    final blanked = text.replaceAllMapped(_tokenInText, (match) {
      if (match[2]!.isEmpty) return match[0]!;
      changed = true;
      return '${match[1]}${match[3] == '"' ? '"' : ''}';
    });
    return changed ? blanked : null;
  }

  /// `"<token key>" : "` (group 1), the string's contents (group 2), and its
  /// closing quote, or the end of a text that stops inside it (group 3).
  static final RegExp _tokenInText = RegExp(
    '("(?:${AppSettings.secretJsonKeys.map(RegExp.escape).join('|')})"'
    r'\s*:\s*")((?:[^"\\]|\\.)*)("|\\?$)',
  );

  static String _jsonStringOrRaw(String raw) {
    try {
      return json.decode('"$raw"') as String;
    } catch (_) {
      return raw;
    }
  }

  String _seal(String key, String plain) {
    final previous = _lastSealed[key];
    if (previous != null && previous.plain == plain) return previous.sealed;

    if (cipher == null) return plain;
    final sealed = sealText(plain);
    if (sealed == null) {
      // Kept in plaintext rather than dropped: losing the token on a save is
      // worse than the exposure every earlier build had. Not cached, so the
      // next save tries to seal it again.
      if (!_reportedSealFailure) {
        _reportedSealFailure = true;
        print('[Config] A token could not be encrypted, so it is being saved '
            'unencrypted until encryption works again.');
      }
      return plain;
    }
    _lastSealed[key] = (plain: plain, sealed: sealed);
    return sealed;
  }

  String? _open(String stored) {
    final active = cipher;
    if (active == null) return null;
    try {
      final bytes = active
          .open(base64.decode(stored.substring(sealedPrefix.length)));
      return bytes == null ? null : utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }
}
