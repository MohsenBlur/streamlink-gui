import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/log_store.dart';
import '../state/log_line_kind.dart';
import '../theme/neu_theme.dart';
import '../theme/theme_notifier.dart';
import '../utils/time_utils.dart';

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
    return showDialog(
      context: context,
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
  final ScrollController _scroll = ScrollController();
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

  @override
  void dispose() {
    widget.logs.removeListener(_onLogs);
    _scroll.dispose();
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

  Color _colorFor(LogLineKind kind, bool isDark, Color accent) {
    switch (kind) {
      case LogLineKind.error:
        return NeuTheme.dangerText(isDark);
      case LogLineKind.system:
        return isDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1);
      case LogLineKind.streamlink:
        return accent;
      case LogLineKind.cliInfo:
        return isDark ? const Color(0xFF10B981) : const Color(0xFF047857);
      case LogLineKind.download:
        return NeuTheme.liveText(isDark);
      case LogLineKind.plain:
        return NeuTheme.text(isDark);
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

    return AlertDialog(
      backgroundColor: themeNotifier.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.terminal, color: themeNotifier.accentInk, size: 18),
          const SizedBox(width: 10),
          Text('Diagnostics Log',
              style: NeuTheme.titleStyle(isDark, fontSize: 16)),
          const Spacer(),
          if (_selected != null) ...[
            TextButton.icon(
              onPressed: lines.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: lines.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Log copied')),
                      );
                    },
              icon: const Icon(Icons.copy_all, size: 14),
              label: const Text('Copy all', style: TextStyle(fontSize: 11)),
            ),
            TextButton.icon(
              onPressed: lines.isEmpty
                  ? null
                  : () => widget.logs.clear(_selected!),
              icon: const Icon(Icons.delete_outline, size: 14),
              label: const Text('Clear', style: TextStyle(fontSize: 11)),
            ),
          ],
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      content: SizedBox(
        width: 760,
        height: 460,
        child: sessions.isEmpty
            ? Center(
                child: Text(
                  'Nothing has run yet this session.',
                  style: NeuTheme.subtextStyle(isDark, fontSize: 13),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_requestedGone)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'That log is no longer available; showing the most recent instead.',
                        style: TextStyle(
                            fontSize: 11,
                            color: NeuTheme.dangerText(isDark)),
                      ),
                    ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 210,
                          child: ListView.builder(
                            itemCount: sessions.length,
                            itemBuilder: (context, i) =>
                                _sessionTile(sessions[i], isDark, theme),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: _logBody(lines, isDark, theme)),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Close',
              style: TextStyle(color: NeuTheme.subtext(isDark))),
        ),
      ],
    );
  }

  Widget _sessionTile(LogSession s, bool isDark, ThemeData theme) {
    final selected = s.key == _selected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() {
          _selected = s.key;
          _requestedGone = false;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: selected
              ? NeuTheme.sunkenDecoration(isDark,
                  radius: 8,
                  border: Border.all(color: themeNotifier.accentInk, width: 1.5))
              : NeuTheme.raisedDecoration(isDark, radius: 8),
          child: Row(
            children: [
              Icon(_iconFor(s),
                  size: 13,
                  color: s.failed
                      ? NeuTheme.dangerText(isDark)
                      : (s.isRunning
                          ? NeuTheme.liveText(isDark)
                          : NeuTheme.subtext(isDark))),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.w500,
                        color: selected
                            ? theme.primaryColor
                            : NeuTheme.text(isDark),
                      ),
                    ),
                    Text(
                      s.isRunning
                          ? 'running · ${timeAgo(s.startedAt)}'
                          : (s.failed
                              ? 'exit ${s.exitCode} · ${timeAgo(s.startedAt)}'
                              : timeAgo(s.startedAt)),
                      style: NeuTheme.subtextStyle(isDark, fontSize: 9.5),
                    ),
                  ],
                ),
              ),
              if (s.failed)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: NeuTheme.dangerText(isDark),
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logBody(List<String> lines, bool isDark, ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: NeuTheme.terminalBg(isDark),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: NeuTheme.border(isDark)),
      ),
      padding: const EdgeInsets.all(10),
      child: lines.isEmpty
          ? Center(
              child: Text('No output.',
                  style: NeuTheme.subtextStyle(isDark, fontSize: 12)))
          : SelectionArea(
              child: ListView.builder(
                controller: _scroll,
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final line = lines[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      line,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 11,
                        height: 1.35,
                        color: _colorFor(
                            classifyLogLine(line), isDark, theme.primaryColor),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
