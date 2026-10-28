import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/services/update_service.dart';

const _asset = 'streamlink-gui-windows.zip';
const _zipUrl = 'https://example.invalid/releases/download/v9.9.9/$_asset';
const _sumsUrl = 'https://example.invalid/releases/download/v9.9.9/SHA256SUMS';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// A client that fails the test if anything is requested through it.
http.Client _noNetwork() => MockClient((request) async {
      fail('unexpected request to ${request.url}');
    });

List<int> _zipOf(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return ZipEncoder().encode(archive)!;
}

/// Every file the extractor insists a complete build carries.
const _completeBuild = <String>[
  'app/streamlink_gui.exe',
  'app/updater.exe',
  'app/bin/bin/streamlink.exe',
  'app/bin/yt-dlp.exe',
  'app/bin/ffmpeg.exe',
];

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

  group('UpdateService.expectedDigestFor', () {
    final a = 'a' * 64;
    final b = 'B' * 64;

    test('reads the release format, stray CR and all', () {
      expect(UpdateService.expectedDigestFor('$a  $_asset\r\n', _asset), a);
    });

    test('picks the named line out of a multi-file list', () {
      final sums = '$a  installer.exe\n$b *dist/$_asset\n';
      expect(UpdateService.expectedDigestFor(sums, _asset), 'b' * 64);
      expect(UpdateService.expectedDigestFor(sums, _asset.toUpperCase()),
          'b' * 64);
    });

    test('has no answer when several files are listed and none is ours', () {
      final sums = '$a  installer.exe\n$b  notes.txt\n';
      expect(UpdateService.expectedDigestFor(sums, _asset), isNull);
    });

    test('takes a lone digest whatever it names', () {
      expect(UpdateService.expectedDigestFor(a, _asset), a);
      expect(UpdateService.expectedDigestFor('$a  renamed.zip', _asset), a);
    });

    test('has no answer for a body with no digest at all', () {
      expect(UpdateService.expectedDigestFor('', _asset), isNull);
      expect(UpdateService.expectedDigestFor('<html>Not Found</html>', _asset),
          isNull);
    });
  });

  group('UpdateService.zipFileNameFor', () {
    test("keeps the release asset's own name", () {
      expect(UpdateService.zipFileNameFor(_zipUrl), _asset);
    });

    test('falls back for anything that is not a plain zip name', () {
      expect(UpdateService.zipFileNameFor('https://example.invalid/'), 'update.zip');
      expect(UpdateService.zipFileNameFor('https://example.invalid/download?id=7'),
          'update.zip');
      expect(UpdateService.zipFileNameFor('https://example.invalid/a%2F..%2Fb.zip'),
          'update.zip');
    });
  });

  group('update downloads never outlive a failure', () {
    late Directory root;

    setUp(() {
      // Deliberately not carrying the update prefix itself.
      root = Directory.systemTemp.createTempSync('streamlink_gui_updater_test_');
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    List<Directory> updateDirs() => root
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).startsWith(UpdateService.updateDirPrefix))
        .toList();

    /// A finished download, laid out exactly as downloadUpdate leaves it.
    File downloaded(List<int> bytes) {
      final dir = Directory(p.join(root.path, '${UpdateService.updateDirPrefix}test'))
        ..createSync();
      return File(p.join(dir.path, _asset))..writeAsBytesSync(bytes);
    }

    UpdateService serving(String sums, {int status = 200}) => UpdateService(
          tempRoot: root,
          client: MockClient((request) async {
            expect(request.url.toString(), _sumsUrl);
            return http.Response(sums, status);
          }),
        );

    group('verifyChecksum', () {
      final payload = utf8.encode('the real archive');

      test('passes a download whose digest matches, and keeps it', () async {
        final zip = downloaded(payload);
        await serving('${_sha(payload)}  $_asset\n').verifyChecksum(zip, _sumsUrl);
        expect(zip.existsSync(), isTrue);
      });

      test('rejects a mismatch and actually discards the download', () async {
        // The message always said "was discarded"; nothing deleted it.
        final zip = downloaded(payload);
        await expectLater(
          serving('${'0' * 64}  $_asset\n').verifyChecksum(zip, _sumsUrl),
          throwsA(predicate((e) => '$e'.contains('integrity check'))),
        );
        expect(updateDirs(), isEmpty);
      });

      test('fails closed when the checksum list is not served', () async {
        // Regression: a non-200 returned silently and the update went ahead
        // unverified.
        final zip = downloaded(payload);
        await expectLater(
          serving('Not Found', status: 404).verifyChecksum(zip, _sumsUrl),
          throwsA(predicate((e) => '$e'.contains('HTTP 404') && '$e'.contains('not applied'))),
        );
        expect(updateDirs(), isEmpty);
      });

      test('fails closed when the checksum request itself fails', () async {
        // Regression: a dropped connection on this one small request let an
        // unverified archive straight through.
        final zip = downloaded(payload);
        final service = UpdateService(
          tempRoot: root,
          client: MockClient((_) async => throw const SocketException('reset')),
        );
        await expectLater(
          service.verifyChecksum(zip, _sumsUrl),
          throwsA(predicate((e) => '$e'.contains('network error'))),
        );
        expect(updateDirs(), isEmpty);
      });

      test('fails closed when the list has no digest for this archive', () async {
        final zip = downloaded(payload);
        final sums = '${_sha(payload)}  installer.exe\n${'1' * 64}  notes.txt\n';
        await expectLater(
          serving(sums).verifyChecksum(zip, _sumsUrl),
          throwsA(predicate((e) => '$e'.contains('no entry for $_asset'))),
        );
        expect(updateDirs(), isEmpty);
      });

      test("matches this archive's line in a multi-file list", () async {
        final zip = downloaded(payload);
        final sums = '${'1' * 64}  installer.exe\n${_sha(payload)}  $_asset\n';
        await serving(sums).verifyChecksum(zip, _sumsUrl);
        expect(zip.existsSync(), isTrue);
      });

      test('lets a release without SHA256SUMS through untouched', () async {
        final zip = downloaded(payload);
        await UpdateService(tempRoot: root, client: _noNetwork())
            .verifyChecksum(zip, '');
        expect(zip.existsSync(), isTrue);
      });

      test('never deletes a directory it did not create', () async {
        final elsewhere = Directory(p.join(root.path, 'not-an-update-dir'))..createSync();
        final zip = File(p.join(elsewhere.path, _asset))..writeAsBytesSync(payload);
        await expectLater(
          serving('${'0' * 64}  $_asset\n').verifyChecksum(zip, _sumsUrl),
          throwsException,
        );
        expect(zip.existsSync(), isTrue);
      });
    });

    group('downloadUpdate', () {
      UpdateService streaming(Stream<List<int>> body, {int? contentLength, int status = 200}) =>
          UpdateService(
            tempRoot: root,
            client: MockClient.streaming((request, _) async =>
                http.StreamedResponse(body, status, contentLength: contentLength)),
          );

      test("saves the archive under the asset's name in its own directory", () async {
        final bytes = utf8.encode('zip bytes');
        final zip = await streaming(Stream.value(bytes), contentLength: bytes.length)
            .downloadUpdate(_zipUrl, null);

        expect(p.basename(zip.path), _asset);
        expect(zip.readAsBytesSync(), bytes);
        expect(updateDirs().single.path, zip.parent.path);
      });

      test('a refused download creates nothing', () async {
        await expectLater(
          streaming(const Stream.empty(), status: 503).downloadUpdate(_zipUrl, null),
          throwsException,
        );
        expect(updateDirs(), isEmpty);
      });

      test('a download cut short is rejected and removed', () async {
        await expectLater(
          streaming(Stream.value([1, 2, 3]), contentLength: 10).downloadUpdate(_zipUrl, null),
          throwsA(predicate((e) => '$e'.contains('cut short'))),
        );
        expect(updateDirs(), isEmpty);
      });

      test('a download that errors midway is removed', () async {
        final body = StreamController<List<int>>();
        final pending = streaming(body.stream, contentLength: 100).downloadUpdate(_zipUrl, null);
        body.add([1, 2, 3]);
        body.addError(const SocketException('connection reset'));
        unawaited(body.close());

        await expectLater(pending, throwsA(isA<SocketException>()));
        expect(updateDirs(), isEmpty);
      });
    });

    group('extractAndVerifyZip', () {
      UpdateService service() => UpdateService(tempRoot: root, client: _noNetwork());

      test('returns the build and frees the archive it no longer needs', () async {
        final zip = downloaded(_zipOf({for (final f in _completeBuild) f: [1]}));

        final appRoot = await service().extractAndVerifyZip(zip);

        expect(File(p.join(appRoot.path, 'streamlink_gui.exe')).existsSync(), isTrue);
        expect(zip.existsSync(), isFalse, reason: 'the ~300 MB archive is spent');
      });

      test('an incomplete build is rejected and removed', () async {
        final zip = downloaded(_zipOf({'app/streamlink_gui.exe': [1]}));
        await expectLater(
          service().extractAndVerifyZip(zip),
          throwsA(predicate((e) => '$e'.contains('incomplete'))),
        );
        expect(updateDirs(), isEmpty);
      });

      test('a corrupt archive is rejected and removed', () async {
        final zip = downloaded(utf8.encode('this is not a zip'));
        await expectLater(service().extractAndVerifyZip(zip), throwsA(anything));
        expect(updateDirs(), isEmpty);
      });
    });

    group('discardExtractedUpdate', () {
      UpdateService service() => UpdateService(tempRoot: root, client: _noNetwork());

      test('takes the whole attempt with it, from the extracted build', () async {
        // main.dart's own step after extraction failing (the download queue
        // could not be saved) used to leave ~300 MB for the sweep a day later.
        final zip = downloaded(_zipOf({for (final f in _completeBuild) f: [1]}));
        final appRoot = await service().extractAndVerifyZip(zip);
        expect(updateDirs(), hasLength(1));

        await service().discardExtractedUpdate(appRoot);

        expect(updateDirs(), isEmpty);
      });

      test('leaves alone a directory that is not one of its own', () async {
        final elsewhere = Directory(p.join(root.path, 'not_an_update', 'app'))
          ..createSync(recursive: true);

        await service().discardExtractedUpdate(elsewhere);

        expect(elsewhere.existsSync(), isTrue);
      });
    });

    group('sweepStaleUpdateDirs', () {
      test('removes old update directories and nothing else', () async {
        final stale = Directory(p.join(root.path, '${UpdateService.updateDirPrefix}old'))
          ..createSync();
        File(p.join(stale.path, 'extracted', 'streamlink_gui.exe'))
          ..createSync(recursive: true)
          ..writeAsBytesSync([1]);
        final unrelated = Directory(p.join(root.path, 'someone_elses_dir'))..createSync();
        final sameNameFile =
            File(p.join(root.path, '${UpdateService.updateDirPrefix}file'))..writeAsStringSync('x');

        await UpdateService(tempRoot: root).sweepStaleUpdateDirs(olderThan: Duration.zero);

        expect(stale.existsSync(), isFalse);
        expect(unrelated.existsSync(), isTrue);
        expect(sameNameFile.existsSync(), isTrue);
      });

      test('keeps a recent one at the default age', () async {
        final fresh = Directory(p.join(root.path, '${UpdateService.updateDirPrefix}new'))
          ..createSync();
        await UpdateService(tempRoot: root).sweepStaleUpdateDirs();
        expect(fresh.existsSync(), isTrue);
      });

      test('never removes the directory of a download still in progress', () async {
        // A directory's timestamp does not move while the file inside it
        // grows, so a slow download would otherwise look abandoned.
        final body = StreamController<List<int>>();
        final service = UpdateService(
          tempRoot: root,
          client: MockClient.streaming((request, _) async =>
              http.StreamedResponse(body.stream, 200, contentLength: 2)),
        );
        final pending = service.downloadUpdate(_zipUrl, null);
        body.add([1]);
        await pumpEventQueue();
        expect(updateDirs(), hasLength(1));

        await service.sweepStaleUpdateDirs(olderThan: Duration.zero);
        expect(updateDirs(), hasLength(1));

        body.add([2]);
        await body.close();
        final zip = await pending;
        expect(zip.readAsBytesSync(), [1, 2]);
      });
    });
  });
}
