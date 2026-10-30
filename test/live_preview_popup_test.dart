import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/models/twitch_channel.dart';
import 'package:streamlink_gui/widgets/live_preview_popup.dart';

void main() {
  group('LivePreviewPopup.previewUrl', () {
    final opened = DateTime.utc(2026, 10, 28, 12, 0, 0);

    test('a re-hover inside the interval asks for the same image', () {
      // Regression: the buster was the open time in milliseconds, so every
      // re-hover minted a URL nothing had seen - a new download, a new
      // ImageCache entry and a blank card while it loaded.
      expect(
          LivePreviewPopup.previewUrl('shroud', opened),
          LivePreviewPopup.previewUrl(
              'shroud', opened.add(const Duration(seconds: 29))));
    });

    test('a new interval asks for a fresh image', () {
      expect(
          LivePreviewPopup.previewUrl('shroud', opened),
          isNot(LivePreviewPopup.previewUrl(
              'shroud', opened.add(LivePreviewPopup.refreshInterval))));
    });

    test('the name is normalised, so case and padding share one image', () {
      expect(LivePreviewPopup.previewUrl('  Shroud ', opened),
          LivePreviewPopup.previewUrl('shroud', opened));
      expect(LivePreviewPopup.previewUrl('shroud', opened),
          startsWith('https://static-cdn.jtvnw.net/previews-ttv/'
              'live_user_shroud-320x180.jpg?t='));
    });
  });

  testWidgets('the open card loads the current interval\'s URL',
      (tester) async {
    final channel = TwitchChannel(username: 'shroud')..isLive = true;
    final before = DateTime.now();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LivePreviewPopup(channel: channel)),
    ));
    final after = DateTime.now();

    final image = tester.widget<Image>(find.byType(Image)).image;
    final url = (image as NetworkImage).url;
    // Either side of a bucket edge, never a raw millisecond stamp.
    expect(url, anyOf(LivePreviewPopup.previewUrl('shroud', before),
        LivePreviewPopup.previewUrl('shroud', after)));
  });
}
