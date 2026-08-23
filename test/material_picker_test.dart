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

    test('a switch does not leave the previous material grain resident', () {
      // The tile is keyed on kind/size/amplitude/seed and NOT on the material,
      // deliberately, so two materials asking for the same brushed tile share
      // one image. That sharing is also why a switch has to evict: without it
      // a material with no texture would keep painting the last one's.
      themeNotifier.setMaterial(AppMaterial.soft);
      expect(TextureCache.residentCount, 0);
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

    test('Save persists it', () {
      expect(settingsSource, contains('material: themeNotifier.material.key'),
          reason: "the Save button's copyWith does not carry the material, so "
              'the choice is lost the moment the dialog closes');
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
