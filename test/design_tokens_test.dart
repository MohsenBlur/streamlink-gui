import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Geometry comes from the scales, not from whatever number was typed.
///
/// Before this refresh the app used fifteen distinct `EdgeInsets` values and
/// eleven distinct corner radii, and the component defaults disagreed with
/// each other - NeuContainer 16, NeuButton 20, NeuCard 20, NeuTextField 22,
/// NeuFocusable 12. Extracting NeuSpace and NeuRadius is only worth anything
/// for as long as nothing goes around them.
///
/// Deliberate exceptions carry `// Intentional:` with a reason, on the line
/// itself or in the comment block directly above it. That is the convention
/// already used for the accent swatches and the rainbow border.
void main() {
  Iterable<File> dartFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      // The scales' own definitions, and the theme that re-exports them.
      .where((f) => !f.path.replaceAll(r'\', '/').startsWith('lib/theme/'));

  String rel(File f) => f.path.replaceAll(r'\', '/');

  /// Lines matching [pattern], minus anything marked intentional.
  List<String> offenders(RegExp pattern) {
    final found = <String>[];
    for (final file in dartFiles()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        // A token reference contains digits too - NeuSpace.s12 - so scrub the
        // tokens before looking for bare numbers.
        final line = lines[i]
            .replaceAll(
                RegExp(r'Neu(Space\.s|Radius\.r|Elevation\.d)[0-9]+'), 'TOKEN')
            // Zero is zero on any scale.
            .replaceAll(RegExp(r'(?<![\w.])0(\.0)?(?![\w.])'), 'ZERO');
        if (!pattern.hasMatch(line)) continue;
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('Intentional:') || line.contains('raw-ok:')) continue;
        final above = lines
            .sublist(i >= 4 ? i - 4 : 0, i)
            .where((l) => l.trimLeft().startsWith('//'))
            .join(' ');
        if (above.contains('Intentional:')) continue;
        found.add('${rel(file)}:${i + 1}  ${lines[i].trim()}');
      }
    }
    return found;
  }

  test('corner radii come from NeuRadius', () {
    // 8 appeared 26 times, 16 twenty-one, 6 fourteen, 4 ten, plus one-off 22,
    // 20, 18, 11, 10 and 2 - and 11 inside a 12px card with 2px of padding
    // left a visible crescent in each corner, which is exactly the sort of
    // thing a concentric rule catches and eyeballing does not.
    final found = offenders(RegExp(r'BorderRadius\.circular\(\s*[0-9]'));
    expect(found, isEmpty,
        reason: 'use NeuRadius.r4/r8/r12/... or NeuRadius.inner(outer, inset):'
            '\n${found.join('\n')}');
  });

  test('decoration radii come from NeuRadius too', () {
    // NeuAvatar's `radius:` is a circle radius, not a corner radius - a
    // different quantity that happens to share a name - so this looks only at
    // the decoration helpers.
    final found = offenders(
        RegExp(r'(raised|sunken)Decoration\([^)]*radius:\s*[0-9]'));
    expect(found, isEmpty,
        reason: 'pass a NeuRadius step:\n${found.join('\n')}');
  });

  test('spacers come from NeuSpace', () {
    // 274 SizedBox spacers across fifteen values. 4/6/8/12/16 already covered
    // about 70% of them, so most of this was ratification; the stragglers -
    // 10, 14, 18 - were never a decision, just whatever was typed.
    final found = offenders(RegExp(r'SizedBox\((width|height):\s*[0-9]'));
    expect(found, isEmpty,
        reason: 'use NeuSpace.s4/s8/s12/...:\n${found.join('\n')}');
  });

  test('padding comes from NeuSpace', () {
    final found = offenders(RegExp(
        r'EdgeInsets\.(all|symmetric|only|fromLTRB)\([^)]*[0-9]'));
    expect(found, isEmpty,
        reason: 'use NeuSpace steps:\n${found.join('\n')}');
  });

  test('every NeuSpace and NeuRadius step is actually reachable', () {
    // A scale nobody can reach without editing an import is a scale nobody
    // uses, which is why both are re-exported from neu_theme.dart - the one
    // theme file that ~30 files already import.
    final theme = File('lib/theme/neu_theme.dart').readAsStringSync();
    expect(theme, contains("export 'neu_tokens.dart';"));
    expect(theme, contains("export 'neu_type.dart';"));
  });
}
