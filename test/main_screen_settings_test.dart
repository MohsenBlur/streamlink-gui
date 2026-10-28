import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';
import 'package:streamlink_gui/utils/twitch_auth_status.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_switch.dart';
import 'package:streamlink_gui/widgets/sidebar_panel.dart';

import 'support/main_screen_harness.dart';

/// What saving Settings sets off, through the pumped screen (see
/// [ScreenHarness]). Another account token's reset is main_screen_test's;
/// these are the rest of the save's consequences. The dialog's own fields
/// are settings_dialog_test's.
void main() {
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });
  tearDown(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });

  Future<void> openSettings(
      WidgetTester tester, ScreenHarness h, String tab) async {
    await tester.tap(find.byTooltip('Settings').first);
    await h.settleRoute(tester);
    await tester.ensureVisible(find.text(tab));
    await tester.tap(find.text(tab));
    await h.settleRoute(tester);
  }

  Future<void> save(WidgetTester tester, ScreenHarness h) async {
    await tester.tap(find.text('Save changes'));
    await h.settleRoute(tester);
  }

  Finder field(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint);

  testWidgets(
      'clearing the account token signs out: no followed list, no account, '
      'back to Favorites', (tester) async {
    final h = ScreenHarness();
    h.helix.user('gamma');
    h.helix.followed.add('gamma');
    await h.launch(tester,
        size: const Size(1400, 1000),
        settings: ScreenHarness.defaultSettings()..activeSidebarTab = 1);
    expect(ScreenHarness.sidebarRow('gamma'), findsWidgets,
        reason: 'precondition: the followed list is up');
    expect(twitchAuth.helix.value.isUsable, isTrue);

    await openSettings(tester, h, 'Twitch');
    await tester.enterText(field('oauth:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'), '');
    await save(tester, h);

    expect(find.text('Settings saved successfully!'), findsOneWidget);
    expect(h.storage.savedSettings?.twitchOauthToken, '');
    expect(twitchAuth.helix.value.state, TwitchAuthState.absent);
    expect(ScreenHarness.sidebarRow('gamma'), findsNothing);
    expect(tester.widget<SidebarPanel>(find.byType(SidebarPanel)).sidebarTab,
        0,
        reason: 'the Followed tab goes with the token');
    // And the saved tab with it: left at Followed, a token added again later
    // in the session opened the next launch on Followed, though the sidebar
    // had shown Favorites since the sign-out.
    await h.advance(tester, const Duration(seconds: 2));
    expect(h.storage.savedSettings?.activeSidebarTab, 0);

    await h.close(tester);
  });

  testWidgets(
      'a new browser token is described at once, and the account is not '
      'probed again for it', (tester) async {
    final h = ScreenHarness();
    await h.launch(tester, size: const Size(1400, 1000));

    await openSettings(tester, h, 'Twitch');
    await tester.enterText(
        field('e.g. 5vnv4iix6wz8y31ok3p7xlccuyb72s'), 'browsertoken123');
    final helix = <TwitchAuthState>[];
    void listener() => helix.add(twitchAuth.helix.value.state);
    twitchAuth.helix.addListener(listener);
    addTearDown(() => twitchAuth.helix.removeListener(listener));
    await save(tester, h);

    expect(h.storage.savedSettings?.twitchWebOauthToken, 'browsertoken123');
    expect(twitchAuth.browser.value.state,
        statusForToken('browsertoken123').state);
    expect(helix, isNot(contains(TwitchAuthState.checking)),
        reason: 'the account token did not change; nothing to probe');
    expect(twitchAuth.helix.value.isUsable, isTrue);

    await h.close(tester);
  });

  testWidgets(
      'turning Launch at Windows startup on writes the Run key once, and the '
      'tray menu is rebuilt', (tester) async {
    final h = ScreenHarness();
    await h.launch(tester, size: const Size(1400, 1000));
    final menus = h.tray.menus.length;

    await openSettings(tester, h, 'System');
    final row = find.ancestor(
        of: find.text('Launch at Windows startup'), matching: find.byType(Row));
    final toggle =
        find.descendant(of: row.first, matching: find.byType(NeuSwitch));
    await tester.ensureVisible(toggle);
    await h.settle(tester);
    await tester.tap(toggle);
    await h.settle(tester);
    await save(tester, h);

    expect(h.startup.syncs, [true]);
    expect(h.storage.savedSettings?.launchAtStartup, isTrue);
    expect(h.tray.menus.length, menus + 1);

    // Saved again unchanged: the Run key is left alone. (Once the message
    // over the sidebar's Settings button has gone.)
    await h.advance(tester, const Duration(seconds: 6));
    await openSettings(tester, h, 'System');
    await save(tester, h);
    expect(h.startup.syncs, [true]);

    await h.close(tester);
  });
}
