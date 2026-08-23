import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every dialog goes through one shell.
///
/// The app had 17 dialogs and no shared shell: three different accessors for
/// the same intended background colour, borders on 2 of 17 disagreeing on
/// alpha, four header arrangements, and six different words for "dismiss".
/// Nothing structural stopped the eighteenth from being hand-rolled too, so
/// this test is that thing.
///
/// Source-level rather than behavioural: most of these dialogs are static
/// `show` methods needing a live `_MainScreenState`, and the property being
/// checked - "was the shell used at all" - is a property of the source.
void main() {
  final shell = File('lib/widgets/shell/neu_dialog.dart').path;
  final dartFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.endsWith('neu_dialog.dart'))
      .toList();

  test('nothing calls showDialog or AlertDialog outside the shell', () {
    final offenders = <String>[];
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      for (final needle in ['showDialog(', 'showDialog<', 'AlertDialog(']) {
        if (source.contains(needle)) {
          offenders.add('${file.path}: $needle');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'use NeuDialog.show / NeuDialog instead. Offenders:\n'
            '${offenders.join('\n')}\nShell lives at $shell');
  });

  test('every NeuDialog.show states its dismissibility', () {
    // `dismissible` is a required parameter with no default, so this cannot
    // fail while the code compiles - it is here to fail loudly if someone
    // gives it a default to save typing. Whether a click on the scrim can
    // discard staged edits or abandon a running update is a real decision.
    final source = File('lib/widgets/shell/neu_dialog.dart').readAsStringSync();
    expect(source, contains('required bool dismissible'));
    expect(source, isNot(contains('bool dismissible = ')));
  });

  test('the update-in-progress dialog cannot be dismissed', () {
    // The one dialog where dismissal is actively dangerous: the binaries are
    // being replaced underneath the running process. It also carries no
    // actions, so there is no way out of it by any route until it resolves.
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('void _performAppUpdate(');
    expect(start, greaterThan(0));
    final body = source.substring(start, source.indexOf('Future.microtask', start));
    expect(body, contains('dismissible: false'));
    expect(body, isNot(contains('actions:')));
  });

  test('dialogs that stage edits are not dismissible', () {
    // Settings and onboarding both hold a form's worth of unsaved state, and
    // Settings additionally applies theme changes live - dismissing it by
    // clicking away would leave the previewed accent applied while discarding
    // everything typed.
    for (final path in const [
      'lib/widgets/settings_dialog.dart',
      'lib/widgets/onboarding_wizard.dart',
    ]) {
      final source = File(path).readAsStringSync();
      final show = source.indexOf('NeuDialog.show');
      expect(show, greaterThan(0), reason: '$path does not use NeuDialog.show');
      expect(source.substring(show, show + 200), contains('dismissible: false'),
          reason: '$path stages edits and must not be scrim-dismissible');
    }
  });
}
