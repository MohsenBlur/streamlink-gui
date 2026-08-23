import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// Meaning, not colour. The caller says what a badge *is*; the tone decides
/// how it looks, so "downloaded" reads the same everywhere it appears.
enum BadgeTone {
  /// Informational, no judgement: STREAMED, QUEUED.
  neutral,

  /// Something is live or complete: LIVE, DOWNLOADED.
  live,

  /// A failure.
  danger,

  /// A caution or degraded state.
  warning,

  /// Tied to the current selection or the user's accent.
  accent,
}

extension on BadgeTone {
  Color ink(bool isDark) => switch (this) {
        BadgeTone.neutral => NeuTheme.subtext(isDark),
        BadgeTone.live => NeuTheme.liveText(isDark),
        BadgeTone.danger => NeuTheme.dangerText(isDark),
        BadgeTone.warning => NeuTheme.warningText(isDark),
        BadgeTone.accent => themeNotifier.accentInk,
      };

  Color base(bool isDark) => switch (this) {
        BadgeTone.neutral => NeuTheme.subtext(isDark),
        BadgeTone.live => NeuTheme.live,
        BadgeTone.danger => NeuTheme.danger,
        BadgeTone.warning => NeuTheme.warning,
        BadgeTone.accent => themeNotifier.primaryColor,
      };
}

/// A small uppercase status chip: DOWNLOADED, STREAMED, QUEUED, NOW PLAYING.
///
/// These existed as a four-line TextStyle literal - `fontSize: 8.5`,
/// `fontWeight: bold`, `letterSpacing: 0.5` - copy-pasted at four sites, with
/// each one picking its own fill and border alpha. 8.5px is also below the
/// size at which Segoe UI's stems land on whole pixels, so it greys out
/// regardless of the colour chosen; these are 10px.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    Key? key,
    required this.label,
    this.tone = BadgeTone.neutral,
    this.icon,
  }) : super(key: key);

  final String label;
  final BadgeTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;
    final ink = tone.ink(isDark);
    final base = tone.base(isDark);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: NeuSpace.s8, vertical: NeuSpace.s4),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(NeuRadius.r6),
        border: Border.all(color: base.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: ink),
            const SizedBox(width: NeuSpace.s4),
          ],
          Text(
            label.toUpperCase(),
            style: NeuType.micro(isDark, color: ink),
          ),
        ],
      ),
    );
  }
}

/// How prominently "live" is being said.
enum LiveVariant {
  /// A bare mint dot, for avatars and dense rows.
  dot,

  /// A LIVE chip.
  pill,

  /// "N LIVE", for the title bar.
  count,
}

/// The app's single way of saying "live".
///
/// It previously said it three ways at once: a tinted "N LIVE" chip in the
/// title bar at 10px with 1.2 tracking, a SOLID mint "LIVE" pill in sidebar
/// rows at 8px, and a third pill in the channel header at 10/9px with 0.5
/// tracking - plus bare mint dots on avatars. A shot containing the title bar,
/// the sidebar and the header showed three different visual languages for one
/// piece of state.
class LiveBadge extends StatelessWidget {
  const LiveBadge({
    Key? key,
    this.variant = LiveVariant.pill,
    this.count,
    this.pulse,
    this.label,
  }) : super(key: key);

  final LiveVariant variant;

  /// Required by [LiveVariant.count].
  final int? count;

  /// Drives a soft pulse when supplied. Null renders static, which is what a
  /// badge in a dialog or a screenshot wants.
  final Animation<double>? pulse;

  /// Overrides the text, for the offline counterpart.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    if (variant == LiveVariant.dot) {
      final dot = Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: NeuTheme.live,
          shape: BoxShape.circle,
          border: Border.all(color: NeuTheme.surface(isDark), width: 2),
        ),
      );
      return _maybePulse(dot);
    }

    final text = switch (variant) {
      LiveVariant.count => '${count ?? 0} LIVE',
      _ => label ?? 'LIVE',
    };

    final badge = StatusBadge(label: text, tone: BadgeTone.live);
    return _maybePulse(badge);
  }

  Widget _maybePulse(Widget child) {
    final animation = pulse;
    if (animation == null) return child;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, inner) => Opacity(
        // A gentle breath. The old sidebar pill dipped its glow to 40%, which
        // reads as flickering rather than pulsing.
        opacity: 0.75 + 0.25 * animation.value,
        child: inner,
      ),
      child: child,
    );
  }
}
