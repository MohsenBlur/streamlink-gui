import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A widget that reads the theme global must never be built `const`.
///
/// ## The bug this exists for
///
/// Const expressions are canonicalised, so the "new" widget a parent hands
/// down on rebuild is the *same instance* as the old one. `Element.updateChild`
/// short-circuits on `child.widget == newWidget` and returns the existing
/// element without calling `update` — the subtree is skipped entirely. A
/// widget that reads `themeNotifier` inside `build` therefore keeps whatever
/// theme it was first built with, forever.
///
/// That is not hypothetical. `themeNotifier.isDarkTheme` starts `true` and is
/// corrected from the config asynchronously, after the first frame. So on a
/// light-theme install, `const SectionHeader(title: 'Quick actions')` rendered
/// its heading in the DARK theme's near-white ink on a champagne ground and
/// stayed there, while `SectionHeader(title: 'Live now')` two hundred lines
/// away — written without `const` — was correct. Six call sites across two
/// widgets, shipped, and invisible for as long as the app only had one
/// material to render them on.
///
/// ## Why a source test rather than a lint
///
/// `prefer_const_constructors` pushes in exactly the wrong direction here: it
/// asks for `const` on any constructor that can take it, which for these
/// widgets is precisely the defect. The two widgets that were actually being
/// const-called had `const` removed from their constructors, so the compiler
/// enforces it for them. This covers the rest — thirty-six more classes where
/// nothing today writes `const`, and nothing stops tomorrow.
///
/// ## The real fix, and why this is not it
///
/// These widgets should read an `InheritedWidget` — `Theme.of(context)` or an
/// equivalent — so Flutter's own dependency tracking forces the rebuild and
/// `const` becomes harmless again. That is a large refactor across the whole
/// widget layer. Until it happens, this is the guard that keeps the class of
/// bug from spreading.
void main() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  String rel(File f) => f.path.replaceAll(r'\', '/');

  /// Widget classes whose build path touches the theme global.
  Set<String> themeReadingWidgets() {
    final found = <String>{};
    final classHead =
        RegExp(r'class (\w+) extends (StatelessWidget|StatefulWidget)');
    for (final file in files) {
      final src = file.readAsStringSync();
      for (final m in classHead.allMatches(src)) {
        final name = m.group(1)!;
        final next = src.indexOf('\nclass ', m.start + 1);
        var body = src.substring(m.start, next > 0 ? next : src.length);

        // A StatefulWidget's build lives in its State, which is a separate
        // class. Missing that would exempt most of the widget layer.
        if (m.group(2) == 'StatefulWidget') {
          final state =
              RegExp('class _?${name}State extends State<$name>').firstMatch(src);
          if (state != null) {
            final n2 = src.indexOf('\nclass ', state.start + 1);
            body += src.substring(state.start, n2 > 0 ? n2 : src.length);
          }
        }
        if (body.contains('themeNotifier')) found.add(name);
      }
    }
    return found;
  }

  test('no widget that reads the theme global is constructed const', () {
    final widgets = themeReadingWidgets();
    expect(widgets, isNotEmpty,
        reason: 'the scan found no theme-reading widgets at all, which means '
            'it has stopped matching the codebase rather than that the '
            'codebase is clean');

    final pattern = RegExp(r'\bconst\s+(' + widgets.join('|') + r')\s*\(');
    final offenders = <String>[];
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        for (final m in pattern.allMatches(line)) {
          // The constructor's own declaration, not a call site. `const Foo({`
          // inside class Foo is what makes const *possible*; it is only a bug
          // where someone actually uses it.
          final after = line.substring(m.end).trimLeft();
          if (after.startsWith('{') || after.startsWith('Key? key') ||
              after.startsWith('super.key') ||
              after.startsWith('required this.') ||
              after.startsWith('this.')) {
            continue;
          }
          offenders.add('${rel(file)}:${i + 1}  ${line.trim()}');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'a const widget that reads themeNotifier never rebuilds when '
            'the theme or material changes — Element.updateChild skips it. '
            'Drop the const:\n${offenders.join('\n')}');
  });

  test('the net would actually catch one', () {
    // A guard that cannot fire is decoration, and this one is a regex over
    // source text with an exemption for constructor declarations - exactly the
    // shape that quietly stops matching. Fed the line that shipped, it has to
    // flag it; fed the declaration that makes const possible, it must not.
    final widgets = themeReadingWidgets();
    expect(widgets, contains('SectionHeader'));
    final pattern = RegExp(r'\bconst\s+(' + widgets.join('|') + r')\s*\(');

    const shipped = "          const SectionHeader(title: 'Quick actions'),";
    expect(pattern.hasMatch(shipped), isTrue,
        reason: 'the pattern no longer matches the line that caused the bug');

    const declaration = '  const SectionHeader({';
    final m = pattern.firstMatch(declaration);
    expect(m, isNotNull);
    expect(declaration.substring(m!.end).trimLeft().startsWith('{'), isTrue,
        reason: 'the declaration exemption must still recognise a declaration, '
            'or every widget in the app reports as an offender');
  });

  test('the two widgets that were actually bitten cannot be const at all', () {
    // Belt as well as braces, and it is the compiler doing the work: with a
    // non-const constructor, `const SectionHeader(...)` will not compile. The
    // grep above is the general net; these two are the ones that were caught
    // in it, so they get the stronger guarantee.
    for (final path in const [
      'lib/widgets/shell/section_header.dart',
      'lib/widgets/shell/empty_state.dart',
    ]) {
      final src = File(path).readAsStringSync();
      final name = path.contains('section') ? 'SectionHeader' : 'EmptyState';
      expect(src.contains('const $name('), isFalse,
          reason: '$name declared a const constructor again — that is what '
              'allowed six call sites to freeze at the startup theme');
    }
  });
}
