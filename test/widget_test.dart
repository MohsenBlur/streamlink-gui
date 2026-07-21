// This is a basic Flutter widget test for TwitchStreamlinkApp.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/main.dart';

void main() {
  testWidgets('Twitch Streamlink GUI smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const TwitchStreamlinkApp());

    // Verify that the title/branding exists
    expect(find.text('Streamlink GUI'), findsOneWidget);

    // Verify that the search input field is present
    expect(find.byType(TextField), findsOneWidget);
  });
}
