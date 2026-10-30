import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/twitch_channel.dart';
import '../../services/automation_service.dart';
import '../../services/player_service.dart';
import '../../services/twitch_api_service.dart';
import '../../state/channels_controller.dart';
import 'app_dialogs.dart';
import 'vod_actions.dart' show ShowMessage;

/// What a channel's own buttons do: add it to the favourites, star or unstar
/// it, and watch it live.
///
/// Moved out of the main screen as it was. The screen keeps what is on
/// screen - the open channel, the search field, the Adding spinner - and is
/// told through [select], [setAdding], [clearSearch] and [removed].
class ChannelActions {
  ChannelActions({
    required ChannelsController channels,
    required List<TwitchChannel> favorites,
    required AutomationService automation,
    required PlayerService player,
    required TwitchApiService api,
    required AppSettings Function() settings,
    required BuildContext Function() context,
    required bool Function() mounted,
    required ShowMessage showMessage,
    required Future<void> Function() save,
    required void Function(TwitchChannel channel) select,
    required void Function(bool adding) setAdding,
    required VoidCallback clearSearch,
    required void Function(String cleanName) removed,
    required VoidCallback changed,
  })  : _channels = channels,
        _favorites = favorites,
        _automation = automation,
        _player = player,
        _api = api,
        _settings = settings,
        _context = context,
        _mounted = mounted,
        _showMessage = showMessage,
        _save = save,
        _select = select,
        _setAdding = setAdding,
        _clearSearch = clearSearch,
        _removed = removed,
        _changed = changed;

  final ChannelsController _channels;

  /// The favourites, the list the poll and the config share.
  final List<TwitchChannel> _favorites;
  final AutomationService _automation;
  final PlayerService _player;
  final TwitchApiService _api;
  final AppSettings Function() _settings;

  /// The screen's, for the confirm; read only while [_mounted].
  final BuildContext Function() _context;
  final bool Function() _mounted;
  final ShowMessage _showMessage;

  /// Writes the config now.
  final Future<void> Function() _save;

  /// Opens a channel, through the screen's one selection path.
  final void Function(TwitchChannel channel) _select;

  /// The sidebar's Adding spinner.
  final void Function(bool adding) _setAdding;
  final VoidCallback _clearSearch;

  /// [cleanName] left the favourites: the screen closes it if it was open.
  final void Function(String cleanName) _removed;

  /// Something on screen changed.
  final VoidCallback _changed;

  /// Adds [name] to the favourites, once Twitch knows it, and opens it.
  Future<void> add(String name) async {
    final cleanName = name.toLowerCase().trim();
    // Refused before the spinner shows: nothing Twitch could say about a name
    // that cannot be a login is more useful than saying so at once.
    switch (_channels.checkAdd(cleanName)) {
      case AddCheck.empty:
      case AddCheck.pending:
        // A second Enter while the first lookup runs; it is on its way.
        return;
      case AddCheck.invalidName:
        _showMessage('"$cleanName" is not a valid Twitch username.', isError: true);
        return;
      case AddCheck.duplicate:
        _showMessage('Channel "$cleanName" is already in your list.', isError: true);
        return;
      case AddCheck.ok:
        break;
    }

    _setAdding(true);
    final outcome = await _channels.addFavorite(cleanName);
    if (!_mounted()) return;
    _setAdding(_channels.hasPendingAdds);

    final added = outcome.channel;
    if (added == null) {
      _showMessage(
          outcome.check == AddCheck.duplicate
              ? 'Channel "$cleanName" is already in your list.'
              : 'Failed to add channel: ${outcome.error}',
          isError: true);
      return;
    }

    _clearSearch();
    // Opened through the one selection path, so the grid loads this channel's
    // VODs rather than going on showing the previous channel's under its
    // header.
    _select(added);

    await _save();
    if (!_mounted()) return;
    _showMessage('Channel "$cleanName" added successfully!', isError: false);
  }

  /// Records a channel that is ALREADY live at the moment it joins the list.
  ///
  /// The went-live check fires for any live channel missing from this set, so
  /// starring or adding someone mid-broadcast produced an "is now LIVE!"
  /// notification up to a minute later for a stream the user had just been
  /// looking at - and, with auto-play configured, could launch it unasked.
  void _seedLiveTracking(TwitchChannel channel) {
    if (!channel.isLive) return;
    _channels.liveFavorites.add(channel.username.toLowerCase().trim());
  }

  /// Stars [channel], or unstars it - after asking, when that discards its
  /// automation.
  Future<void> toggleFavorite(TwitchChannel channel) async {
    final cleanName = channel.username.toLowerCase().trim();
    final isFavorite = _favorites.any((c) => c.username == cleanName);

    if (isFavorite) {
      // Removing a favorite also discards its automation configuration, which
      // there is no way to undo. Confirm when there is something to lose - a
      // single mis-click on the star used to silently destroy it.
      final existing = _favorites.firstWhere((c) => c.username == cleanName);
      if (existing.autoPlayLive || existing.autoDownloadVods) {
        final confirmed = await confirmRemoveFavorite(_context(),
            name: channel.username, existing: existing);
        if (confirmed != true) return;
      }

      _favorites.removeWhere((c) => c.username == cleanName);
      // Drop tracking state for the removed channel so it cannot resurface as
      // a stale "went live" notification or auto-play session later.
      _channels.liveFavorites.remove(cleanName);
      _automation.forgetChannel(cleanName);
      _removed(cleanName);
      await _save();
      _showMessage('Removed "${channel.username}" from Favorites.', isError: false);
    } else {
      final newFav = TwitchChannel(username: cleanName);
      newFav.avatarUrl = channel.avatarUrl;
      newFav.isLive = channel.isLive;
      newFav.uptime = channel.uptime;
      newFav.viewerCount = channel.viewerCount;
      newFav.game = channel.game;
      newFav.streamTitle = channel.streamTitle;

      _favorites.add(newFav);
      _changed();
      _seedLiveTracking(newFav);
      await _save();
      _showMessage('Added "${channel.username}" to Favorites.', isError: false);

      _api.fetchChannelStats(newFav, _settings()).then((_) {
        if (_mounted()) _changed();
      });
    }
  }

  /// Launches [channel]'s live stream using ITS OWN metadata. The old
  /// double-tap path received only a username and looked title/game/live up
  /// on the open channel, so double-tapping a non-selected row launched with
  /// a different channel's metadata.
  void watch(TwitchChannel channel) {
    if (_player.runningChannels
        .contains(channel.username.toLowerCase().trim())) {
      return;
    }
    _player.launchStreamlinkForLive(
      channel.username,
      channel.isLive,
      channel.streamTitle,
      channel.game,
      _settings(),
    );
  }

  /// The tray's Watch for [username]. Resolves the channel by name AT CLICK
  /// TIME: menu items can outlive a poll cycle, and capturing the channel
  /// object would launch with stale title/game metadata (or a channel that
  /// just went offline).
  void watchFromTray(String username) {
    final index = _favorites.indexWhere((c) => c.username == username);
    if (index == -1) return;
    final channel = _favorites[index];
    if (!channel.isLive) return;
    watch(channel);
  }
}
