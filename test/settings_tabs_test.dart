import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The settings dialog is a 1400-line builder behind a static `show`, so it is
/// not practical to pump. These assert its STRUCTURE at the source level,
/// which is where the real risk lives: the tab labels and the TabBarView
/// children are two separate lists, and nothing except their order connects
/// them. Getting that wrong puts the wrong panel behind the right label -
/// which compiles, renders, and looks almost right.
///
/// Source-level rather than behavioural, and deliberately so: a screenshot
/// cannot check this either, because the capture harness can only deliver one
/// synthetic click per app launch and switching tabs needs two.
void main() {
  final lines =
      File('lib/widgets/settings_dialog.dart').readAsLinesSync();

  List<String> tabLabels() {
    final re = RegExp(r"Tab\(text: '([^']+)'\)");
    return [
      for (final line in lines)
        if (re.firstMatch(line) case final m?) m.group(1)!,
    ];
  }

  /// The direct children of the TabBarView, keyed by their marker comment.
  ///
  /// A panel starts at its `// PANEL n: ...` comment - indented to the depth
  /// of the children list itself - and runs to the next one.
  Map<String, List<String>> panelSpans() {
    const panelIndent = 22;
    const listIndent = 20;
    final spans = <String, List<String>>{};
    var inTabBarView = false;
    String? current;
    for (final line in lines) {
      if (line.contains('TabBarView(')) inTabBarView = true;
      if (!inTabBarView) continue;
      final trimmed = line.trim();
      final indent = line.length - line.trimLeft().length;
      if (trimmed == '],' && indent == listIndent) break;
      if (trimmed.startsWith('// ') && indent == panelIndent) {
        current = trimmed.substring(3);
        spans[current] = <String>[];
        continue;
      }
      if (current != null) spans[current]!.add(line);
    }
    return spans;
  }

  test('there is one panel per tab label', () {
    // If these ever disagree, TabBarView either throws or silently pairs the
    // wrong panel with a label.
    expect(panelSpans().length, tabLabels().length);
  });

  test('each panel is one balanced expression', () {
    // The marker comments are not evidence. A restructure once dropped the
    // last 62 lines of the Downloads panel; the comments still said five
    // panels and the analyzer still passed - the orphaned panels had simply
    // nested one level deeper inside the panel above, which is valid Dart and
    // a TabBarView with four children behind five tabs.
    //
    // So count brackets instead. Each panel must open and close exactly, and
    // must never dip below zero, which is what "one child of the children
    // list" actually means.
    final noise = RegExp("'[^']*'" r'|"[^"]*"|//.*$');
    panelSpans().forEach((panel, span) {
      var depth = 0;
      for (final line in span) {
        for (final ch in line.replaceAll(noise, '').split('')) {
          if (ch == '(' || ch == '[' || ch == '{') depth++;
          if (ch == ')' || ch == ']' || ch == '}') depth--;
        }
        expect(depth, greaterThanOrEqualTo(0),
            reason: '$panel closes more than it opens');
      }
      expect(depth, 0, reason: '$panel is not a self-contained child');
    });
  });

  test('the labels are the rebalanced set, in order', () {
    // General used to hold 17 controls in eight sub-sections while Styling
    // held three - and defaultQuality and twitchLowLatency, which are
    // streamlink flags, lived under General rather than with the player.
    expect(tabLabels(), [
      'Playback',
      'Downloads',
      'Appearance',
      'Twitch',
      'System',
    ]);
  });

  test('each panel holds the settings its label promises', () {
    // The pairing that actually matters, asserted by content rather than by
    // position: a heading unique to each panel must appear in that panel.
    final spans = panelSpans();
    final names = spans.keys.toList();

    String panelContaining(String needle) => spans.entries
        .firstWhere((e) => e.value.any((l) => l.contains(needle)),
            orElse: () => throw StateError('no panel contains "$needle"'))
        .key;

    // Playback owns the streamlink flags AND the player.
    final playback = names[0];
    expect(panelContaining("'Default Video Quality'"), playback);
    expect(panelContaining("'Low Latency Streams'"), playback);
    expect(panelContaining("'VOD Watched Threshold'"), playback);
    expect(panelContaining('Player Type'), playback);

    // System owns everything about the app rather than about playback.
    final system = names[4];
    expect(panelContaining("'Window & Tray'"), system);
    expect(panelContaining("'Notifications'"), system);
    expect(panelContaining("'Watch History'"), system);
    expect(panelContaining("'Diagnostics'"), system);

    expect(panelContaining("'VOD Download Directory'"), names[1]);
  });

  test('no panel is left empty', () {
    // The Styling tab held three controls against General's seventeen; an
    // empty panel would be the same failure taken to its limit.
    final control = RegExp(r'NeuSwitch|DropdownButton|Slider\(|TextField\('
        r'|OutlinedButton|ElevatedButton|GestureDetector');
    panelSpans().forEach((panel, span) {
      expect(span.where(control.hasMatch).length, greaterThan(0),
          reason: '$panel has no controls at all');
    });
  });
}
