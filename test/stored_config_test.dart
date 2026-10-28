import 'package:flutter_test/flutter_test.dart';
import 'package:streamlink_gui/state/stored_config.dart';

/// The first load's reading of channels_config.json. Each rule here was
/// learnt from a config that lost data: a part that cannot be read is left
/// out, and never takes the rest with it.
void main() {
  test('a malformed channel is skipped, not the list', () {
    final stored = StoredConfig.parse({
      'channels': [
        {'username': 'alpha'},
        {'name': 'no username'},
        42,
        '',
        null,
        'Beta',
      ],
    });
    expect([for (final c in stored.channels) c.username], ['alpha', 'beta'],
        reason: 'a bare name is the oldest config format');
    expect(stored.skippedChannels, 3, reason: 'a null entry is not counted');
  });

  test('settings are read field by field, a bad one falling back alone', () {
    final stored = StoredConfig.parse({
      'channels': [
        {'username': 'alpha'},
      ],
      'settings': {'max_recently_watched': 'many', 'is_dark_theme': false},
    });
    expect(stored.settingsError, isNull);
    expect(stored.settings?.maxRecentlyWatched, 8);
    expect(stored.settings?.isDarkTheme, isFalse);
    expect(stored.channels, hasLength(1));
  });

  test('watch positions keep every usable value', () {
    final stored = StoredConfig.parse({
      'local_vods_progress': {
        'a': 120,
        'b': 61.9,
        'c': '300',
        'd': 'later',
        'e': null,
      },
    });
    expect(stored.localProgress, {'a': 120, 'b': 61, 'c': 300});
  });

  test('the download registry keeps every path it has', () {
    final stored = StoredConfig.parse({
      'downloaded_vods': {'v1': r'D:\VODs\a.mp4', 'v2': null, 3: 'x.mp4'},
    });
    expect(stored.registry, {'v1': r'D:\VODs\a.mp4', '3': 'x.mp4'});
  });

  test('the download history keeps every usable time', () {
    final stored = StoredConfig.parse({
      'download_history': {'1': 1000, '2': 2000.5, '3': '3000', '4': 'soon'},
    });
    expect(stored.downloadHistory, {'1': 1000, '2': 2000, '3': 3000});
  });

  test('a part the file does not have is null, so memory stands', () {
    final stored = StoredConfig.parse({'channels': 'nope'});
    expect(stored.channels, isEmpty);
    expect(stored.skippedChannels, 0);
    expect(stored.settings, isNull);
    expect(stored.settingsError, isNull);
    expect(stored.localProgress, isNull);
    expect(stored.registry, isNull);
    expect(stored.downloadHistory, isNull,
        reason: 'a config from before it existed, which seeds it');
  });
}
