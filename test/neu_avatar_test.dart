import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/widgets/neumorphic/neu_avatar.dart';

Widget host(Widget child) {
  return MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('NeuAvatar', () {
    testWidgets('no URL shows the fallback icon', (tester) async {
      await tester.pumpWidget(host(
        const NeuAvatar(url: null, radius: 18, isDark: true),
      ));
      expect(find.byIcon(Icons.person), findsOneWidget);
    });

    testWidgets('an empty or blank URL is treated as no URL', (tester) async {
      await tester.pumpWidget(host(
        const NeuAvatar(url: '   ', radius: 18, isDark: true),
      ));
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a URL that fails to load falls back to the icon',
        (tester) async {
      // The point of the widget. CircleAvatar's backgroundImage has no error
      // path - onBackgroundImageError only swallows the exception - so a
      // Twitch CDN URL that had expired left an empty coloured circle.
      //
      // flutter_test's HttpClient answers every request with 400, so this
      // exercises exactly that failure.
      await tester.pumpWidget(host(
        const NeuAvatar(
          url: 'https://static-cdn.jtvnw.net/expired-avatar.png',
          radius: 18,
          isDark: true,
        ),
      ));

      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.person), findsNothing); // still trying

      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.person), findsOneWidget);
    });

    testWidgets('the circle keeps the requested diameter', (tester) async {
      await tester.pumpWidget(host(
        const NeuAvatar(url: null, radius: 14, isDark: true),
      ));
      final size = tester.getSize(find.byType(NeuAvatar));
      expect(size.width, 28);
      expect(size.height, 28);
    });
  });
}
