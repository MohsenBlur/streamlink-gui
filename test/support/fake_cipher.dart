import 'dart:typed_data';

import 'package:streamlink_gui/services/config_secrets.dart';

/// A reversible stand-in for DPAPI that runs on every platform, CI's ubuntu
/// included.
///
/// The first byte names the "account" that sealed the blob; a cipher with a
/// different [account] cannot open it, the way DPAPI cannot open a config
/// moved to another Windows account or machine.
class FakeCipher implements SecretCipher {
  FakeCipher({this.account = 0x5A, this.refuseToSeal = false});

  final int account;
  final bool refuseToSeal;
  int seals = 0;

  @override
  Uint8List? seal(Uint8List plain) {
    seals++;
    if (refuseToSeal) return null;
    return Uint8List.fromList([account, for (final b in plain) b ^ account]);
  }

  @override
  Uint8List? open(Uint8List sealed) {
    if (sealed.isEmpty || sealed.first != account) return null;
    return Uint8List.fromList([for (final b in sealed.skip(1)) b ^ account]);
  }
}
