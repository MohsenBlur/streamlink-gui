import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/services/storage_service.dart';
import 'package:streamlink_gui/state/twitch_auth_notifier.dart';

import 'support/main_screen_harness.dart';

/// Adding and removing favourites, through the pumped screen (see
/// [ScreenHarness]). Which names are refused and how a lookup is coalesced
/// is channels_controller_test's; this is what the screen does around them.
void main() {
  setUp(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });
  tearDown(() {
    twitchAuth.resetForTest();
    storageWriteFailure.value = null;
  });

  Finder search() => find.byWidgetPredicate((w) =>
      w is TextField && w.decoration?.hintText == 'Search or add username...');

  Future<void> add(WidgetTester tester, ScreenHarness h, String name) async {
    await tester.enterText(search(), name);
    await tester.tap(find.byTooltip('Add Channel'));
    await h.settleRoute(tester);
  }

  /// Right-clicks [name]'s sidebar row and picks [item] from its menu.
  Future<void> fromRowMenu(
      WidgetTester tester, ScreenHarness h, String name, String item) async {
    await tester.tap(ScreenHarness.sidebarRow(name).first,
        buttons: kSecondaryMouseButton);
    await h.advance(tester, const Duration(milliseconds: 500),
        step: const Duration(milliseconds: 100));
    await tester.tap(find.text(item).last);
    await h.settleRoute(tester);
  }

  List<String> savedFavorites(ScreenHarness h) => [
        for (final c in (h.storage.config!['channels'] as List))
          (c as Map)['username'] as String,
      ];

  testWidgets(
      'a name added from the sidebar search is looked up, opened, saved and '
      'announced', (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.addVideo('alpha', title: 'Its newest VOD');
    await h.launch(tester);

    await add(tester, h, 'Alpha ');
    expect(find.text('Channel "alpha" added successfully!'), findsOneWidget);
    expect(ScreenHarness.sidebarRow('alpha'), findsWidgets);
    expect(find.text('Its newest VOD'), findsOneWidget,
        reason: 'opened through the one selection path');
    expect(tester.widget<TextField>(search()).controller!.text, isEmpty);
    expect(savedFavorites(h), ['alpha']);

    await h.close(tester);
  });

  testWidgets(
      'a name that cannot be a login, one already there, and one Twitch does '
      'not know are each refused with the reason', (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    await h.launch(tester, favorites: ['alpha']);

    await add(tester, h, 'not a name!');
    expect(find.text('"not a name!" is not a valid Twitch username.'),
        findsOneWidget);
    await h.advance(tester, const Duration(seconds: 6));

    await add(tester, h, 'alpha');
    expect(find.text('Channel "alpha" is already in your list.'),
        findsOneWidget);
    await h.advance(tester, const Duration(seconds: 6));

    await add(tester, h, 'nobody');
    expect(find.textContaining('Failed to add channel'), findsOneWidget);
    expect(savedFavorites(h), ['alpha']);

    await h.close(tester);
  });

  testWidgets(
      'a followed channel starred while live becomes a favourite, and is not '
      'then announced as going live', (tester) async {
    final h = ScreenHarness();
    h.helix.user('gamma');
    h.helix.followed.add('gamma');
    h.helix.goLive('gamma');
    await h.launch(tester,
        settings: ScreenHarness.defaultSettings()..activeSidebarTab = 1);

    await fromRowMenu(tester, h, 'gamma', 'Add to favorites');
    expect(find.text('Added "gamma" to Favorites.'), findsOneWidget);
    expect(savedFavorites(h), ['gamma']);

    await h.advance(tester, const Duration(seconds: 61));
    expect(h.notifications.titles, isNot(contains('gamma is now LIVE!')),
        reason: 'it was live when it joined; nothing went live');

    await h.close(tester);
  });

  testWidgets(
      'a favourite with automation is removed only after asking, and the '
      'dashboard it had open goes with it', (tester) async {
    final h = ScreenHarness();
    h.helix.user('alpha');
    h.helix.user('beta');
    await h.launch(tester,
        favorites: ['beta'],
        channels: [TwitchChannel(username: 'alpha', autoPlayLive: true)]);
    await h.openChannel(tester, 'alpha');

    await fromRowMenu(tester, h, 'alpha', 'Remove from favorites');
    expect(find.text('Remove alpha from favourites?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await h.settleRoute(tester);
    expect(savedFavorites(h), containsAll(['alpha', 'beta']));
    expect(find.text('Select'), findsOneWidget, reason: "alpha's dashboard");

    await fromRowMenu(tester, h, 'alpha', 'Remove from favorites');
    await tester.tap(find.text('Remove'));
    await h.settleRoute(tester);
    expect(find.text('Removed "alpha" from Favorites.'), findsOneWidget);
    expect(savedFavorites(h), ['beta']);
    expect(find.text('Select'), findsNothing, reason: 'back to the welcome');

    // One with nothing to lose goes at once.
    await h.advance(tester, const Duration(seconds: 6));
    await fromRowMenu(tester, h, 'beta', 'Remove from favorites');
    expect(find.text('Remove beta from favourites?'), findsNothing);
    expect(savedFavorites(h), isEmpty);

    await h.close(tester);
  });
}
