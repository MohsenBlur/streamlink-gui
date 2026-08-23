import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/theme/neu_theme.dart';
import 'package:streamlink_gui/widgets/shell/neu_dialog.dart';

Widget host(Widget child) => MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: NeuTheme.defaultDarkAccent,
      ),
      home: Scaffold(body: child),
    );

void main() {
  _footerContract();
  group('NeuDialog', () {
    testWidgets('a dismissed dialog returns null, never a value',
        (tester) async {
      // The single most dangerous property of this migration. Nine showDialog
      // sites return values, and several gate a destructive action on the
      // result; if dismissing produced `false` for one caller and `null` for
      // another, a delete could silently proceed or silently not.
      bool? result = true;
      await tester.pumpWidget(host(Builder(builder: (context) {
        return TextButton(
          onPressed: () async {
            result = await NeuDialog.show<bool>(
              context,
              dismissible: true,
              builder: (context) => const NeuDialog(
                title: 'Delete?',
                content: Text('body'),
              ),
            );
          },
          child: const Text('open'),
        );
      })));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Delete?'), findsOneWidget);

      // Click the barrier.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Delete?'), findsNothing);
      expect(result, isNull,
          reason: 'a dismissal must be distinguishable from a choice');
    });

    testWidgets('a non-dismissible dialog survives a barrier tap',
        (tester) async {
      // The update-in-progress dialog relies on this: dismissing it mid-update
      // leaves the user with no indication that the app is replacing itself.
      await tester.pumpWidget(host(Builder(builder: (context) {
        return TextButton(
          onPressed: () => NeuDialog.show<void>(
            context,
            dismissible: false,
            builder: (context) => const NeuDialog(
              title: 'Updating',
              content: Text('body'),
            ),
          ),
          child: const Text('open'),
        );
      })));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Updating'), findsOneWidget,
          reason: 'barrierDismissible: false must actually hold');
    });

    testWidgets('the confirm sits after the dismiss', (tester) async {
      // Every dialog in the app now agrees on this order; they previously did
      // not, so muscle memory sent a click to a different action per dialog.
      await tester.pumpWidget(host(NeuDialog(
        title: 'Confirm',
        content: const Text('body'),
        actions: [
          NeuDialogAction.secondary('Cancel', () {}),
          NeuDialogAction.primary('Delete', () {}),
        ],
      )));

      final cancelX = tester.getCenter(find.text('Cancel')).dx;
      final deleteX = tester.getCenter(find.text('Delete')).dx;
      expect(deleteX, greaterThan(cancelX));
    });

    testWidgets('fits inside the 380x500 minimum window', (tester) async {
      // The dialogs it replaces used a hard 520x520 and 720x650, neither of
      // which fits a window the app itself permits.
      final overflows = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exception.toString().contains('overflowed')) {
          overflows.add(d.exception.toString().split('\n').first);
        } else {
          previous?.call(d);
        }
      };
      tester.view.physicalSize = const Size(380, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(NeuDialog(
        title: 'A dialog title long enough to need wrapping in a narrow window',
        icon: Icons.warning_amber,
        content: const Text(
            'A body paragraph with enough text in it to require scrolling '
            'inside a 500px-tall window, which is a size this app permits.'),
        actions: [
          NeuDialogAction.secondary('Cancel', () {}),
          NeuDialogAction.primary('Confirm', () {}),
        ],
      )));
      await tester.pump();
      FlutterError.onError = previous;

      expect(overflows, isEmpty);
      final size = tester.getSize(find.byType(Dialog));
      expect(size.width, lessThanOrEqualTo(380));
      expect(size.height, lessThanOrEqualTo(500));
    });

    testWidgets('a disabled primary action cannot be activated',
        (tester) async {
      var pressed = 0;
      await tester.pumpWidget(host(NeuDialog(
        title: 'Settings',
        content: const Text('body'),
        actions: [
          NeuDialogAction.primary('Save', null),
          NeuDialogAction.secondary('Cancel', () => pressed++),
        ],
      )));
      await tester.tap(find.text('Save'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(pressed, 0);
    });
  });
}

/// The footer's ParentDataWidget contract.
///
/// Kept apart from the layout sweep on purpose: this is the one class of
/// defect a screenshot and a size measurement can BOTH miss, because debug and
/// release disagree about it and only release is wrong.
///
/// `Flexible` is a `ParentDataWidget<FlexParentData>`. Put one in a `Wrap` and
/// `RenderObjectElement._updateParentData` notices — inside an `assert`. Debug
/// therefore logs "Incorrect use of ParentDataWidget", **declines to apply the
/// parent data**, and renders on looking entirely correct. Release strips the
/// assert along with the check it guards, `Flexible.applyParentData` casts
/// `WrapParentData` to `FlexParentData`, and the throw takes out the whole
/// subtree — Flutter swaps in a grey `RenderErrorBox`.
///
/// v1.7.0 shipped exactly that: a settings dialog whose entire body was a grey
/// rectangle in the release build, while every debug screenshot of it looked
/// right. Nothing in the suite could see it, because the suite runs in debug
/// and the sweep's test dialog passed plain `Text` leading actions.
void _footerContract() {
  group('the footer footgun', () {
    testWidgets('a Flexible leading action is rejected loudly, in debug',
        (tester) async {
      // The assert has to fire where it can be seen. Silence here is the bug:
      // the framework's own detection is silent in debug by design, so the
      // dialog carries its own check rather than relying on it.
      await tester.pumpWidget(host(Center(
        child: NeuDialog(
          title: 'Settings',
          content: const Text('body'),
          leadingActions: [
            Flexible(child: Row(mainAxisSize: MainAxisSize.min, children: const [Text('v1')])),
          ],
          actions: [NeuDialogAction.primary('Save', () {})],
        ),
      )));

      final thrown = tester.takeException();
      expect(thrown, isNotNull,
          reason: 'a Flexible leading action must fail the build in debug. If '
              'this passes silently, the contract is unenforced and the next '
              'one ships as a grey box in release.');
      expect(thrown.toString(), contains('leadingActions'));
    });

    testWidgets('plain leading actions build clean', (tester) async {
      // The control case. Without it the test above would still pass if
      // NeuDialog threw on everything.
      await tester.pumpWidget(host(Center(
        child: NeuDialog(
          title: 'Settings',
          content: const Text('body'),
          leadingActions: [
            const Text('v9.9.9'),
            const Text('GitHub Repo'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: const Text('Up to date',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ],
          actions: [NeuDialogAction.primary('Save', () {})],
        ),
      )));
      expect(tester.takeException(), isNull);
      expect(find.text('GitHub Repo'), findsOneWidget);
    });
  });
}
