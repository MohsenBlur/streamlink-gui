import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/widgets/twitch_video_card.dart';
import 'package:streamlink_gui/widgets/vods_grid.dart';

TwitchVideo vod(int i) => TwitchVideo(
      id: 'vod$i',
      title: 'VOD $i',
      duration: '1h0m0s',
      thumbnailUrl: '', // no network in tests
      viewCount: '1',
      publishedAt: DateTime(2026, 1, 1),
    );

/// Everything the grid reports back, by VOD id.
class Calls {
  final played = <String>[];
  final downloaded = <String>[];
  final deleted = <String>[];
  final cancelled = <String>[];
  final opened = <String>[];
  final selected = <String, bool>{};
}

void main() {
  late TextEditingController search;
  setUp(() => search = TextEditingController());
  tearDown(() => search.dispose());

  /// The real grid of real cards: vod0 is fresh, vod1 is downloaded, vod2 is
  /// mid-download.
  Future<Calls> pumpGrid(
    WidgetTester tester, {
    bool multiSelect = false,
    Set<String> playing = const {},
  }) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final calls = Calls();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          return CustomScrollView(slivers: [
            VodsGrid(
              vods: [vod(0), vod(1), vod(2)],
              isLoading: false,
              vodsError: null,
              vodScale: 300,
              vodTitleFontSize: 14,
              showGamesOnThumbnails: false,
              selectedGamesFilter: const {},
              vodSearchController: search,
              theme: Theme.of(context),
              isMultiSelectMode: multiSelect,
              selectedVodIds: const {},
              isPlaying: playing.contains,
              isDownloaded: (id) => id == 'vod1',
              getDownloadStatus: (id) => id == 'vod2' ? '45%' : null,
              getDownloadProgress: (id) => id == 'vod2' ? 0.45 : null,
              pulseController: null,
              watchedThreshold: 90,
              activeProgressColor: Colors.purple,
              watchedProgressColor: Colors.green,
              onGameFilterSelected: (_) {},
              onClearGameFilter: () {},
              onPlay: (v) => calls.played.add(v.id),
              onDownload: (v) => calls.downloaded.add(v.id),
              onDeleteDownload: calls.deleted.add,
              onCancelDownload: calls.cancelled.add,
              onVodSelectedChange: (id, on) => calls.selected[id] = on,
              onOpenFolder: (v) => calls.opened.add(v.id),
            ),
          ]);
        }),
      ),
    ));
    await tester.pump();
    return calls;
  }

  Finder card(String id) => find.byKey(ValueKey(id));

  bool focusIsIn(Finder target) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final element = target.evaluate().single;
    if (focused == element) return true;
    var inside = false;
    focused.visitAncestorElements((e) {
      if (e == element) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }

  /// Tabs until keyboard focus is on [target] - from the keyboard alone,
  /// the way a user without a mouse gets there.
  Future<void> tabTo(WidgetTester tester, Finder target) async {
    for (var i = 0; i < 20 && !focusIsIn(target); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(focusIsIn(target), isTrue, reason: 'Tab never reached the card');
  }

  Future<void> shiftF10(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  group('a VOD card from the keyboard', () {
    testWidgets('Tab reaches it, and Enter and Space play it',
        (tester) async {
      // Regression: the card had no focus at all, so no key ever reached it.
      final calls = await pumpGrid(tester);
      await tabTo(tester, card('vod0'));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls.played, ['vod0']);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(calls.played, ['vod0', 'vod0']);
    });

    testWidgets('focus reveals its buttons, and Tab moves into them',
        (tester) async {
      // The Download button existed only under a hovering mouse.
      final calls = await pumpGrid(tester);
      final download = find.descendant(
          of: card('vod0'), matching: find.byTooltip('Download VOD'));
      expect(download, findsNothing);

      await tabTo(tester, card('vod0'));
      expect(download, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusIsIn(download), isTrue,
          reason: 'focus moved into the card, and the button stayed');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls.downloaded, ['vod0']);
      expect(calls.played, isEmpty);
    });

    testWidgets('Shift+F10 opens its menu', (tester) async {
      final calls = await pumpGrid(tester);
      await tabTo(tester, card('vod0'));
      await shiftF10(tester);

      expect(find.text('Play'), findsOneWidget);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(calls.downloaded, ['vod0']);
    });

    testWidgets('the Menu key opens a downloaded card\'s menu',
        (tester) async {
      final calls = await pumpGrid(tester);
      await tabTo(tester, card('vod1'));
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();

      expect(find.text('Play local file'), findsOneWidget);
      expect(find.text('Show in Explorer'), findsOneWidget);
      await tester.tap(find.text('Delete download'));
      await tester.pumpAndSettle();
      expect(calls.deleted, ['vod1']);
    });

    testWidgets('a playing card stays reachable, but does not relaunch',
        (tester) async {
      final calls = await pumpGrid(tester, playing: {'vod1'});
      await tabTo(tester, card('vod1'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls.played, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      final play = tester.widget<PopupMenuItem<int>>(find.ancestor(
          of: find.text('Play local file'),
          matching: find.byType(PopupMenuItem<int>)));
      expect(play.enabled, isFalse);
      await tester.tap(find.text('Show in Explorer'));
      await tester.pumpAndSettle();
      expect(calls.opened, ['vod1']);
    });

    testWidgets('in multi-select Space toggles it, and there is no menu',
        (tester) async {
      final calls = await pumpGrid(tester, multiSelect: true);
      await tabTo(tester, card('vod0'));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(calls.selected, {'vod0': true});

      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<int>), findsNothing);
    });
  });

  group('a VOD card without a mouse', () {
    testWidgets('a long press reaches a downloading card\'s Cancel',
        (tester) async {
      // Touch and pen never hover, so the hover-only Cancel button was out
      // of reach for them entirely.
      final calls = await pumpGrid(tester);
      await tester.longPress(card('vod2'));
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsNothing,
          reason: 'already downloading');
      await tester.tap(find.text('Cancel download'));
      await tester.pumpAndSettle();
      expect(calls.cancelled, ['vod2']);
    });

    testWidgets('in multi-select a long press still toggles it',
        (tester) async {
      // Regression: the context menu's long-press recognizer stayed in the
      // arena with an empty menu, won any press held past the timeout and
      // opened nothing - so a slow click or a touch-and-hold on a card in
      // multi-select was swallowed instead of selecting it.
      final calls = await pumpGrid(tester, multiSelect: true);
      await tester.longPress(card('vod0'));
      await tester.pumpAndSettle();
      expect(calls.selected, {'vod0': true});
      expect(find.byType(PopupMenuItem<int>), findsNothing);
    });

    testWidgets('a pen\'s long press opens the menu too', (tester) async {
      await pumpGrid(tester);
      final gesture = await tester.startGesture(tester.getCenter(card('vod0')),
          kind: PointerDeviceKind.stylus);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('a right-click opens the same menu', (tester) async {
      final calls = await pumpGrid(tester);
      await tester.tap(card('vod0'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(calls.played, isEmpty, reason: 'a right-click is not a play');
      expect(find.text('Download'), findsOneWidget);
    });
  });

  testWidgets('a mouse press held past the long-press timeout is still a '
      'click', (tester) async {
    // A mouse has a right button for the menu. While the long press
    // accepted mouse too, a slow primary click opened the menu and the
    // VOD never played.
    final calls = await pumpGrid(tester);
    final gesture = await tester.startGesture(tester.getCenter(card('vod0')),
        kind: PointerDeviceKind.mouse);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<int>), findsNothing);
    expect(calls.played, ['vod0']);
  });

  testWidgets('each card tells a screen reader what it is', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpGrid(tester, playing: {'vod0'});

    // The card is a button node; its own texts (duration, views) merge into
    // it after the summary, which is what a reader announces first.
    Finder announced(String summary) =>
        find.bySemanticsLabel(RegExp('^${RegExp.escape(summary)}'));
    expect(announced('VOD 0, now playing'), findsOneWidget);
    expect(tester.getSemantics(announced('VOD 0, now playing')),
        isSemantics(isButton: true, isFocusable: true));
    expect(announced('VOD 1, downloaded'), findsOneWidget);
    expect(announced('VOD 2, downloading, 45%'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a card is still one widget per VOD', (tester) async {
    // Guard against the wrappers above duplicating the card in the tree.
    await pumpGrid(tester);
    expect(find.byType(TwitchVideoCard), findsNWidgets(3));
  });

  group('a long game name', () {
    // Wider than a pill (half the card) in the test font, which draws every
    // glyph a full em wide, and narrower than the card the badge sits in.
    const long = 'A category name too long';
    const games = [long, 'Just Chatting'];

    Future<void> pumpCard(WidgetTester tester,
        {required bool onThumbnails, List<String> names = games}) async {
      tester.view.physicalSize = const Size(600, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: TwitchVideoCard(
                  vod: vod(0)..games = List.of(names),
                  scale: 300,
                  theme: Theme.of(context),
                  onPlay: () {},
                  formatNumber: (n) => n,
                  titleFontSize: 14,
                  isPlaying: false,
                  pulseController: null,
                  showGamesOnThumbnails: onThumbnails,
                  watchedThreshold: 90,
                  activeProgressColor: Colors.purple,
                  watchedProgressColor: Colors.green,
                  onDownload: () {},
                  onDeleteDownload: () {},
                  onCancel: () {},
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    /// Hovers [target] until its tooltip is up.
    Future<void> hover(WidgetTester tester, Finder target) async {
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 200));
    }

    final everyName = games.join('\n');

    testWidgets('can be read in full from its pill on the thumbnail',
        (tester) async {
      // The pills share half the card's width and cut a long name short;
      // the one-badge path had a tooltip with every name, this one had none.
      await pumpCard(tester, onThumbnails: true);
      final pill = find.text(long);
      expect(tester.renderObject<RenderParagraph>(pill).didExceedMaxLines,
          isTrue,
          reason: 'precondition: the pill cuts the name short');
      expect(find.byTooltip(everyName), findsOneWidget);

      await hover(tester, pill);
      expect(find.text(everyName), findsOneWidget,
          reason: 'the tooltip shows every name in full');
    });

    testWidgets('and from the single badge, as before', (tester) async {
      await pumpCard(tester, onThumbnails: false);
      expect(find.byTooltip(everyName), findsOneWidget);
      await hover(tester, find.byTooltip(everyName));
      expect(find.text(everyName), findsOneWidget);
    });

    testWidgets('wider than the card stays on it in the single badge, cut '
        'short there', (tester) async {
      // The badge sits in the thumbnail's top-right corner, which bounds it
      // on the right only: a name wider than the card grew it leftwards past
      // the card's edge. Half the card at most, as the pills are; its
      // tooltip has the name in full.
      const longest = 'A category name far too long for the card to hold whole';
      await pumpCard(tester,
          onThumbnails: false, names: const [longest, 'Just Chatting']);
      final card = tester.getRect(find.byType(TwitchVideoCard));
      final name = find.text(longest);
      expect(tester.getRect(name).left, greaterThanOrEqualTo(card.left));
      expect(tester.getRect(name).width, lessThanOrEqualTo(card.width / 2));
      expect(tester.renderObject<RenderParagraph>(name).didExceedMaxLines,
          isTrue);
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('$longest\nJust Chatting'), findsOneWidget);
    });
  });
}
