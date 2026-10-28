import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/activity_state.dart';
import 'package:streamlink_gui/widgets/activity_pill.dart';
import 'package:streamlink_gui/widgets/interactive_popover.dart';

ActivitySnapshot running(String label) => ActivitySnapshot(
      downloading: [
        ActivityItem(
          kind: ActivityKind.downloading,
          id: 'v1',
          label: label,
          progress: 0.5,
          status: '50.0% at 3.1MiB/s',
        ),
      ],
      queued: const [
        ActivityItem(kind: ActivityKind.queued, id: 'v2', label: 'Queued VOD'),
      ],
      playing: const [
        ActivityItem(
            kind: ActivityKind.liveStream, id: 'shroud', label: 'shroud'),
      ],
    );

void sized(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The pill where the title bar puts it: right-aligned, with the theme
/// toggle and the three window buttons (~150px) between it and the edge.
/// Compact below 600px, as main.dart has it.
Widget titleBar(ValueNotifier<ActivitySnapshot> activity,
        {void Function(ActivityItem)? onStop, bool compact = false}) =>
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  const Spacer(),
                  ActivityPill(
                    activity: activity,
                    onStop: onStop ?? (_) {},
                    compact: compact,
                  ),
                  const SizedBox(width: 150),
                ],
              ),
            ),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
      ),
    );

Rect popoverRect(WidgetTester tester) =>
    tester.getRect(find.byType(ActivityPopover));

void main() {
  group('PopoverPlacement', () {
    const window = Size(1000, 800);
    const child = Size(340, 200);

    Offset place(Rect trigger,
            {Alignment target = Alignment.bottomRight,
            Alignment follower = Alignment.topRight,
            Offset offset = const Offset(0, 6),
            Size size = child,
            Size overlay = window}) =>
        PopoverPlacement(
          trigger: trigger,
          targetAnchor: target,
          followerAnchor: follower,
          offset: offset,
        ).getPositionForChild(overlay, size);

    test('a popover with room lands exactly where the follower put it', () {
      // trigger bottom-right (600, 40) + (0, 6) - child top-right (340, 0)
      expect(place(const Rect.fromLTWH(500, 10, 100, 30)),
          const Offset(260, 46));
    });

    test('a right-aligned popover slides back onto a narrow window', () {
      // The activity popover at the 380px minimum: the pill's right edge
      // sits ~150px in, so the follower put the left edge at -110.
      final p = place(const Rect.fromLTWH(180, 6, 50, 28),
          overlay: const Size(380, 500));
      expect(p.dx, 8, reason: 'held a margin inside the left edge');
      expect(p.dy, 40);
    });

    test('a popover slides back from the right edge too', () {
      final p = place(const Rect.fromLTWH(900, 100, 40, 30),
          target: Alignment.bottomLeft, follower: Alignment.topLeft);
      expect(p.dx, 1000 - 8 - 340);
    });

    test('a trigger near the bottom opens upward', () {
      final p = place(const Rect.fromLTWH(500, 740, 100, 40));
      // Above: trigger top 740, minus the mirrored 6px, minus 200 tall.
      expect(p.dy, 740 - 6 - 200);
    });

    test('it does not flip when the other side has no room either', () {
      // 700 tall in an 800 window, trigger mid-screen: neither side fits, so
      // it keeps its side and slides up only as far as it must.
      final p = place(const Rect.fromLTWH(500, 300, 100, 40),
          size: const Size(340, 700));
      expect(p.dy, 800 - 8 - 700);
    });

    test('a trigger scrolled out of the window takes its popover with it', () {
      // Clamped, the popover stayed pinned 8px inside the top edge over
      // whatever had scrolled in, its trigger gone.
      expect(place(const Rect.fromLTWH(500, -100, 100, 30)),
          const Offset(260, -64));
      // Still partly on screen, it is kept inside as before: below a
      // trigger whose bottom is 1px into the window it would start at 7.
      expect(place(const Rect.fromLTWH(500, -29, 100, 30)).dy, 8);
    });

    test('it is never larger than the window less its margins', () {
      final c = const PopoverPlacement(
        trigger: Rect.zero,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: Offset.zero,
      ).getConstraintsForChild(
          BoxConstraints.tight(const Size(380, 500)));
      expect(c.maxWidth, 364);
      expect(c.maxHeight, 484);
      expect(c.minWidth, 0);
    });
  });

  group('the activity popover', () {
    testWidgets('stays on screen at the 380px minimum', (tester) async {
      // Regression: right-aligned to the pill, the 340px popover opened
      // ~110px off the left of a 380px window, cutting off every heading and
      // the start of every label.
      sized(tester, const Size(380, 500));
      final activity = ValueNotifier(running('A VOD'));
      addTearDown(activity.dispose);
      await tester.pumpWidget(titleBar(activity, compact: true));

      await tester.tap(find.byType(ActivityPill));
      await tester.pump();

      final rect = popoverRect(tester);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(380));
      expect(rect.bottom, lessThanOrEqualTo(500));
      // Still under the pill rather than over it.
      final pill = tester.getRect(find.byType(ActivityPill));
      expect(rect.top, greaterThanOrEqualTo(pill.bottom));
    });

    testWidgets('lands right-aligned under the pill on a wide window',
        (tester) async {
      // Nothing moves where there was room all along.
      sized(tester, const Size(1600, 1000));
      final activity = ValueNotifier(running('A VOD'));
      addTearDown(activity.dispose);
      await tester.pumpWidget(titleBar(activity));

      await tester.tap(find.byType(ActivityPill));
      await tester.pump();

      final pill = tester.getRect(find.byType(InteractivePopover));
      final rect = popoverRect(tester);
      expect(rect.right, moreOrLessEquals(pill.right));
      expect(rect.top, moreOrLessEquals(pill.bottom + 6));
      expect(rect.width, 340);
    });

    testWidgets('its content stays live while it is open', (tester) async {
      sized(tester, const Size(1600, 1000));
      final activity = ValueNotifier(running('First title'));
      addTearDown(activity.dispose);
      await tester.pumpWidget(titleBar(activity));
      await tester.tap(find.byType(ActivityPill));
      await tester.pump();
      expect(
          find.descendant(
              of: find.byType(ActivityPopover),
              matching: find.text('First title')),
          findsOneWidget);

      activity.value = running('Second title');
      await tester.pump();
      expect(
          find.descendant(
              of: find.byType(ActivityPopover),
              matching: find.text('Second title')),
          findsOneWidget);
    });

    testWidgets('a stop closes it and reports the item; outside taps close it',
        (tester) async {
      sized(tester, const Size(380, 500));
      final activity = ValueNotifier(running('A VOD'));
      addTearDown(activity.dispose);
      ActivityItem? stopped;
      await tester.pumpWidget(titleBar(activity,
          onStop: (item) => stopped = item, compact: true));

      await tester.tap(find.byType(ActivityPill));
      await tester.pump();
      await tester.tap(find.byTooltip('Stop playback'));
      await tester.pump();
      expect(stopped?.id, 'shroud');
      expect(find.byType(ActivityPopover), findsNothing);

      await tester.tap(find.byType(ActivityPill));
      await tester.pump();
      expect(find.byType(ActivityPopover), findsOneWidget);
      await tester.tapAt(const Offset(190, 450));
      await tester.pump();
      expect(find.byType(ActivityPopover), findsNothing);
    });
  });

  testWidgets('Esc inside a popover closes it, not the page behind it',
      (tester) async {
    // The portal builds the popover below its trigger, so key events from
    // inside it bubble through the page's shortcuts - main.dart binds Esc
    // there to close the Library, under a Focus(autofocus) like this one.
    // Typing into the search popover's field and pressing Esc closed the
    // Library behind a popover that stayed open.
    var pageEscapes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                pageEscapes++,
          },
          child: Focus(
            autofocus: true,
            child: Center(
              child: InteractivePopover(
                popover: const SizedBox(
                  key: ValueKey('menu'),
                  width: 200,
                  child: TextField(),
                ),
                child: const SizedBox(width: 60, height: 30),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byType(InteractivePopover));
    await tester.pump();
    expect(find.byKey(const ValueKey('menu')), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TextField>(),
        isNotNull,
        reason: 'the field inside the popover has focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('menu')), findsNothing);
    expect(pageEscapes, 0, reason: 'the page never saw the Esc');
  });

  testWidgets('Esc on the trigger closes an open popover, and only then',
      (tester) async {
    // Enter or Space on a focused trigger opens the popover and leaves focus
    // on the trigger, outside the popover, where the overlay's own Esc
    // binding cannot hear it: the page's Esc closed the Library behind a
    // popover that stayed open.
    var pageEscapes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                pageEscapes++,
          },
          child: Focus(
            autofocus: true,
            child: Center(
              child: InteractivePopover(
                popover: const SizedBox(
                    key: ValueKey('menu'), width: 200, height: 80),
                child: const SizedBox(width: 60, height: 30),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<InteractivePopover>(),
        isNotNull,
        reason: 'the trigger has focus');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byKey(const ValueKey('menu')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('menu')), findsNothing);
    expect(pageEscapes, 0, reason: 'the open popover took the Esc');

    // Closed, the trigger leaves Esc to the page.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(pageEscapes, 1);
  });

  group('focus', () {
    // The page as main.dart builds it: Esc bound to close the Library, under
    // a Focus(autofocus) that holds focus whenever nothing else does.
    Widget page({
      required VoidCallback onPageEscape,
      Widget popover =
          const SizedBox(key: ValueKey('menu'), width: 200, height: 80),
      Widget? elsewhere,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): onPageEscape,
              },
              child: Focus(
                autofocus: true,
                child: Column(
                  children: [
                    ?elsewhere,
                    Center(
                      child: InteractivePopover(
                        popover: popover,
                        child: const SizedBox(width: 60, height: 30),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

    bool focusInPopover() {
      final focus = FocusManager.instance.primaryFocus;
      return focus != null &&
          [focus, ...focus.ancestors].any((n) => n.debugLabel == 'popover');
    }

    testWidgets('Esc closes a popover a mouse click opened', (tester) async {
      // A click leaves focus where it was - the page - and the popover's Esc
      // binding only hears keys from inside the popover, so the page's Esc
      // closed the Library behind a popover that stayed open.
      var pageEscapes = 0;
      await tester.pumpWidget(page(onPageEscape: () => pageEscapes++));
      await tester.tap(find.byType(InteractivePopover));
      await tester.pump();
      expect(find.byKey(const ValueKey('menu')), findsOneWidget);
      expect(focusInPopover(), isTrue, reason: 'opening moved focus inside');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('menu')), findsNothing);
      expect(pageEscapes, 0, reason: 'the page never saw the Esc');

      // Focus went back to the page, whose Esc works as before.
      expect(focusInPopover(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(pageEscapes, 1);
    });

    testWidgets('closing gives focus back to the trigger that opened it',
        (tester) async {
      await tester.pumpWidget(page(onPageEscape: () {}));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final trigger = FocusManager.instance.primaryFocus;
      expect(
          trigger?.context?.findAncestorWidgetOfExactType<InteractivePopover>(),
          isNotNull,
          reason: 'the trigger has focus');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(focusInPopover(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('menu')), findsNothing);
      expect(FocusManager.instance.primaryFocus, same(trigger));
    });

    testWidgets('an autofocus field inside a popover gets focus',
        (tester) async {
      // Flutter drops an autofocus request when the field's scope already
      // has a focused child, and the page's Focus(autofocus) was that child:
      // the field opened with no caret. In the popover's own scope it takes.
      await tester.pumpWidget(page(
        onPageEscape: () {},
        popover: const SizedBox(
            key: ValueKey('menu'),
            width: 200,
            child: TextField(autofocus: true)),
      ));
      await tester.tap(find.byType(InteractivePopover));
      await tester.pump();
      await tester.pump();
      expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<TextField>(),
          isNotNull);
    });

    testWidgets('focus moved elsewhere on the page closes the popover',
        (tester) async {
      // Ctrl+F sends focus to the sidebar search while a popover is open. An
      // open popover without focus could not hear its Esc any more.
      final elsewhere = FocusNode();
      addTearDown(elsewhere.dispose);
      await tester.pumpWidget(page(
        onPageEscape: () {},
        elsewhere: SizedBox(
            width: 200, child: TextField(focusNode: elsewhere)),
      ));
      await tester.tap(find.byType(InteractivePopover));
      await tester.pump();
      expect(find.byKey(const ValueKey('menu')), findsOneWidget);

      elsewhere.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('menu')), findsNothing);
      expect(elsewhere.hasPrimaryFocus, isTrue,
          reason: 'closing did not pull focus back from where it went');
    });

    testWidgets('a dialog opened from a popover, or the window deactivating, '
        'leaves it open', (tester) async {
      await tester.pumpWidget(page(
        onPageEscape: () {},
        popover: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('menu'),
            onPressed: () => Navigator.of(context).push(DialogRoute<void>(
              context: context,
              builder: (_) => const Material(
                child: TextField(key: ValueKey('dialog'), autofocus: true),
              ),
            )),
            child: const Text('Open dialog'),
          ),
        ),
      ));
      await tester.tap(find.byType(InteractivePopover));
      await tester.pump();

      // On Windows the FocusManager parks focus on the root scope when the
      // app loses activation, and gives it back on resume.
      final suspended = FocusManager.instance.primaryFocus!;
      FocusManager.instance.rootScope.requestScopeFocus();
      await tester.pump();
      expect(find.byKey(const ValueKey('menu')), findsOneWidget);
      suspended.requestFocus();
      await tester.pump();
      expect(focusInPopover(), isTrue);

      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<TextField>()
              ?.key,
          const ValueKey('dialog'));
      expect(find.byKey(const ValueKey('menu')), findsOneWidget,
          reason: 'focus went to another route, not elsewhere on the page');
    });
  });

  testWidgets('a popover follows a trigger that scrolls', (tester) async {
    // The dashboard header's popovers sit inside the page's CustomScrollView.
    // The follower tracked the trigger at compositing time; the portal has to
    // track it at layout time, every frame.
    sized(tester, const Size(800, 600));
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 200),
            Align(
              alignment: Alignment.centerLeft,
              child: InteractivePopover(
                targetAnchor: Alignment.bottomLeft,
                followerAnchor: Alignment.topLeft,
                popover: const SizedBox(
                    key: ValueKey('menu'), width: 120, height: 80),
                child: const SizedBox(width: 60, height: 30),
              ),
            ),
            const SizedBox(height: 2000),
          ],
        ),
      ),
    ));
    await tester.tap(find.byType(InteractivePopover));
    await tester.pump();
    final before = tester.getRect(find.byKey(const ValueKey('menu')));
    expect(before.top,
        moreOrLessEquals(tester.getRect(find.byType(InteractivePopover)).bottom + 6));

    scroll.jumpTo(50);
    await tester.pump();
    final after = tester.getRect(find.byKey(const ValueKey('menu')));
    expect(after.top, moreOrLessEquals(before.top - 50));

    // Scrolled clean off the top (and still inside the list's cache
    // extent, so still built), the trigger takes the popover with it.
    scroll.jumpTo(250);
    await tester.pump();
    // Out of the viewport, so offstage to a default finder - the popover
    // too, whose element sits under the trigger's.
    final trigger = tester
        .getRect(find.byType(InteractivePopover, skipOffstage: false));
    expect(trigger.bottom, lessThan(0), reason: 'precondition');
    expect(
        tester
            .getRect(find.byKey(const ValueKey('menu'), skipOffstage: false))
            .top,
        moreOrLessEquals(trigger.bottom + 6));
  });
}
