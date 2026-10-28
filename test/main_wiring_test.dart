import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins how main.dart wires the pieces whose rules are tested elsewhere.
///
/// A source scan, like external_link_test, because no test pumps MainScreen:
/// it would need window_manager, the tray, notifications and storage faked.
/// Each rule below is a call the screen makes or no longer makes, so it
/// reads the method it belongs to, and fails if that call goes back to how
/// it was.
void main() {
  // Line endings as git stores them, whatever the checkout turned them into.
  final src =
      File('lib/main.dart').readAsStringSync().replaceAll('\r\n', '\n');

  /// From [open] (an opening bracket) to the bracket that closes it.
  String bracketed(int open, String opening, String closing) {
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      final c = src[i];
      if (c == opening) depth++;
      if (c == closing && --depth == 0) return src.substring(open, i + 1);
    }
    fail('unbalanced $opening$closing at $open');
  }

  /// The body of the first declaration starting with [signature]: past its
  /// parameter list (named parameters have braces too), the block after it.
  String bodyOf(String signature) {
    final at = src.indexOf(signature);
    expect(at, isNonNegative, reason: '$signature is gone from main.dart');
    final params = src.indexOf('(', at);
    final end = params + bracketed(params, '(', ')').length;
    return bracketed(src.indexOf('{', end), '{', '}');
  }

  test('frequent saves go through the debounced, config-only write', () {
    // Every VOD fetch and every window move wrote the config and the
    // progress sidecar at once, each fsync'd.
    for (final method in [
      'Future<void> _applyVodOutcome(',
      'void _saveWindowState(',
    ]) {
      final body = bodyOf(method);
      expect(body, contains('_settingsRepo.requestSave()'), reason: method);
      expect(body, isNot(contains('_saveChannels()')), reason: method);
    }
  });

  test('a VOD auto-download announces is left out of the New VOD toast', () {
    expect(bodyOf('void _onNewVods('),
        contains('_automation.newVodsToAnnounce('));
  });
}
