import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/app_settings.dart';
import 'package:streamlink_gui/services/config_secrets.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/utils/dpapi.dart';

import 'support/fake_cipher.dart';

const _account = 'abcdefghijklmnopqrstuvwxyz0123';
const _browser = 'zyxwvutsrqponmlkjihgfedcba9876';

Map<String, dynamic> _settingsJson({String account = _account, String browser = _browser}) =>
    AppSettings(twitchOauthToken: account, twitchWebOauthToken: browser).toJson();

void main() {
  group('AppSettings.secretJsonKeys', () {
    test('names exactly the fields that hold the two tokens', () {
      // If a token field were renamed in toJson without this list following,
      // it would silently go to disk in plaintext.
      final json = _settingsJson();
      expect(AppSettings.secretJsonKeys, hasLength(2));
      expect(
        {for (final key in AppSettings.secretJsonKeys) json[key]},
        {_account, _browser},
      );
    });
  });

  group('ConfigSecrets', () {
    test('seals both tokens on the way to disk and leaves everything else alone', () {
      final secrets = ConfigSecrets(FakeCipher());
      final plain = _settingsJson();

      final onDisk = secrets.sealForDisk(plain);

      for (final key in AppSettings.secretJsonKeys) {
        expect(ConfigSecrets.isSealed(onDisk[key]), isTrue, reason: key);
      }
      final encoded = json.encode(onDisk);
      expect(encoded, isNot(contains(_account)));
      expect(encoded, isNot(contains(_browser)));
      for (final key in plain.keys.where((k) => !AppSettings.secretJsonKeys.contains(k))) {
        expect(onDisk[key], plain[key], reason: key);
      }
      expect(plain['twitch_oauth_token'], _account,
          reason: 'the caller\'s map is not modified');
    });

    test('round-trips through disk back to the same settings', () {
      final onDisk = ConfigSecrets(FakeCipher()).sealForDisk(_settingsJson());
      final read = Map<String, dynamic>.from(onDisk);

      // A fresh instance, as on the next launch.
      final rewrite = ConfigSecrets(FakeCipher()).openFromDisk(read);

      expect(rewrite, isNull, reason: 'already sealed: nothing to migrate');
      final settings = AppSettings.fromJson(read);
      expect(settings.twitchOauthToken, _account);
      expect(settings.twitchWebOauthToken, _browser);
    });

    test('keeps an oauth: prefix and non-ASCII text exactly', () {
      const odd = 'oauth:tökén ✓';
      final onDisk = ConfigSecrets(FakeCipher())
          .sealForDisk(_settingsJson(account: odd));
      final read = Map<String, dynamic>.from(onDisk);
      ConfigSecrets(FakeCipher()).openFromDisk(read);
      expect(read['twitch_oauth_token'], odd);
    });

    test('a plaintext config from an older build is offered for migration', () {
      final legacy = _settingsJson();

      final rewrite = ConfigSecrets(FakeCipher()).openFromDisk(legacy);

      expect(legacy['twitch_oauth_token'], _account,
          reason: 'the app keeps running on the plaintext it read');
      expect(rewrite, isNotNull);
      for (final key in AppSettings.secretJsonKeys) {
        expect(ConfigSecrets.isSealed(rewrite![key]), isTrue, reason: key);
      }
      expect(json.encode(rewrite), isNot(contains(_account)));
    });

    test('empty tokens stay empty and need no migration', () {
      final secrets = ConfigSecrets(FakeCipher());
      final none = _settingsJson(account: '', browser: '');

      expect(secrets.openFromDisk(Map.of(none)), isNull);
      final onDisk = secrets.sealForDisk(none);
      expect(onDisk['twitch_oauth_token'], '');
      expect(onDisk['twitch_web_oauth_token'], '');
    });

    test('without a cipher, tokens are stored as typed, as before', () {
      final secrets = ConfigSecrets(null);
      final plain = _settingsJson();

      expect(secrets.sealForDisk(plain)['twitch_oauth_token'], _account);
      expect(secrets.openFromDisk(Map.of(plain)), isNull);
    });

    test('an unchanged token is not re-sealed on every save', () {
      // DPAPI output is salted: re-sealing per autosave would rewrite the
      // stored value every two seconds of playback for nothing.
      final cipher = FakeCipher();
      final secrets = ConfigSecrets(cipher);

      final first = secrets.sealForDisk(_settingsJson());
      final second = secrets.sealForDisk(_settingsJson());

      expect(second, first);
      expect(cipher.seals, 2, reason: 'once per token, not once per save');

      final changed = secrets.sealForDisk(_settingsJson(account: 'new-token'));
      expect(changed['twitch_oauth_token'], isNot(first['twitch_oauth_token']));
      expect(changed['twitch_web_oauth_token'], first['twitch_web_oauth_token']);
    });

    test('a token opened from disk is saved back as the same sealed value', () {
      final stored = ConfigSecrets(FakeCipher()).sealForDisk(_settingsJson());
      final cipher = FakeCipher();
      final secrets = ConfigSecrets(cipher);
      final read = Map<String, dynamic>.from(stored);
      secrets.openFromDisk(read);

      final saved = secrets.sealForDisk(read);

      expect(saved['twitch_oauth_token'], stored['twitch_oauth_token']);
      expect(cipher.seals, 0);
    });

    group('a token this account cannot open', () {
      Map<String, dynamic> sealedElsewhere() =>
          ConfigSecrets(FakeCipher(account: 0x11)).sealForDisk(_settingsJson());

      test('runs as not connected, but is kept in the file', () {
        // A config moved from another account or machine, or a portable
        // install carried between PCs: showing "not connected" here must not
        // destroy the token for the place it does open.
        final stored = sealedElsewhere();
        final secrets = ConfigSecrets(FakeCipher());
        final read = Map<String, dynamic>.from(stored);

        expect(secrets.openFromDisk(read), isNull);
        expect(read['twitch_oauth_token'], '');
        expect(read['twitch_web_oauth_token'], '');

        final saved = secrets.sealForDisk(AppSettings.fromJson(read).toJson());
        expect(saved['twitch_oauth_token'], stored['twitch_oauth_token']);
        expect(saved['twitch_web_oauth_token'], stored['twitch_web_oauth_token']);

        // And it still opens where it was sealed.
        final back = Map<String, dynamic>.from(saved);
        ConfigSecrets(FakeCipher(account: 0x11)).openFromDisk(back);
        expect(back['twitch_oauth_token'], _account);
      });

      test('is replaced once a new token is entered, and not resurrected', () {
        final secrets = ConfigSecrets(FakeCipher());
        secrets.openFromDisk(Map<String, dynamic>.from(sealedElsewhere()));

        final replaced = Map<String, dynamic>.from(
            secrets.sealForDisk(_settingsJson(account: 'fresh', browser: '')));
        final cleared = secrets.sealForDisk(_settingsJson(account: '', browser: ''));

        ConfigSecrets(FakeCipher()).openFromDisk(replaced);
        expect(replaced['twitch_oauth_token'], 'fresh');
        expect(cleared['twitch_oauth_token'], '',
            reason: 'disconnecting after replacing it must really clear it');
        expect(ConfigSecrets.isSealed(cleared['twitch_web_oauth_token']), isTrue,
            reason: 'the browser token was never replaced, so it is still kept');
      });

      test('damaged sealed text is treated the same way', () {
        final secrets = ConfigSecrets(FakeCipher());
        final read = _settingsJson()
          ..['twitch_oauth_token'] = '${ConfigSecrets.sealedPrefix}%%%not base64%%%';

        expect(() => secrets.openFromDisk(read), returnsNormally);
        expect(read['twitch_oauth_token'], '');
      });
    });

    test('a token that cannot be sealed is saved in plaintext, then retried', () {
      // Dropping it would lose the account on the next launch; plaintext is
      // what every earlier build stored anyway.
      final refusing = ConfigSecrets(FakeCipher(refuseToSeal: true));
      expect(refusing.sealForDisk(_settingsJson())['twitch_oauth_token'], _account);

      final cipher = FakeCipher(refuseToSeal: true);
      final secrets = ConfigSecrets(cipher);
      secrets.sealForDisk(_settingsJson());
      secrets.sealForDisk(_settingsJson());
      expect(cipher.seals, 4, reason: 'a failure is not cached');
    });

    test('an older build reading a sealed config neither crashes nor loses the token', () {
      // Older builds know nothing of sealing: AppSettings.fromJson reads the
      // sealed string as an opaque token and toJson writes it back verbatim.
      // That is why the sealed value lives in the same key - a new key would
      // be deleted by the older build's first save.
      final written = ConfigSecrets(FakeCipher()).sealForDisk(_settingsJson());

      late AppSettings olderBuild;
      expect(() => olderBuild = AppSettings.fromJson(written), returnsNormally);
      expect(olderBuild.twitchOauthToken, written['twitch_oauth_token']);
      final rewrittenByOlderBuild = olderBuild.toJson();

      final read = Map<String, dynamic>.from(rewrittenByOlderBuild);
      ConfigSecrets(FakeCipher()).openFromDisk(read);
      expect(read['twitch_oauth_token'], _account);
      expect(read['twitch_web_oauth_token'], _browser);
    });
  });

  group('ConfigSecrets.sealTokensInText, for quarantined copies', () {
    /// What [sealed] holds, opened the way the next load would.
    String open(String sealed) {
      final settings = {'twitch_oauth_token': sealed};
      ConfigSecrets(FakeCipher()).openFromDisk(settings);
      return settings['twitch_oauth_token']!;
    }

    final sealedValue = RegExp('${RegExp.escape(ConfigSecrets.sealedPrefix)}[A-Za-z0-9+/=]+');

    test('seals both tokens and changes nothing else in the text', () {
      // Unparseable, as every quarantined copy is.
      final text = '{"channels":[{"username":"alpha"}],"settings":{'
          '"twitch_oauth_token": "$_account","default_quality":"best",'
          '"twitch_web_oauth_token":"$_browser", oops';

      final sealed = ConfigSecrets(FakeCipher()).sealTokensInText(text)!;

      expect(sealed, isNot(contains(_account)));
      expect(sealed, isNot(contains(_browser)));
      final values = sealedValue.allMatches(sealed).map((m) => m[0]!).toList();
      expect(values.map(open), [_account, _browser]);
      expect(sealed.replaceAll(values[0], _account).replaceAll(values[1], _browser),
          text);
    });

    test('a token the damage cut off is sealed as far as it goes', () {
      final text = '{"settings":{"twitch_web_oauth_token":"${_browser.substring(0, 9)}';

      final sealed = ConfigSecrets(FakeCipher()).sealTokensInText(text)!;

      expect(sealed, startsWith('{"settings":{"twitch_web_oauth_token":"dpapi:v1:'));
      expect(open(sealedValue.firstMatch(sealed)![0]!), _browser.substring(0, 9));
    });

    test('an escaped token is sealed as the text it stands for', () {
      final sealed = ConfigSecrets(FakeCipher())
          .sealTokensInText(r'{"twitch_oauth_token":"oauth:a\/bc"}')!;
      expect(open(sealedValue.firstMatch(sealed)![0]!), 'oauth:a/bc');
    });

    test('leaves alone what needs no sealing, or cannot be sealed', () {
      final alreadySealed = json.encode({
        'settings': ConfigSecrets(FakeCipher()).sealForDisk(_settingsJson()),
      });
      for (final text in [
        alreadySealed,
        '{"twitch_oauth_token":"","twitch_web_oauth_token":""}',
        '{"default_quality":"$_account"}',
        '',
      ]) {
        expect(ConfigSecrets(FakeCipher()).sealTokensInText(text), isNull,
            reason: text);
      }
      final plaintext = '{"twitch_oauth_token":"$_account"}';
      expect(ConfigSecrets(null).sealTokensInText(plaintext), isNull);
      expect(ConfigSecrets(FakeCipher(refuseToSeal: true)).sealTokensInText(plaintext),
          isNull);
    });
  });

  group('ConfigSecrets.blankTokensInText, for the mirror beside the exe', () {
    test('empties both tokens, sealed or not, and changes nothing else', () {
      final sealed = ConfigSecrets(FakeCipher()).sealText(_browser)!;
      final text = '{"channels":[{"username":"alpha"}],"settings":{'
          '"twitch_oauth_token": "$_account","default_quality":"best",'
          '"twitch_web_oauth_token":"$sealed"}}';

      expect(
          ConfigSecrets.blankTokensInText(text),
          '{"channels":[{"username":"alpha"}],"settings":{'
          '"twitch_oauth_token": "","default_quality":"best",'
          '"twitch_web_oauth_token":""}}');
    });

    test('an escaped token goes whole, and a cut-off one as far as it goes', () {
      expect(ConfigSecrets.blankTokensInText(r'{"twitch_oauth_token":"oauth:a\"b\/c","x":1}'),
          '{"twitch_oauth_token":"","x":1}');
      expect(
          ConfigSecrets.blankTokensInText(
              '{"settings":{"twitch_web_oauth_token":"${_browser.substring(0, 9)}'),
          '{"settings":{"twitch_web_oauth_token":"');
      expect(ConfigSecrets.blankTokensInText(r'{"twitch_oauth_token":"abc\'),
          '{"twitch_oauth_token":"');
    });

    test('null when there is no token to blank', () {
      for (final text in [
        '{"twitch_oauth_token":"","twitch_web_oauth_token":""}',
        '{"default_quality":"$_account"}',
        '{"twitch_oauth_token":null}',
        '',
      ]) {
        expect(ConfigSecrets.blankTokensInText(text), isNull, reason: text);
      }
    });
  });

  group('StorageService.platformCipher', () {
    test('seals with DPAPI only on Windows, outside the test runner', () {
      expect(StorageService.platformCipher(isWindows: true, isTestRunner: false),
          isA<DpapiSecretCipher>());
      expect(StorageService.platformCipher(isWindows: true, isTestRunner: true), isNull);
      expect(StorageService.platformCipher(isWindows: false, isTestRunner: false), isNull);
    });
  });

  group('Dpapi', () {
    final skip = Platform.isWindows ? false : 'DPAPI exists only on Windows';
    final secret = Uint8List.fromList(utf8.encode(_browser));
    final entropy = Uint8List.fromList(utf8.encode('test-entropy'));

    test('is available on Windows', () {
      expect(Dpapi.isAvailable, isTrue);
    }, skip: skip);

    test('round-trips, and the sealed bytes do not contain the secret', () {
      final sealed = Dpapi.protect(secret, entropy: entropy);

      expect(sealed, isNotNull);
      expect(latin1.decode(sealed!, allowInvalid: true), isNot(contains(_browser)));
      expect(Dpapi.unprotect(sealed, entropy: entropy), secret);
    }, skip: skip);

    test('refuses the wrong entropy and damaged bytes without throwing', () {
      final sealed = Dpapi.protect(secret, entropy: entropy)!;
      expect(Dpapi.unprotect(sealed, entropy: Uint8List.fromList([1, 2, 3])), isNull);
      expect(Dpapi.unprotect(sealed), isNull);

      final damaged = Uint8List.fromList(sealed)..[sealed.length ~/ 2] ^= 0xFF;
      expect(Dpapi.unprotect(damaged, entropy: entropy), isNull);
      expect(Dpapi.unprotect(Uint8List.fromList([1, 2, 3])), isNull);
    }, skip: skip);

    test('through StorageService: the file holds no token, the app reads it back', () async {
      final dir = Directory.systemTemp.createTempSync('streamlink_gui_dpapi_test_');
      StorageService.storageDirectoryOverride = dir.path;
      StorageService.secretCipher = const DpapiSecretCipher();
      addTearDown(() {
        StorageService.storageDirectoryOverride = null;
        StorageService.secretCipher = null;
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final storage = StorageService();
      await storage.saveConfig(
        const [],
        AppSettings(twitchOauthToken: _account, twitchWebOauthToken: _browser),
        <String, int>{},
        <String, String>{},
      );

      final raw = File('${dir.path}${Platform.pathSeparator}channels_config.json')
          .readAsStringSync();
      expect(raw, isNot(contains(_account)));
      expect(raw, isNot(contains(_browser)));
      expect(raw, contains(ConfigSecrets.sealedPrefix));

      // A fresh start: nothing remembered from the save above.
      StorageService.secretCipher = const DpapiSecretCipher();
      final loaded = await storage.loadConfig();
      final settings = AppSettings.fromJson(loaded!['settings']);
      expect(settings.twitchOauthToken, _account);
      expect(settings.twitchWebOauthToken, _browser);
    }, skip: skip);
  });
}
