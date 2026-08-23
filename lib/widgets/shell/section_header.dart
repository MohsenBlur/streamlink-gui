import 'package:flutter/material.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';

/// How loudly a heading speaks.
enum SectionDensity {
  /// A major section of a page: "Live now", "Continue watching".
  page,

  /// A group inside a panel or dialog.
  panel,

  /// A small all-caps label above a dense list: "IN PROGRESS".
  inline,
}

/// The heading above a group of content.
///
/// Page and panel headings were bare `Text` widgets with a hand-picked size at
/// each site (16, 13, 14), and the all-caps inline label existed as the same
/// four-line TextStyle - `fontSize: 9.5, bold, letterSpacing: 0.8` - written
/// out twice in two files.
///
/// A [count] renders as part of the heading rather than as a separate chip,
/// because "Live now 3" answers a question the user is already asking; a
/// [trailing] slot takes the section's own control (a refresh, a "see all").
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    Key? key,
    required this.title,
    this.icon,
    this.count,
    this.subtitle,
    this.trailing,
    this.density = SectionDensity.page,
  }) : super(key: key);

  final String title;
  final IconData? icon;
  final int? count;
  final String? subtitle;
  final Widget? trailing;
  final SectionDensity density;

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    final TextStyle style;
    switch (density) {
      case SectionDensity.page:
        style = NeuType.headingMd(isDark);
      case SectionDensity.panel:
        style = NeuType.headingSm(isDark);
      case SectionDensity.inline:
        // 10px is the floor for all-caps micro text: below it Segoe UI's stems
        // fall between device pixels and grey out whatever colour is set. The
        // two sites doing this by hand used 9.5.
        style = NeuType.plate(isDark, color: NeuTheme.subtext(isDark));
    }

    final label = density == SectionDensity.inline ? title.toUpperCase() : title;

    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon,
              size: density == SectionDensity.page ? 18 : 14,
              color: NeuTheme.subtext(isDark)),
          const SizedBox(width: NeuSpace.s8),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(label,
                        style: style,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: NeuSpace.s8),
                    Text('$count',
                        style: density == SectionDensity.page
                            ? NeuType.body(isDark,
                                color: NeuTheme.subtext(isDark))
                            : NeuType.caption(isDark)),
                  ],
                ],
              ),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: NeuSpace.s2),
                  child: Text(subtitle!,
                      style: NeuType.caption(isDark),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          trailing!,
        ],
      ],
    );
  }
}
