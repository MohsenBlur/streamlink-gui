import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/models/twitch_video.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_focusable.dart';
import 'package:streamlink_gui/widgets/shell/home_view.dart';

/// Everything Home reports back.
class Calls {
  final selected = <String>[];
  final launched = <String>[];
  final played = <String>[];
}

/// Home's two main strips, Live now and Continue watching, through the
/// real HomeView: a click answers at once, and the keyboard reaches them.
///
/// A live card was GestureDetector(onTap:, onDoubleTap:), which held every
/// click for the double-tap timeout - the lag the sidebar's live rows had
/// until DoubleClickListener - and neither card had focus at all, so Tab
/// went from the header straight to the quick actions.
void main() {
  late ScrollController recents;
  setUp(() => recents = ScrollController());
  tearDown(() => recents.dispose());

  Future<Calls> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final live = TwitchChannel(username: 'livechan')
      ..isLive = true
      ..streamTitle = 'Speedruns'
      ..game = 'Chess';
    final recent = TwitchVideo(
      id: 'v1',
      title: 'Last night',
      duration: '1h0m0s',
      thumbnailUrl: '', // no network in tests
      viewCount: '1',
      publishedAt: DateTime(2026, 1, 1),
      watchProgress: 0.4,
    );
    final calls = Calls();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeView(
          channels: [live],
          recentVods: [recent],
          runningDownloads: const [],
          downloadedCount: 0,
          accountLogin: 'someone',
          recentScroll: recents,
          fadeLeft: false,
          fadeRight: false,
          onRecentScrolled: () {},
          onAddChannel: () {},
          onSelectChannel: (c) => calls.selected.add(c.username),
          onLaunchLive: (c) => calls.launched.add(c.username),
          onPlayRecent: (v) => calls.played.add(v.id),
          onOpenLibrary: () {},
          onOpenSettings: () {},
          onConnectAccount: () {},
        ),
      ),
    ));
    await tester.pump();
    return calls;
  }

  /// Where the live card is, read before any click: a click hovers it, and
  /// its preview then repeats the title, so a text finder is ambiguous.
  Offset liveCard(WidgetTester tester) =>
      tester.getCenter(find.text('Speedruns'));

  testWidgets('a click on a live card opens the channel at once',
      (tester) async {
    final calls = await pumpHome(tester);
    await tester.tapAt(liveCard(tester), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls.selected, ['livechan'],
        reason: 'not after the 300ms double-tap timeout');
    expect(calls.launched, isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a double-click on it also plays it, and selects it once',
      (tester) async {
    final calls = await pumpHome(tester);
    final at = liveCard(tester);
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls.launched, ['livechan']);
    expect(calls.selected, ['livechan']);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Tab reaches both cards, and Enter opens and resumes them',
      (tester) async {
    final calls = await pumpHome(tester);
    for (var i = 0;
        i < 30 && (calls.selected.isEmpty || calls.played.isEmpty);
        i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final label = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<NeuFocusable>()
          ?.semanticLabel;
      if (label == null) continue;
      if (label.startsWith('livechan') || label.startsWith('Last night')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }
    }
    expect(calls.selected, ['livechan']);
    expect(calls.played, ['v1']);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('each card tells a screen reader what it is', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHome(tester);
    expect(find.bySemanticsLabel(RegExp(r'^livechan, live: Speedruns')),
        findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Last night, resume at 40%')),
        findsOneWidget);
    semantics.dispose();
  });
}
