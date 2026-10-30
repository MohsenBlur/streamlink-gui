import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/activity_state.dart';
import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../activity_pill.dart';
import '../neumorphic/neu_title_bar.dart';
import 'app_chassis.dart';
import 'app_layout.dart';

/// The window's frame: the chassis, the title bar with the activity pill,
/// the banners, and the sidebar beside the content - or above it, in
/// portrait - with the two shortcuts that work from anywhere in it.
///
/// Moved out of `_MainScreenState.build` as it was; what goes in each slot
/// is the screen's.
class AppFrame extends StatelessWidget {
  const AppFrame({
    super.key,
    required this.layout,
    required this.liveCount,
    required this.activity,
    required this.onStopActivity,
    required this.onThemeToggle,
    required this.banners,
    required this.sidebar,
    required this.content,
    required this.onEscape,
    required this.onFind,
  });

  /// The one measurement of the window, published to everything below.
  final AppLayoutData layout;

  /// Live favourites, for the title bar.
  final int liveCount;
  final ValueListenable<ActivitySnapshot> activity;
  final void Function(ActivityItem item) onStopActivity;
  final ValueChanged<bool> onThemeToggle;

  /// Under the title bar, in order; each collapses when it has nothing to say.
  final List<Widget> banners;
  final Widget sidebar;

  /// The Library, Home or the open channel.
  final Widget content;

  /// Esc.
  final VoidCallback onEscape;

  /// Ctrl+F.
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final isVertical = layout.isPortrait;
    final isNarrow = layout.isCompact;
    final contentArea = Expanded(
      // No fill of its own. AppChassis already paints the whole window body
      // as a lit panel - grain, ramp and light - and a flat token fill here
      // was covering it across the largest region of the app, so the
      // machined ground existed only behind the sidebar and title bar while
      // every card floated on flat paper.
      child: Container(
        child: content,
      ),
    );


    return AppLayout(
      data: layout,
      child: Scaffold(
      // The window chassis, which had no host until now. `titleBarStyle` is
      // hidden and this Scaffold's own background was a flat colour, so every
      // pixel of the frame is ours to paint and nothing was painting it.
      body: AppChassis(
      child: CallbackShortcuts(
        bindings: {
          // Esc leaves the Library, or else selection mode. Dialogs sit on
          // their own Navigator route and consume Esc before it reaches
          // here, so this cannot steal a dialog's dismiss.
          const SingleActivator(LogicalKeyboardKey.escape): onEscape,
          // Focus the sidebar search from anywhere. In layouts without the
          // inline field the search popover is the affordance instead.
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): onFind,
        },
        child: Focus(
          autofocus: true,
          child: Column(
        children: [
          NeuTitleBar(
            liveCount: liveCount,
            actions: [
              ActivityPill(
                activity: activity,
                onStop: onStopActivity,
                compact: isNarrow,
              ),
              const SizedBox(width: NeuSpace.s12),
            ],
            isDarkTheme: themeNotifier.isDarkTheme,
            onThemeToggle: onThemeToggle,
          ),
          ...banners,
          Expanded(
            child: isVertical
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sidebar,
                      contentArea,
                    ],
                  )
                : Row(
                    // Stretch, not the default centre. The content area is an
                    // Expanded Container whose child does not fill the height,
                    // so under a centred Row it sized to its child and floated
                    // in the middle of the window. That was invisible for as
                    // long as everything behind it was the same flat colour;
                    // the moment the chassis carried a fill ramp, the content
                    // area became a lighter rectangle with two hard edges
                    // across the middle of the app.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sidebar,
                      contentArea,
                    ],
                  ),
          ),
        ],
          ),
        ),
      ),
      ),
      ),
    );
  }
}
