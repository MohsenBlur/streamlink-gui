import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/utils/time_utils.dart';

void main() {
  group('timeAgo', () {
    final now = DateTime(2026, 8, 19, 12, 0, 0);

    String ago(Duration d) => timeAgo(now.subtract(d), now: now);

    test('sub-minute is "just now"', () {
      expect(ago(Duration.zero), 'just now');
      expect(ago(const Duration(seconds: 59)), 'just now');
    });

    test('minutes, singular and plural', () {
      expect(ago(const Duration(minutes: 1)), '1 minute ago');
      expect(ago(const Duration(minutes: 59)), '59 minutes ago');
    });

    test('hours boundary', () {
      expect(ago(const Duration(hours: 1)), '1 hour ago');
      expect(ago(const Duration(hours: 23, minutes: 59)), '23 hours ago');
    });

    test('days boundary', () {
      expect(ago(const Duration(days: 1)), '1 day ago');
      expect(ago(const Duration(days: 6)), '6 days ago');
    });

    test('weeks between 7 and 29 days', () {
      expect(ago(const Duration(days: 7)), '1 week ago');
      expect(ago(const Duration(days: 29)), '4 weeks ago');
    });

    test('months between 30 and 364 days', () {
      expect(ago(const Duration(days: 30)), '1 month ago');
      expect(ago(const Duration(days: 364)), '12 months ago');
    });

    test('years from 365 days', () {
      expect(ago(const Duration(days: 365)), '1 year ago');
      expect(ago(const Duration(days: 730)), '2 years ago');
    });
  });
}
