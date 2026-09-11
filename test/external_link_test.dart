import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the quoting of URLs handed to `explorer.exe`.
///
/// A source scan because the behaviour lives in a `Process.start` against a
/// Windows shell component, which a unit test cannot exercise. It is here
/// because the fix is a single trailing space inside a string literal — it
/// reads exactly like a typo, and deleting it silently breaks every external
/// link that has a query string.
///
/// What it broke: `explorer.exe` does not use standard argv parsing, so a bare
/// URL containing `&` gets split and a fragment is handed to the shell. The
/// Twitch sign-in URL ends in `scope=user:read:follows`, so Windows was asked
/// to open a `user:` protocol and offered the Microsoft Store instead of a
/// browser. Verified against a local listener: unquoted delivers nothing,
/// quoted delivers the full query string.
void main() {
  test('the URL handed to explorer is quoted, via the trailing space', () {
    final src = File('lib/main.dart').readAsStringSync();

    expect(
      src.contains(r"Process.start('explorer.exe', ['$url ']"),
      isTrue,
      reason: 'the trailing space inside the argument is what forces Dart to '
          'quote it; without the quotes explorer splits the URL on & and the '
          'sign-in link opens the Microsoft Store',
    );

    expect(
      src.contains(r"Process.start('explorer.exe', [url]"),
      isFalse,
      reason: 'the unquoted form is the bug',
    );
  });

  test('the reason is recorded next to the code', () {
    // A bare space is invisible in review; the comment is the only thing
    // standing between it and a well-meaning cleanup.
    final src = File('lib/main.dart').readAsStringSync();
    expect(src, contains('TRAILING SPACE IS LOAD-BEARING'));
  });
}
