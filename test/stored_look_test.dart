import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/material/app_material.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';

import 'support/main_screen_harness.dart';

/// A config saved by a build that offered a choice of looks, opened by this
/// one, which has only Soft (classic).
///
/// Builds since v1.7.0 stored the chosen look as `material` (Broadcast rack,
/// Warm analogue, Retro AV deck or Soft), and pre-release builds of this one
/// the "Simple rendering" switch as `canvas_engine`. An upgrade from any of
/// them has to open on Soft with no complaint, leave the file alone until the
/// app has its own reason to save, and then write what a rollback to one of
/// those builds reads as Soft.
void main() {
  for (final saved in ['rack', 'analogue', 'deck']) {
    testWidgets(
        'a config saved on $saved opens on Soft and is not rewritten for it',
        (tester) async {
      final h = ScreenHarness();
      h.helix.user('alpha');
      await h.launch(tester, favorites: ['alpha'], config: {
        'settings': {
          ...ScreenHarness.defaultSettings().toJson(),
          'material': saved,
          'canvas_engine': true,
        },
      });

      for (final isDark in [false, true]) {
        expect(NeuTheme.palette(isDark), same(softSpec.palette(isDark)),
            reason: 'the app wears Soft whatever look was saved');
      }
      expect(h.storage.configWrites, 0,
          reason: 'opening an old config is no reason to rewrite it');

      // The next save the app makes for a reason of its own.
      await tester.tap(find.byTooltip('Switch to Light Neumorphic').first);
      await h.settle(tester);
      final written = h.storage.config!['settings'] as Map<String, dynamic>;
      expect(written['is_dark_theme'], isFalse, reason: 'precondition');
      expect(written['material'], 'soft',
          reason: 'a rollback to v1.10.0 reads this key, and wears Rack '
              'without it');
      expect(written.containsKey('canvas_engine'), isFalse,
          reason: 'the switch is gone with the engine it switched');

      await h.close(tester);
    });
  }
}
