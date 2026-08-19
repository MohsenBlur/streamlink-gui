import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/services/update_service.dart';

void main() {
  group('UpdateService.compareVersions', () {
    test('orders by major, minor then patch', () {
      expect(UpdateService.compareVersions('1.0.61', '1.0.60'), greaterThan(0));
      expect(UpdateService.compareVersions('1.0.60', '1.0.61'), lessThan(0));
      expect(UpdateService.compareVersions('1.1.0', '1.0.99'), greaterThan(0));
      expect(UpdateService.compareVersions('2.0.0', '1.99.99'), greaterThan(0));
    });

    test('treats equal versions as equal regardless of a v prefix', () {
      expect(UpdateService.compareVersions('1.0.60', '1.0.60'), 0);
      expect(UpdateService.compareVersions('v1.0.60', '1.0.60'), 0);
      expect(UpdateService.compareVersions('v1.0.60', 'v1.0.60'), 0);
    });

    test('does not carry a component into the next field', () {
      // Regression: the previous implementation packed the version as
      // major*1000000 + minor*1000 + patch, so 1.0.1000 compared equal to
      // 1.1.0 and a genuine update could be reported as "no update".
      expect(UpdateService.compareVersions('1.0.1000', '1.1.0'), lessThan(0));
      expect(UpdateService.compareVersions('1.1.0', '1.0.1000'), greaterThan(0));
      expect(UpdateService.compareVersions('1.0.1001', '1.0.1000'), greaterThan(0));
    });

    test('pads missing components with zero', () {
      expect(UpdateService.compareVersions('1.2', '1.2.0'), 0);
      expect(UpdateService.compareVersions('1', '1.0.0'), 0);
      expect(UpdateService.compareVersions('1.2.1', '1.2'), greaterThan(0));
    });

    test('does not crash on malformed input', () {
      expect(UpdateService.compareVersions('', ''), 0);
      expect(UpdateService.compareVersions('not-a-version', '0.0.0'), 0);
      expect(UpdateService.compareVersions('v1.0.60-beta', '1.0.60'), 0);
    });
  });

  group('UpdateService version injection', () {
    test('falls back to the dev sentinel when APP_VERSION is not defined', () {
      // `flutter test` runs without --dart-define=APP_VERSION, so this asserts
      // the fallback path rather than a hardcoded release number.
      expect(UpdateService.currentVersion, UpdateService.devVersion);
      expect(UpdateService.isDevBuild, isTrue);
    });

    test('a dev build never reports an available update', () async {
      // Guards against a dev build self-updating over the working tree.
      expect(await UpdateService().checkForUpdates(), isNull);
    });
  });

  group('UpdateInfo', () {
    test('tagName always carries a single v prefix', () {
      final withPrefix = UpdateInfo(
        version: 'v1.2.3',
        releaseNotes: '',
        zipDownloadUrl: 'https://example.invalid/a.zip',
        isUpdateAvailable: true,
      );
      final withoutPrefix = UpdateInfo(
        version: '1.2.3',
        releaseNotes: '',
        zipDownloadUrl: 'https://example.invalid/a.zip',
        isUpdateAvailable: true,
      );
      expect(withPrefix.tagName, 'v1.2.3');
      expect(withoutPrefix.tagName, 'v1.2.3');
    });
  });
}
