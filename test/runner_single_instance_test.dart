import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Which launches the runner counts as one instance
/// (windows/runner/single_instance.cpp).
///
/// The runner's C++ has no tests of its own, and what this guards was found
/// with a probe launched through a junction, which no test here can make;
/// so the source is read, as the other runner checks do.
void main() {
  final source = File('windows/runner/single_instance.cpp')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  String body(String signature) {
    final start = source.indexOf(signature);
    expect(start, isNonNegative, reason: signature);
    return source.substring(start, source.indexOf('\n}\n', start));
  }

  group("a portable copy's scope is its real folder", () {
    // Keyed by the folder as GetModuleFileNameW spelled it, one portable
    // folder reached through a junction, a subst or mapped drive, or its UNC
    // path was two scopes: the second launch did not see the first one's
    // mutex, and two instances wrote one channels_config.json. Dart resolves
    // the same spellings to one folder (Platform.resolvedExecutable), so the
    // two halves disagreed about whether they were the same copy.
    test('the executable is resolved before its folder is taken', () {
      final directory = body('std::wstring ExecutableDirectory(');
      final resolve =
          directory.indexOf('FinalPath(std::wstring(path, length))');
      expect(resolve, isNonNegative,
          reason: 'the module path, not its folder: a link to the exe alone '
              'reads portable.txt where Dart reads it');
      expect(resolve, lessThan(directory.indexOf('find_last_of(')));
      expect(resolve, lessThan(directory.indexOf('towlower')));
    });

    test('resolved the way Dart resolves resolvedExecutable', () {
      final resolve = body('std::wstring FinalPath(');
      expect(resolve, contains('CreateFileW('));
      expect(resolve, contains('FILE_FLAG_BACKUP_SEMANTICS'));
      expect(resolve, contains('GetFinalPathNameByHandleW('));
      expect(resolve, contains('FILE_NAME_NORMALIZED | VOLUME_NAME_DOS'));
      expect(resolve, contains('::CloseHandle(file);'));
      // The plain spelling back, so a path with no alias in it keeps the
      // scope it had, and a UNC path is still one.
      expect(resolve, contains(r'L"\\\\?\\UNC\\"'));
      expect(resolve, contains(r'L"\\\\?\\"'));
      // A path that cannot be opened is keyed as spelled, as before.
      expect(RegExp(r'return path;').allMatches(resolve).length, 2);
    });

    test('both the portable check and the scope use that folder', () {
      final scope = body('const Scope& CurrentScope(');
      expect(scope, contains('const std::wstring directory = ExecutableDirectory();'));
      expect(scope, contains('IsPortable(directory)'));
      expect(scope, contains('HashDirectory(directory)'));
    });
  });
}
