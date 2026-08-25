import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../services/player_service.dart';
import '../services/twitch_api_service.dart';
import '../theme/neu_theme.dart';
import 'neumorphic/neu_led_indicator.dart';
import '../theme/theme_notifier.dart';
import 'neumorphic/neu_switch.dart';
import 'shell/neu_dialog.dart';

/// First-run setup: player, download folder, optional Twitch token, tray
/// behavior. Fully skippable; everything it configures lives in Settings too.
///
/// Returns the configured [AppSettings] (a SINGLE copyWith so no concurrent
/// field is lost), or null when skipped/dismissed. Either way the caller
/// marks onboarding complete - the wizard never comes back.
class OnboardingWizard {
  static Future<AppSettings?> show(BuildContext context, {required AppSettings settings}) {
    // Not dismissible: a stray click on the scrim would silently skip setup
    // for good, since the caller marks onboarding complete either way.
    return NeuDialog.show<AppSettings>(
      context,
      dismissible: false,
      builder: (context) => _OnboardingDialog(settings: settings),
    );
  }
}

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog({required this.settings});

  final AppSettings settings;

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final PageController _pageController = PageController();
  int _step = 0;
  static const int _stepCount = 5;

  late final Map<String, bool> _detectedPlayers;
  String _playerType = 'default';
  String _downloadFolder = '';
  final TextEditingController _tokenController = TextEditingController();
  bool _isTestingToken = false;
  TokenValidationResult? _tokenResult;
  bool _launchAtStartup = false;
  bool _startMinimized = false;

  @override
  void initState() {
    super.initState();
    _detectedPlayers = PlayerService().detectInstalledPlayers(widget.settings);
    _playerType = widget.settings.playerType;
    _downloadFolder = widget.settings.vodDownloadFolder;
    _launchAtStartup = widget.settings.launchAtStartup;
    _startMinimized = widget.settings.startMinimized;
  }

  @override
  void dispose() {
    _pageController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  bool get _isDark => themeNotifier.isDarkTheme;

  void _goTo(int step) {
    setState(() => _step = step);
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  void _finish() {
    Navigator.of(context).pop(widget.settings.copyWith(
      playerType: _playerType,
      vodDownloadFolder: _downloadFolder.trim(),
      twitchOauthToken: _tokenController.text.trim().isEmpty
          ? widget.settings.twitchOauthToken
          : _tokenController.text.trim().replaceFirst('oauth:', ''),
      launchAtStartup: _launchAtStartup,
      startMinimized: _startMinimized,
      onboardingCompleted: true,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Esc/back = skip with defaults; the caller still marks onboarding done.
    final isLast = _step == _stepCount - 1;
    return PopScope(
      canPop: true,
      child: NeuDialog(
        title: 'Set up Twitch Streamlink GUI',
        subtitle: 'Step ${_step + 1} of $_stepCount',
        icon: Icons.auto_awesome,
        width: 560,
        maxHeight: 560,
        scrollable: false,
        // Expanded, not a hard 460: PageView has no intrinsic height, and the
        // old fixed 540x460 could not fit the 380x500 window the app allows.
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _welcomeStep(theme),
                  _playerStep(theme),
                  _folderStep(theme),
                  _tokenStep(theme),
                  _trayStep(theme),
                ],
              ),
            ),
          ],
        ),
        // Progress and the way out both belong on the left: "Skip setup" was
        // previously in the title bar, which is where a close button lives, so
        // it read as "dismiss" rather than "continue without configuring".
        leadingActions: [
          // A row of lamp lenses, the active step lit: the reference
          // boards do step state exactly this way, and flat dots were the
          // one flat element on an otherwise decorated surface.
          for (var i = 0; i < _stepCount; i++)
            Container(
              margin: const EdgeInsets.only(right: NeuSpace.s6),
              child: NeuLedIndicator(
                size: NeuSpace.s8,
                isLive: i == _step,
                isPulsing: false,
                activeColor: theme.primaryColor,
              ),
            ),
          const SizedBox(width: NeuSpace.s8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: Text('Skip setup',
                style:
                    NeuType.caption(themeNotifier.isDarkTheme, color: NeuTheme.subtext(_isDark))),
          ),
        ],
        actions: [
          if (_step > 0)
            NeuDialogAction.secondary('Back', () => _goTo(_step - 1)),
          NeuDialogAction.primary(
            isLast ? 'Finish' : 'Next',
            () => isLast ? _finish() : _goTo(_step + 1),
          ),
        ],
      ),
    );
  }

  Widget _stepScaffold({required String title, required List<Widget> children}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
          horizontal: NeuSpace.s4, vertical: NeuSpace.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: NeuType.headingMd(_isDark)),
          const SizedBox(height: NeuSpace.s12),
          ...children,
        ],
      ),
    );
  }

  Widget _bullet(IconData icon, String text, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NeuSpace.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: themeNotifier.accentInk),
          const SizedBox(width: NeuSpace.s8),
          Expanded(child: Text(text, style: NeuType.bodySm(_isDark))),
        ],
      ),
    );
  }

  Widget _welcomeStep(ThemeData theme) {
    return _stepScaffold(
      title: 'Watch Twitch your way',
      children: [
        _bullet(Icons.live_tv, 'Launch live streams in a real media player (VLC, MPV, MPC-HC) through Streamlink - no browser, no ads overlay.', theme),
        _bullet(Icons.star, 'Track favorite channels, get notified when they go live, and auto-play or auto-download their streams.', theme),
        _bullet(Icons.download, 'Download past broadcasts with yt-dlp and manage them in the built-in Library.', theme),
        _bullet(Icons.speed, 'The app lives in your tray and keeps monitoring in the background.', theme),
        const SizedBox(height: NeuSpace.s6),
        Text('The next steps take about a minute. Everything can be changed later in Settings.',
            style: NeuType.caption(_isDark)),
      ],
    );
  }

  Widget _playerStep(ThemeData theme) {
    final options = <(String, String, bool?)>[
      ('default', 'Default system player', null),
      ('vlc', 'VLC Media Player', _detectedPlayers['vlc'] == true),
      ('mpv', 'MPV Player', _detectedPlayers['mpv'] == true),
      ('mpc-hc', 'MPC-HC Player', _detectedPlayers['mpc-hc'] == true),
    ];
    return _stepScaffold(
      title: 'Pick your media player',
      children: [
        for (final (value, label, detected) in options)
          Padding(
            padding: const EdgeInsets.only(bottom: NeuSpace.s6),
            child: InkWell(
              borderRadius: BorderRadius.circular(NeuRadius.r8),
              onTap: () => setState(() => _playerType = value),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
                decoration: _playerType == value
                    ? NeuTheme.sunkenDecoration(_isDark, radius: NeuRadius.r8,
                        border: Border.all(color: themeNotifier.accentInk, width: 1.5))
                    : NeuTheme.raisedDecoration(_isDark, radius: NeuRadius.r8),
                child: Row(
                  children: [
                    Icon(
                      _playerType == value
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 16,
                      color: _playerType == value
                          ? theme.primaryColor
                          : NeuTheme.subtext(_isDark),
                    ),
                    const SizedBox(width: NeuSpace.s8),
                    Expanded(child: Text(label, style: NeuType.bodySm(_isDark))),
                    if (detected != null)
                      Text(
                        detected ? 'Detected' : 'Not found',
                        style: NeuType.plate(themeNotifier.isDarkTheme, color: detected
                              ? NeuTheme.liveText(_isDark)
                              : NeuTheme.subtext(_isDark)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: NeuSpace.s6),
        Text('A custom player executable can be configured later under Settings > Player.',
            style: NeuType.caption(_isDark)),
      ],
    );
  }

  Widget _folderStep(ThemeData theme) {
    return _stepScaffold(
      title: 'Where should VOD downloads go?',
      children: [
        Text('Optional - only needed if you download past broadcasts. Each channel gets its own subfolder.',
            style: NeuType.caption(_isDark)),
        const SizedBox(height: NeuSpace.s12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
          decoration: NeuTheme.sunkenDecoration(_isDark, radius: NeuRadius.r8),
          child: Row(
            children: [
              Icon(Icons.folder, size: 16, color: NeuTheme.subtext(_isDark)),
              const SizedBox(width: NeuSpace.s8),
              Expanded(
                child: Text(
                  _downloadFolder.trim().isEmpty
                      ? 'No folder selected yet'
                      : _downloadFolder,
                  style: NeuType.bodySm(_isDark),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: NeuSpace.s8),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor),
          onPressed: () async {
            final path = await FilePicker.platform.getDirectoryPath();
            if (path != null && path.isNotEmpty) {
              setState(() => _downloadFolder = path);
            }
          },
          icon: Icon(Icons.folder_open, size: 16, color: themeNotifier.onPrimaryColor),
          label: Text('Browse',
              style: TextStyle(
                  color: themeNotifier.onPrimaryColor, fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }

  Widget _tokenStep(ThemeData theme) {
    return _stepScaffold(
      title: 'Connect Twitch (optional)',
      children: [
        Text(
          'Pasting an OAuth token unlocks your followed channels list, VOD browsing, subscriber streams and ad-free playback. You can paste one from any token tool (Settings has a guide), or skip this entirely.',
          style: NeuType.caption(_isDark),
        ),
        const SizedBox(height: NeuSpace.s12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _tokenController,
                obscureText: true,
                style: NeuType.bodySm(_isDark),
                decoration: const InputDecoration(
                  hintText: 'oauth:xxxxxxxxxxxx or raw token',
                  contentPadding: EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
                ),
              ),
            ),
            const SizedBox(width: NeuSpace.s8),
            SizedBox(
              height: 38,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: theme.primaryColor),
                onPressed: _isTestingToken
                    ? null
                    : () async {
                        setState(() {
                          _isTestingToken = true;
                          _tokenResult = null;
                        });
                        final result = await TwitchApiService()
                            .validateOAuthToken(_tokenController.text);
                        if (!mounted) return;
                        setState(() {
                          _isTestingToken = false;
                          _tokenResult = result;
                        });
                      },
                child: _isTestingToken
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: themeNotifier.onPrimaryColor),
                      )
                    : Text('Test',
                        style: NeuType.label(themeNotifier.isDarkTheme, color: themeNotifier.onPrimaryColor)),
              ),
            ),
          ],
        ),
        if (_tokenResult != null) ...[
          const SizedBox(height: NeuSpace.s8),
          Row(
            children: [
              Icon(
                _tokenResult!.isValid ? Icons.check_circle : Icons.error,
                size: 14,
                color: _tokenResult!.isValid
                    ? NeuTheme.liveText(_isDark)
                    : NeuTheme.dangerText(_isDark),
              ),
              const SizedBox(width: NeuSpace.s6),
              Expanded(
                child: Text(
                  _tokenResult!.message,
                  style: NeuType.captionStrong(themeNotifier.isDarkTheme, color: _tokenResult!.isValid
                        ? NeuTheme.liveText(_isDark)
                        : NeuTheme.dangerText(_isDark)),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _trayStep(ThemeData theme) {
    return _stepScaffold(
      title: 'Background behavior',
      children: [
        Text(
          'Closing the window keeps the app running in the system tray so live notifications and automation keep working. Right-click the tray icon to exit for real. Both behaviors are configurable in Settings.',
          style: NeuType.caption(_isDark),
        ),
        const SizedBox(height: NeuSpace.s12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text('Launch at Windows startup (minimized to tray)',
                  style: NeuType.bodySm(_isDark)),
            ),
            NeuSwitch(
              value: _launchAtStartup,
              activeColor: theme.primaryColor,
              onChanged: (val) => setState(() => _launchAtStartup = val),
            ),
          ],
        ),
        const SizedBox(height: NeuSpace.s8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text('Start minimized to tray on manual launch',
                  style: NeuType.bodySm(_isDark)),
            ),
            NeuSwitch(
              value: _startMinimized,
              activeColor: theme.primaryColor,
              onChanged: (val) => setState(() => _startMinimized = val),
            ),
          ],
        ),
        const SizedBox(height: NeuSpace.s12),
        Text('All set - press Finish to start. Add channels with the sidebar search (Ctrl+F).',
            style: NeuType.bodySm(_isDark)),
      ],
    );
  }
}
