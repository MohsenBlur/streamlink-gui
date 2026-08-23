import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/material/texture_cache.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/theme/theme_notifier.dart';

/// The material choice, and the four places it can be silently lost.
///
/// The settings dialog is a 1400-line builder behind a static `show`, so the
/// established convention in this suite is to assert its structure at the
/// source level and its behaviour everywhere else. The picker splits the same
/// way: what it *paints* is checkable through the theme API, what it *writes*
/// is checkable at the source, and the two together cover the failure the plan
/// singles out — a choice that appears to work and reverts on the next launch.
void main() {
  final settingsSource =
      File('lib/widgets/settings_dialog.dart').readAsStringSync();

  group('the preview tiles cannot all look the same', () {
    test('each material resolves to its own surfaces', () {
      // The bug this exists for is one missing argument. A tile that calls
      // `NeuTheme.panel(isDark)` instead of `NeuTheme.panel(isDark, material:
      // spec.id)` renders every entry in the picker identically — and looks
      // completely fine while only one material is registered, which is
      // exactly when someone would write it.
      for (final isDark in [false, true]) {
        final seen = <String>{};
        for (final spec in MaterialSpec.available) {
          final key = [
            NeuTheme.panel(isDark, material: spec.id),
            NeuTheme.raised(isDark, material: spec.id),
            NeuTheme.sunken(isDark, material: spec.id),
          ].map((d) => d.hashCode).join('/');
          expect(seen.add(key), isTrue,
              reason: '${spec.id.key} paints the same surfaces as another '
                  'material — the picker would show two identical tiles');
        }
      }
    });

    test('each material names itself', () {
      // The tiles are labelled from the spec, so an empty or duplicated name
      // makes two entries indistinguishable even when their surfaces differ.
      final names = <String>{};
      for (final spec in MaterialSpec.available) {
        expect(spec.name.trim(), isNotEmpty);
        expect(spec.blurb.trim(), isNotEmpty);
        expect(names.add(spec.name), isTrue,
            reason: 'two materials are called ${spec.name}');
      }
    });
  });

  group('switching material invalidates what it invalidates', () {
    tearDown(() => themeNotifier.setMaterial(AppMaterial.rack));

    test('the derived accent ink is recomputed against the new grounds', () {
      // `_invalidateDerivedColors` was reachable only from the theme and
      // accent setters. Without it here, the app serves the PREVIOUS
      // material's accent ink until something unrelated happens to change the
      // accent — which presents as a caching glitch rather than as a missing
      // call, and is very hard to trace back.
      themeNotifier.setMaterial(AppMaterial.rack);
      themeNotifier.setLightAccent(const Color(0xFF00F2FE));
      themeNotifier.setDarkTheme(false);
      final onRack = themeNotifier.accentInk;

      themeNotifier.setMaterial(AppMaterial.soft);
      final onSoft = themeNotifier.accentInk;

      expect(onSoft, NeuTheme.accentInk(themeNotifier.primaryColor, false),
          reason: 'the cached ink survived a material switch');
      // Rack light and Soft light have different worst grounds, so the derived
      // ink must actually differ — otherwise this test would pass on a stale
      // cache too.
      expect(onSoft, isNot(onRack),
          reason: 'these two materials happen to derive the same ink, so this '
              'guard is not proving anything — pick another pair');
    });

    testWidgets('a switch does not leave the previous material grain resident',
        (tester) async {
      // This used to compare 0 to 0. `residentCount` is zero before the switch
      // as well as after, because constructing a SkeuoDecoration never paints
      // and nothing here warmed a tile - so deleting `TextureCache.evictAll()`
      // from the setter left this test, and the whole suite, green.
      //
      // It has to be a testWidgets: `evictAll` defers its dispose to a
      // post-frame callback, so it reaches WidgetsBinding.instance the moment
      // there is actually something to evict, and a plain `test()` throws
      // "Binding has not yet been initialized" there.
      const key = TileKey(
          kind: TextureKind.brushed,
          width: 32,
          height: 32,
          amplitude: 3,
          seed: 11);

      await tester.runAsync(() async {
        var landed = false;
        TextureCache.request(key, () => landed = true);
        for (var i = 0; i < 40 && !landed; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });

      expect(TextureCache.residentCount, greaterThan(0),
          reason: 'precondition: a tile has to be resident for eviction to '
              'mean anything - without this the assertion below is 0 == 0');

      themeNotifier.setMaterial(AppMaterial.soft);
      await tester.pump();

      expect(TextureCache.residentCount, 0,
          reason: 'switching material left the previous grain resident. Tiles '
              'are keyed on kind/size/amplitude/seed and NOT on the material, '
              'so a material declaring no texture would keep painting the last '
              "one's");
    });

    test('setting the same material again is inert', () {
      // The setter is called on every config load. Notifying unconditionally
      // there would rebuild the whole app during startup for no change.
      themeNotifier.setMaterial(AppMaterial.rack);
      var notifications = 0;
      void listener() => notifications++;
      themeNotifier.addListener(listener);
      themeNotifier.setMaterial(AppMaterial.rack);
      themeNotifier.removeListener(listener);
      expect(notifications, 0);
    });
  });

  group('the choice has all three writers', () {
    // Persistence needs three, and missing any one produces the same symptom
    // from the user's side: the picker works, and the app forgets by morning.

    test('Save persists it, without clobbering an unresolvable key', () {
      // Two halves, and the second one is why this is not just
      // `contains('material:')`.
      //
      // Save has to write the user's choice. It also has to NOT write when the
      // user changed nothing, because `themeNotifier.material` is the RESOLVED
      // value and main.dart deliberately leaves it at the fallback for a key
      // this build cannot implement. Writing unconditionally turned "open
      // Settings, press Save" into "silently destroy the material a newer
      // build chose" - through a full no-merge config rewrite, with the picker
      // showing the fallback as selected so there was no cue.
      expect(settingsSource, contains('themeNotifier.material.key'),
          reason: "the Save button's copyWith does not carry the material, so "
              'the choice is lost the moment the dialog closes');
      expect(settingsSource, contains('themeNotifier.material == originalMaterial'),
          reason: 'Save writes the resolved material unconditionally, so it '
              'overwrites a stored key this build could not resolve');
    });

    test('every exit from the SETTINGS dialog either saves or restores', () {
      // The Appearance tab applies material, theme mode and both accents live
      // and unpersisted, so an exit that does neither leaves the session on
      // settings the config does not record - and the next launch silently
      // reverts, which reads as the app forgetting a choice.
      //
      // `NeuDialog.show(dismissible: false)` disables the scrim AND Escape, so
      // the exits are exactly the three below. A blanket scan for
      // `Navigator.pop` does not work here and was tried: this file also
      // builds several NESTED confirm dialogs whose own pops return to
      // settings rather than leaving it, and flagging those is noise.
      //
      // Named, therefore, and each one paired with what makes it safe.
      expect(settingsSource, contains('restoreLiveThemeEdits();'),
          reason: 'Cancel must put the live theme edits back');

      // Connect Account pops without saving, so it needs the restore too. It
      // was the only unguarded exit.
      // Comments stripped first. Searching raw source for "the next N
      // characters after onConnectAccount" is defeated by a long enough
      // explanatory comment sitting between the call and the restore - which
      // is exactly what happened when this was written.
      final code = settingsSource
          .split(String.fromCharCode(10))
          .where((l) => !l.trimLeft().startsWith('//'))
          .join(String.fromCharCode(10));
      final connect = code.indexOf('onConnectAccount();');
      expect(connect, greaterThan(-1));
      final afterConnect = code.substring(connect, connect + 300);
      expect(afterConnect, contains('restoreLiveThemeEdits()'),
          reason: 'Connect Account leaves the dialog without saving and '
              'without restoring, so the session keeps unpersisted theme '
              'edits that the next launch will silently revert');

      // And Save, which is safe because it persists rather than restores.
      expect(settingsSource, contains('onSave('),
          reason: 'the Save path must actually persist');
    });


    test('Cancel restores it', () {
      expect(settingsSource, contains('setMaterial(originalMaterial)'),
          reason: 'restoreLiveThemeEdits does not put the material back, so '
              'Cancel leaves the app wearing a material it never saved');
    });

    test('launch applies it', () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      expect(mainSource, contains('themeNotifier.setMaterial('),
          reason: 'nothing applies the stored material at startup, so a saved '
              'choice is written to disk and never read back');
      expect(mainSource, contains('AppMaterial.fromKey(_settings.material)'),
          reason: 'the stored key must be RESOLVED rather than assumed valid, '
              'so an unknown material from a newer build falls back for the '
              'session instead of throwing');
    });

    test('the picker is actually in the Appearance panel', () {
      // Ordering, not existence: the plan puts the material above theme mode
      // and accent because it is the outermost choice — the other two are
      // adjustments within it.
      final picker = settingsSource.indexOf('_MaterialPicker(');
      final themeMode = settingsSource.indexOf("Text('Application Theme Mode'");
      expect(picker, greaterThan(-1), reason: 'no picker in the dialog');
      expect(themeMode, greaterThan(-1));
      expect(picker, lessThan(themeMode),
          reason: 'the material is the outermost choice and belongs above '
              'theme mode, not below it');
    });

    test('the preview never previews by mutating the notifier', () {
      // Assigning `themeNotifier.material` to preview and restoring it fires
      // `notifyListeners()` and rebuilds the entire app — on every pointer
      // move, if it were wired to hover. The tiles take `material:` instead.
      expect(settingsSource.contains('onHover: (_) => themeNotifier.setMaterial'),
          isFalse);
      expect(settingsSource, contains('material: spec.id'),
          reason: 'the tiles must resolve their surfaces by parameter');
    });
  });
}
