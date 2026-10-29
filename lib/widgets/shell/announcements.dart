import 'dart:async';

import '../../models/app_settings.dart';
import '../../models/twitch_channel.dart';
import '../../models/twitch_video.dart';
import '../../services/automation_service.dart';
import '../../services/desktop_shell.dart';
import '../../services/player_service.dart';
import '../../state/channels_controller.dart';

/// The toasts that say a channel went live or has a new VOD, and what a
/// click on one does: the window comes back and the channel opens - and for
/// one that went live, its stream starts.
///
/// Moved out of the main screen as it was. The screen keeps what is on
/// screen - the open channel, the Library, the window - and reads them out
/// through [openChannel], [libraryOpen] and [windowVisible]; [select] is its
/// one path for opening a channel.
class Announcements {
  Announcements({
    required AppNotifications notifications,
    required List<TwitchChannel> favorites,
    required AutomationService automation,
    required PlayerService player,
    required AppSettings Function() settings,
    required bool Function() mounted,
    required bool Function() windowVisible,
    required bool Function() libraryOpen,
    required TwitchChannel? Function() openChannel,
    required Future<void> Function() showWindow,
    required void Function(TwitchChannel channel) select,
  })  : _notifications = notifications,
        _favorites = favorites,
        _automation = automation,
        _player = player,
        _settings = settings,
        _mounted = mounted,
        _windowVisible = windowVisible,
        _libraryOpen = libraryOpen,
        _openChannel = openChannel,
        _showWindow = showWindow,
        _select = select;

  final AppNotifications _notifications;

  /// The favourites, the list the poll and the config share.
  final List<TwitchChannel> _favorites;
  final AutomationService _automation;
  final PlayerService _player;
  final AppSettings Function() _settings;
  final bool Function() _mounted;
  final bool Function() _windowVisible;
  final bool Function() _libraryOpen;
  final TwitchChannel? Function() _openChannel;
  final Future<void> Function() _showWindow;
  final void Function(TwitchChannel channel) _select;

  /// The went-live toasts for one pass, one after another, over the pass's
  /// own lists. This used to await each toast inside a loop over the
  /// favourites, and starring a channel during that await threw
  /// ConcurrentModificationError and skipped the rest of the pass.
  Future<void> wentLive(ChannelsPass pass) async {
    final settings = _settings();
    final channels = <TwitchChannel>[
      if (settings.notifyWentLive) ...pass.favoritesWentLive,
      if (settings.notifyFollowedWentLive) ...pass.followedWentLive,
    ];
    for (final channel in channels) {
      try {
        final gameText = channel.game ?? 'Twitch';
        final titleText = channel.streamTitle ?? 'Streaming Live!';
        await _notifications.show(AppNotification(
          title: '${channel.username} is now LIVE!',
          body: 'Playing $gameText\n$titleText',
          onClick: () async {
            await _showWindow();
            if (!_mounted()) return;
            _select(channel);

            _player.launchStreamlinkForLive(
              channel.username,
              channel.isLive,
              channel.streamTitle,
              channel.game,
              _settings(),
            );
          },
        ));
      } catch (e) {
        print('[Favorites Notification] Error displaying desktop toast: $e');
      }
    }
  }

  /// A channel's archive gained a VOD (see VodBrowserController.onNewVods).
  /// Announced for favourites only, and not for the open channel while the
  /// window is on screen: the grid shows it arriving. Nor for a VOD the
  /// auto-download pass takes, which has a toast of its own.
  void newVods(TwitchChannel channel, List<TwitchVideo> vods,
      List<TwitchVideo> firstPage) {
    if (!_mounted() || !_settings().notifyNewVod || vods.isEmpty) return;
    final name = channel.username.toLowerCase().trim();
    final index = _favorites.indexWhere((c) => c.username == name);
    if (index == -1) return;
    if (_windowVisible() &&
        !_libraryOpen() &&
        _openChannel()?.username == name) {
      return;
    }
    final news =
        _automation.newVodsToAnnounce(_favorites[index], vods, firstPage);
    if (news.isEmpty) return;
    unawaited(_announceNewVods(name, news));
  }

  Future<void> _announceNewVods(String name, List<TwitchVideo> vods) async {
    try {
      final more = vods.length - 1;
      await _notifications.show(AppNotification(
        title: 'New VOD from $name',
        body: more > 0 ? '${vods.first.title}\n+$more more' : vods.first.title,
        onClick: () async {
          await _showWindow();
          if (!_mounted()) return;
          final index = _favorites.indexWhere((c) => c.username == name);
          if (index != -1) _select(_favorites[index]);
        },
      ));
    } catch (e) {
      print('[New VOD Notification] Error displaying desktop toast: $e');
    }
  }
}
