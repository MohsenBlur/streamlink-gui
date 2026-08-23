import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A source-level guard against the duplication this refresh removed growing
/// back. Every primitive below was, at the start of the work, hand-rolled at
/// several call sites with slightly different numbers at each one; the point of
/// extracting them is lost the moment someone adds an eleventh spelling.
///
/// Crude on purpose - it is a grep, not an analyzer plugin - but it is the only
/// thing that makes the canonicalisation stick.
///
/// To exempt a genuinely special case, put `// raw-ok:` with a reason on the
/// same line. That mirrors the `// Intentional:` convention already used for
/// the accent swatches and the rainbow border.
void main() {
  final libDir = Directory('lib');

  /// Files that legitimately contain the raw primitive: the primitive's own
  /// implementation, plus surfaces not yet migrated.
  const allowedFiles = <String, String>{
    // The primitives themselves.
    'lib/widgets/neumorphic/neu_progress.dart': 'defines the progress widgets',
    'lib/widgets/neumorphic/neu_text_field.dart': 'defines the field',

    // Form inputs rather than search fields, in a dialog that a later phase
    // restructures wholesale. Converting them now would collide with that.
    'lib/widgets/settings_dialog.dart': 'settings forms, pending the IA rework',
    'lib/widgets/onboarding_wizard.dart': 'onboarding form, pending the IA rework',
  };

  Iterable<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  String rel(File f) => f.path.replaceAll(r'\', '/');

  void expectNoRaw(String pattern, String replacement) {
    final offenders = <String>[];
    for (final file in dartFiles()) {
      final path = rel(file);
      if (allowedFiles.containsKey(path)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Word boundary: `NeuTextField(` must not match `TextField(`.
        final at = line.indexOf(pattern);
        if (at < 0) continue;
        if (at > 0 && RegExp(r'[A-Za-z0-9_]').hasMatch(line[at - 1])) continue;
        if (line.contains('raw-ok:')) continue;
        // A reference in a comment is not a use.
        if (line.trimLeft().startsWith('//')) continue;
        offenders.add('$path:${i + 1}  ${line.trim()}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'use $replacement instead of $pattern:\n'
            '${offenders.join('\n')}');
  }

  test('no hand-rolled linear progress bars', () {
    // Four sites rendered this with heights 2, 3, 3 and the default, two of
    // them rounded and two not.
    expectNoRaw('LinearProgressIndicator(', 'NeuProgressBar');
  });

  test('no hand-rolled circular progress rings', () {
    // Strokes of 1.5, 1.8, 2 and 2 across the app.
    expectNoRaw('CircularProgressIndicator(', 'NeuProgressRing');
  });

  test('no raw Material text fields', () {
    // The same search field existed at 130x28/font 11, at height 36/font 12,
    // capped at 280, and at height 44/font 14.
    expectNoRaw('TextField(', 'NeuTextField');
  });

  test('the allow-list only names files that exist', () {
    // An allow-list entry for a deleted or renamed file silently stops
    // guarding whatever replaced it.
    for (final path in allowedFiles.keys) {
      expect(File(path).existsSync(), isTrue,
          reason: '$path is allow-listed but does not exist');
    }
  });
}
