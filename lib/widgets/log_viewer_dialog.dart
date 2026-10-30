import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/log_store.dart';
import '../state/log_line_kind.dart';
import '../theme/neu_theme.dart';
import 'horizontal_mouse_scrollable.dart';
import 'neumorphic/neu_led_indicator.dart';
import '../theme/theme_notifier.dart';
import '../utils/time_utils.dart';
import 'shell/neu_dialog.dart';

/// On-demand process logs.
///
/// Replaces the permanent console drawer: logs matter only when something
/// went wrong, so they live behind a "View log" action on failures and a
/// Settings entry rather than occupying the bottom of every screen.
class LogViewerDialog {
  static Future<void> show(
    BuildContext context, {
    required LogNotifier logs,
    String? initialKey,
  }) {
    // Dismissible: it is read-only, and nothing is staged or in flight.
    return NeuDialog.show<void>(
      context,
      dismissible: true,
      builder: (context) =>
          _LogViewerDialog(logs: logs, initialKey: initialKey),
    );
  }
}

class _LogViewerDialog extends StatefulWidget {
  const _LogViewerDialog({required this.logs, this.initialKey});

  final LogNotifier logs;
  final String? initialKey;

  @override
  State<_LogViewerDialog> createState() => _LogViewerDialogState();
}

class _LogViewerDialogState extends State<_LogViewerDialog> {
  /// Below this content width the session list moves above the log. At 560
  /// the side-by-side log still gets ~340px; below it, it loses more to the
  /// fixed column than a strip costs in height.
  static const double _sideBySideMinWidth = 560;
  static const double _sessionColumnWidth = 210;

  /// Fixed, so a session's offset in the strip is known without measuring.
  static const double _stripTileWidth = 180;

  final ScrollController _scroll = ScrollController();

  /// The narrow layout's session strip.
  final ScrollController _sessionStrip = ScrollController();
  String? _selected;

  /// Set when the requested session had already been evicted — better to say
  /// so than to silently show a different log than the one asked for.
  bool _requestedGone = false;

  @override
  void initState() {
    super.initState();
    final sessions = widget.logs.sessions;
    final requested = widget.initialKey;
    if (requested != null && widget.logs.session(requested) != null) {
      _selected = requested;
    } else {
      _requestedGone = requested != null;
      _selected = sessions.isNotEmpty ? sessions.first.key : null;
    }
    widget.logs.addListener(_onLogs);
  }

  /// Whether the last layout was the narrow one, with the session strip.
  bool _stripShown = false;

  /// Brings the selected session into view in the narrow layout's strip.
  /// "View log" on a failure can name an older session, and the strip shows
  /// newest first - without this the selected tile could open off to the
  /// right, with nothing saying which log is on screen.
  ///
  /// Run each time the strip appears, not only when the dialog opens: a
  /// strip built by a resize from wide to narrow starts scrolled to the left
  /// as well, whatever was selected in the column before.
  void _revealSelected() {
    if (!mounted || !_sessionStrip.hasClients) return;
    final index =
        widget.logs.sessions.indexWhere((s) => s.key == _selected);
    if (index <= 0) return;
    final position = _sessionStrip.position;
    _sessionStrip.jumpTo((index * (_stripTileWidth + NeuSpace.s8))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble());
  }

  @override
  void dispose() {
    widget.logs.removeListener(_onLogs);
    _scroll.dispose();
    _sessionStrip.dispose();
    super.dispose();
  }

  void _onLogs() {
    if (mounted) setState(() {});
  }

  /// Follows the tail only when the reader is already near it, so scrolling
  /// up to read something does not fight the incoming output.
  void _followTail() {
    if (!_scroll.hasClients) return;
    final pinned = _scroll.position.maxScrollExtent - _scroll.offset < 80;
    if (!pinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// Log-line ink, resolved against the **screen**, not the surface.
  ///
  /// Every one of these used to be a colour calibrated against a panel, drawn
  /// on a near-black terminal. In the dark theme that was survivable by luck -
  /// both grounds are dark, so inks meant for one worked on the other. On a
  /// light look with a dark readout (the removed Broadcast rack) it was not:
  /// `text(false)` and `screen` were both dark and the plain lines measured
  /// 1.08:1. The two hand-picked hexes are the source colours the walk starts
  /// from, and it only moves them if they do not already clear the bar.
  Color _colorFor(LogLineKind kind, bool isDark, Color accent) {
    Color onScreen(Color c) => NeuTheme.inkOnScreen(c, isDark);
    switch (kind) {
      case LogLineKind.error:
        return onScreen(NeuTheme.danger);
      case LogLineKind.system:
        return onScreen(
            isDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1));
      case LogLineKind.streamlink:
        return NeuTheme.accentInkOnScreen(accent, isDark);
      case LogLineKind.cliInfo:
        return onScreen(
            isDark ? const Color(0xFF10B981) : const Color(0xFF047857));
      case LogLineKind.download:
        return onScreen(NeuTheme.live);
      case LogLineKind.plain:
        return NeuTheme.screenText(isDark);
    }
  }

  IconData _iconFor(LogSession s) {
    if (s.key.startsWith('dl-')) return Icons.download;
    if (s.key.startsWith('stream_')) return Icons.live_tv;
    return Icons.play_circle_outline;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = themeNotifier.isDarkTheme;
    final sessions = widget.logs.sessions;
    final lines = _selected == null ? const <String>[] : widget.logs.getLogs(_selected!);
    _followTail();

    // The widest dialog in the app: two panes side by side, so it asks for
    // 900 and NeuDialog clamps it to whatever the window can actually hold.
    return NeuDialog(
      title: 'Diagnostics log',
      subtitle: sessions.isEmpty
          ? null
          : '${sessions.length} ${sessions.length == 1 ? 'session' : 'sessions'} this run',
      icon: Icons.terminal,
      width: 900,
      maxHeight: 620,
      scrollable: false,
      // Copy and Clear act on the selected log rather than on the dialog, so
      // they sit at the far left of the footer, away from Close. They used to
      // be crammed into the title bar beside the heading.
      leadingActions: _selected == null
          ? const <Widget>[]
          : [
              TextButton.icon(
                onPressed: lines.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(
                            ClipboardData(text: lines.join('\n')));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Log copied')),
                        );
                      },
                icon: const Icon(Icons.copy_all, size: 14),
                label: const Text('Copy all', style: NeuType.captionMetrics),
              ),
              TextButton.icon(
                onPressed:
                    lines.isEmpty ? null : () => widget.logs.clear(_selected!),
                icon: const Icon(Icons.delete_outline, size: 14),
                label: const Text('Clear', style: NeuType.captionMetrics),
              ),
            ],
      content: sessions.isEmpty
          ? SizedBox(
              height: 200,
              child: Center(
                child: Text(
                  'Nothing has run yet this session.',
                  style: NeuType.body(isDark, color: NeuTheme.subtext(isDark)),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_requestedGone)
                  Padding(
                    padding: const EdgeInsets.only(bottom: NeuSpace.s8),
                    child: Text(
                      'That log is no longer available; showing the most recent instead.',
                      style: NeuType.caption(isDark, color: NeuTheme.dangerText(isDark)),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(builder: (context, constraints) {
                    // A fixed 210px session column beside the log only works
                    // when there is room for both. NeuDialog clamps the 900px
                    // request to the window, so at the 380px minimum the
                    // content is 292px wide and the log got ~70px - a few
                    // characters per line, in the dialog whose only job is
                    // showing those lines. Narrow, the sessions become a strip
                    // above a full-width log instead.
                    if (constraints.maxWidth < _sideBySideMinWidth) {
                      if (!_stripShown) {
                        _stripShown = true;
                        WidgetsBinding.instance.addPostFrameCallback(
                            (_) => _revealSelected());
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          HorizontalMouseScrollable(
                            controller: _sessionStrip,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final s in sessions)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        right: NeuSpace.s8),
                                    child: SizedBox(
                                      width: _stripTileWidth,
                                      child: _sessionTile(s, isDark, theme),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(child: _logBody(lines, isDark, theme)),
                        ],
                      );
                    }
                    _stripShown = false;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: _sessionColumnWidth,
                          child: ListView.builder(
                            padding: NeuShadowRoom.list,
                            itemCount: sessions.length,
                            itemBuilder: (context, i) =>
                                _sessionTile(sessions[i], isDark, theme),
                          ),
                        ),
                        const SizedBox(width: NeuSpace.s12),
                        Expanded(child: _logBody(lines, isDark, theme)),
                      ],
                    );
                  }),
                ),
              ],
            ),
      actions: [
        NeuDialogAction.secondary('Close', () => Navigator.pop(context)),
      ],
    );
  }

  Widget _sessionTile(LogSession s, bool isDark, ThemeData theme) {
    final selected = s.key == _selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: NeuSpace.s4),
      child: InkWell(
        borderRadius: BorderRadius.circular(NeuRadius.r8),
        onTap: () => setState(() {
          _selected = s.key;
          _requestedGone = false;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s8),
          decoration: selected
              ? NeuTheme.sunkenDecoration(isDark,
                  radius: NeuRadius.r8,
                  border: Border.all(color: themeNotifier.accentInk, width: 1.5))
              : NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r8),
          child: Row(
            children: [
              Icon(_iconFor(s),
                  size: 13,
                  color: s.failed
                      ? NeuTheme.dangerText(isDark)
                      : (s.isRunning
                          ? NeuTheme.liveText(isDark)
                          : NeuTheme.subtext(isDark))),
              const SizedBox(width: NeuSpace.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: NeuType.caption(isDark).copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w400,
                        // Derived accent ink, never the raw accent as a
                        // foreground - raw Cyan on the light well is the
                        // 1.015:1 failure this repo has fixed three times.
                        color: selected
                            ? themeNotifier.accentInk
                            : NeuTheme.text(isDark),
                      ),
                    ),
                    Text(
                      s.isRunning
                          ? 'running · ${timeAgo(s.startedAt)}'
                          : (s.failed
                              ? 'exit ${s.exitCode} · ${timeAgo(s.startedAt)}'
                              : timeAgo(s.startedAt)),
                      style: NeuType.caption(isDark),
                    ),
                  ],
                ),
              ),
              if (s.failed)
                // The fault lamp: steadily lit red, in the one dialog that
                // already commits fully to the hardware read.
                const NeuLedIndicator(
                  size: 6,
                  isPulsing: false,
                  activeColor: NeuTheme.danger,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logBody(List<String> lines, bool isDark, ThemeData theme) {
    return Container(
      // The `screen` role, which is what this always was: a display set into a
      // bezel. It carries its own recess and edge, so the hand-rolled border
      // goes with the BoxDecoration.
      decoration: NeuTheme.screen(isDark, radius: NeuRadius.r8),
      padding: const EdgeInsets.all(NeuSpace.s8),
      child: lines.isEmpty
          ? Center(
              child: Text('No output.',
                  style: NeuType.bodySm(isDark,
                      color: NeuTheme.screenSubtext(isDark))))
          : SelectionArea(
              child: ListView.builder(
                controller: _scroll,
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final line = lines[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: NeuSpace.s4),
                    child: Text(
                      line,
                      // 11px rather than mono's 12: a log pane fits a
                      // meaningful amount more per line, and it is scanned
                      // rather than read.
                      style: NeuType.mono(
                        isDark,
                        color: _colorFor(
                            classifyLogLine(line), isDark, theme.primaryColor),
                      ).copyWith(fontSize: 11, height: 1.35), // Intentional: 11px
                    ),
                  );
                },
              ),
            ),
    );
  }
}
