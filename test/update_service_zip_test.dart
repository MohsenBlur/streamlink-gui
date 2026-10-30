import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:streamlink_gui/services/update_service.dart';

/// The updater's zip extraction, end to end through the archive package.
///
/// Every archive here is built with the package's own ZipEncoder and goes
/// through the same steps as a real update: downloaded, checked against a
/// SHA256SUMS, extracted. It pins the archive 4.x migration (audit I7): the
/// extracted build must be byte-for-byte the one that was packed, and an
/// entry that climbs out of the extraction directory must stop the update
/// before it writes anywhere else.
const _asset = 'streamlink-gui-windows.zip';
const _zipUrl = 'https://example.invalid/releases/download/v9.9.9/$_asset';
const _sumsUrl = 'https://example.invalid/releases/download/v9.9.9/SHA256SUMS';

/// The release zip's top folder (7z packs `./dist/<stage>`).
const _bundle = 'Streamlink GUI 9.9.9';

Uint8List _noise(int length, int seed) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

/// A complete build: everything the extractor insists on, plus contents
/// that exercise the codec - incompressible noise across several deflate
/// blocks, a highly compressible run, an empty file, a nested folder.
Map<String, Uint8List> _build() => {
      '$_bundle/streamlink_gui.exe': _noise(300 * 1024, 1),
      '$_bundle/updater.exe': _noise(40 * 1024, 2),
      '$_bundle/flutter_windows.dll': Uint8List(1024 * 1024)..fillRange(0, 4096, 7),
      '$_bundle/bin/bin/streamlink.exe': _noise(64 * 1024, 3),
      '$_bundle/bin/yt-dlp.exe': _noise(70 * 1024, 4),
      '$_bundle/bin/ffmpeg.exe': _noise(90 * 1024, 5),
      '$_bundle/data/flutter_assets/AssetManifest.bin': Uint8List.fromList([1, 2, 3]),
      '$_bundle/data/empty.txt': Uint8List(0),
    };

List<int> _zip(Map<String, Uint8List> files, {List<String> directories = const []}) {
  final archive = Archive();
  for (final dir in directories) {
    archive.addFile(ArchiveFile.directory(dir));
  }
  files.forEach((name, bytes) => archive.addFile(ArchiveFile.bytes(name, bytes)));
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('streamlink_gui_zip_test_');
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

  /// Serves [zipBytes] and a SHA256SUMS that matches it.
  UpdateService serving(List<int> zipBytes) {
    final sums = '${sha256.convert(zipBytes)}  $_asset\n';
    return UpdateService(
      tempRoot: root,
      client: MockClient.streaming((request, _) async {
        if (request.url.toString() == _zipUrl) {
          return http.StreamedResponse(Stream.value(zipBytes), 200,
              contentLength: zipBytes.length);
        }
        if (request.url.toString() == _sumsUrl) {
          final body = sums.codeUnits;
          return http.StreamedResponse(Stream.value(body), 200,
              contentLength: body.length);
        }
        return http.StreamedResponse(const Stream.empty(), 404);
      }),
    );
  }

  /// Download, verify, extract: the update flow up to the updater.
  Future<Directory> install(UpdateService service) async {
    final zip = await service.downloadUpdate(_zipUrl, null);
    await service.verifyChecksum(zip, _sumsUrl);
    return service.extractAndVerifyZip(zip);
  }

  test('a ZipEncoder archive extracts byte for byte', () async {
    final files = _build();
    final service = serving(
        _zip(files, directories: ['$_bundle/', '$_bundle/data/logs/']));

    final appRoot = await install(service);

    expect(p.basename(appRoot.path), _bundle,
        reason: 'the bundle folder is the staging directory');
    for (final entry in files.entries) {
      final relative = p.joinAll(p.posix.split(entry.key).skip(1));
      final file = File(p.join(appRoot.path, relative));
      expect(file.existsSync(), isTrue, reason: '${entry.key} was extracted');
      expect(file.readAsBytesSync(), entry.value,
          reason: '${entry.key} is byte-identical');
    }
    expect(Directory(p.join(appRoot.path, 'data', 'logs')).existsSync(), isTrue,
        reason: 'directory entries become directories');

    final written = appRoot
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.relative(f.path, from: appRoot.path))
        .toSet();
    expect(written, files.keys.map((k) => p.joinAll(p.posix.split(k).skip(1))).toSet(),
        reason: 'nothing more and nothing less');
    expect(File(p.join(appRoot.parent.parent.path, _asset)).existsSync(), isFalse,
        reason: 'the archive is deleted once extracted');
  });

  group('Zip Slip', () {
    // Names an attacker would use to write outside the extraction folder:
    // straight up, up after a legitimate prefix, and (on Windows) with
    // backslashes or an absolute drive path.
    final escapes = <String>[
      '../evil.txt',
      // Two levels up from extracted/ is the test's own temp root, which
      // outlives the refused attempt - so a write there would be seen.
      '../../evil.txt',
      '$_bundle/../../../evil.txt',
      if (Platform.isWindows) r'..\..\evil.txt',
      if (Platform.isWindows) 'C:/Windows/Temp/streamlink_gui_zip_test_evil.txt',
    ];

    for (final name in escapes) {
      test('"$name" is refused and nothing escapes', () async {
        final files = _build();
        // Last, so every legitimate file is written before it is reached:
        // the refusal must still take the whole attempt with it.
        files[name] = Uint8List.fromList('pwned'.codeUnits);
        final zipBytes = _zip(files);

        // The hostile name survived the round trip; otherwise this test
        // would prove nothing. (archive 4.x stores a backslash as '/', so
        // that case reaches the extractor as the forward-slash climb.)
        expect(ZipDecoder().decodeBytes(zipBytes).map((e) => e.name),
            contains(name.replaceAll(r'\', '/')));

        final service = serving(zipBytes);
        await expectLater(
          install(service),
          throwsA(predicate((e) => '$e'.contains('unsafe path'))),
        );

        expect(File(p.join(root.path, 'evil.txt')).existsSync(), isFalse);
        if (Platform.isWindows) {
          expect(
              File('C:/Windows/Temp/streamlink_gui_zip_test_evil.txt')
                  .existsSync(),
              isFalse);
        }
        expect(updateDirs(), isEmpty,
            reason: 'the refused attempt is removed whole');
      });
    }

    test('a name that only looks like climbing stays inside', () async {
      final files = _build();
      files['$_bundle/data/..notes'] = Uint8List.fromList([9]);
      final appRoot = await install(serving(_zip(files)));
      expect(File(p.join(appRoot.path, 'data', '..notes')).readAsBytesSync(),
          [9]);
    });
  });

  test('a truncated archive is refused and removed', () async {
    final zipBytes = _zip(_build());
    // Cut through the central directory, as a broken mirror would.
    final cut = zipBytes.sublist(0, zipBytes.length - 200);
    final zipDir = Directory(p.join(root.path, '${UpdateService.updateDirPrefix}cut'))
      ..createSync();
    final zip = File(p.join(zipDir.path, _asset))..writeAsBytesSync(cut);

    await expectLater(
        UpdateService(tempRoot: root).extractAndVerifyZip(zip), throwsA(anything));
    expect(updateDirs(), isEmpty);
  });
}
