import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/twitch_video.dart';
import 'library_entries.dart';

/// The Library screen: whether it is showing, its rows, and what their
/// buttons do.
///
/// Moved out of the main screen as it was. The rows are CACHED - built, with
/// a stat of every file, only when the Library opens, is refreshed or
/// changes; never in build(), because download-progress rebuilds would
/// otherwise stat every file per frame. Playing and deleting are the VOD
/// actions'; this decides when, and keeps the rows in step.
class LibraryController extends ChangeNotifier {
  LibraryController({
    required Map<String, String> Function() registry,
    required List<TwitchVideo> Function() recents,
    required Map<String, int> Function() localProgress,
    required Map<String, String> Function() channelNames,
    required String Function() downloadRoot,
    required VoidCallback rescan,
    required void Function(TwitchVideo video, String channel) play,
    required Future<void> Function(String vodId, String channel) deleteDownload,
    required Future<bool?> Function(String title) confirmDelete,
    required Future<void> Function(String vodId) forget,
    LibraryFileStat? Function(String path)? statFile,
  })  : _registry = registry,
        _recents = recents,
        _localProgress = localProgress,
        _channelNames = channelNames,
        _downloadRoot = downloadRoot,
        _rescan = rescan,
        _play = play,
        _deleteDownload = deleteDownload,
        _confirmDelete = confirmDelete,
        _forget = forget,
        _statFile = statFile ?? statOnDisk;

  final Map<String, String> Function() _registry;
  final List<TwitchVideo> Function() _recents;
  final Map<String, int> Function() _localProgress;

  /// This session's download bookkeeping: VOD id to channel.
  final Map<String, String> Function() _channelNames;
  final String Function() _downloadRoot;

  /// Brings the registry in step with the disk; it reports back through
  /// [refreshIfOpen] once it has.
  final VoidCallback _rescan;
  final void Function(TwitchVideo video, String channel) _play;
  final Future<void> Function(String vodId, String channel) _deleteDownload;
  final Future<bool?> Function(String title) _confirmDelete;
  final Future<void> Function(String vodId) _forget;
  final LibraryFileStat? Function(String path) _statFile;

  bool _isOpen = false;
  List<LibraryEntry> _entries = [];
  bool _disposed = false;

  /// The Library is what the screen shows.
  bool get isOpen => _isOpen;

  /// Its rows, as last built.
  List<LibraryEntry> get entries => _entries;

  /// The size and time of the file at [path], or null when there is none.
  static LibraryFileStat? statOnDisk(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final stat = file.statSync();
      return (size: stat.size, modified: stat.modified);
    } catch (_) {
      return null;
    }
  }

  /// Opens the Library with a fresh scan of the download registry.
  void open() {
    _rescan();
    refresh();
    _isOpen = true;
    _notify();
  }

  /// Leaves the Library for whatever was showing before it.
  ///
  /// The open channel is deliberately left alone by [open], so simply
  /// lowering the flag lands back on that channel's dashboard - or the
  /// welcome screen if no channel was selected. The state to return to was
  /// always there; what was missing was any way to ask for it.
  void close() {
    if (!_isOpen) return;
    _isOpen = false;
    _notify();
  }

  /// Rebuilds the cached rows (the only place file stats happen).
  void refresh() {
    _entries = buildLibraryEntries(
      registry: _registry(),
      recents: _recents(),
      localProgress: _localProgress(),
      channelNames: _channelNames(),
      downloadRoot: _downloadRoot(),
      statFile: _statFile,
    );
    _notify();
  }

  /// [refresh], when the rows are on screen: the registry or the history
  /// changed underneath them.
  void refreshIfOpen() {
    if (_isOpen) refresh();
  }

  /// The view's own Refresh: the disk, then the rows.
  void rescanAndRefresh() {
    _rescan();
    refresh();
  }

  void play(LibraryEntry entry) {
    // Registry-only entries carry no Twitch metadata; a minimal synthesized
    // video is enough for a play's local-file path.
    final video = entry.video ??
        TwitchVideo(
          id: entry.vodId,
          title: entry.title,
          duration: '',
          thumbnailUrl: '',
          viewCount: '0',
          publishedAt: entry.modified ?? DateTime.now(),
        );
    // '' resolves to the download root itself, which is exactly where a file
    // with no channel folder lives - that is the only way channel is null for
    // a downloaded entry.
    _play(video, entry.channel ?? '');
  }

  Future<void> delete(LibraryEntry entry) async {
    final bool? confirmed = await _confirmDelete(entry.title);
    // != true, not == false: a dismissed dialog returns null, and null must
    // never mean "yes, delete it".
    if (confirmed != true) return;
    await _deleteDownload(entry.vodId, entry.channel ?? '');
    refresh();
  }

  /// Takes [entry] out of the watch history (WatchHistoryController.forget),
  /// position and all.
  Future<void> removeFromHistory(LibraryEntry entry) async {
    await _forget(entry.vodId);
    if (_disposed) return;
    refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
