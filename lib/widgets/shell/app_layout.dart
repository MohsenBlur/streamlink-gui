import 'package:flutter/widgets.dart';
import '../../theme/neu_tokens.dart';

/// How much room the window has, as one shared answer.
///
/// The app previously computed this three times, in three places, with two
/// different names for the same predicate:
///
/// ```
/// main.dart:2213   isVertical = h > w;  isNarrow = w < 700
/// main.dart:3147   isSmall = w < 1180;  isCompact = w < 700 || h > w
/// dashboard_header.dart:266            (a byte-identical copy of the above)
/// ```
///
/// `isNarrow` and `isCompact` differed only in whether portrait counted, and
/// nothing tied them together, so a change to one silently disagreed with the
/// others. Responsive behaviour cannot be designed against three truths.
enum LayoutSize {
  /// Under 700 logical px. The sidebar is forced to its rail form regardless
  /// of the user's preference, and toolbars collapse to icons.
  compact,

  /// 700 to 1180. The sidebar can expand; wide-only toolbar controls move
  /// into popovers.
  medium,

  /// 1180 and up. Everything has room for its full form.
  expanded,
}

@immutable
class AppLayoutData {
  const AppLayoutData({required this.size, required this.isPortrait});

  factory AppLayoutData.fromSize(Size window) {
    final width = window.width;
    return AppLayoutData(
      size: width < compactMax
          ? LayoutSize.compact
          : width < expandedMin
              ? LayoutSize.medium
              : LayoutSize.expanded,
      isPortrait: window.height > window.width,
    );
  }

  /// Exclusive upper bound of [LayoutSize.compact].
  static const double compactMax = 700;

  /// Inclusive lower bound of [LayoutSize.expanded].
  static const double expandedMin = 1180;

  final LayoutSize size;

  /// Taller than wide. The sidebar becomes a horizontal strip above the
  /// content rather than a column beside it, so this is independent of [size]
  /// - a 900x1200 window is [LayoutSize.medium] *and* portrait.
  final bool isPortrait;

  bool get isCompact => size == LayoutSize.compact;
  bool get isMedium => size == LayoutSize.medium;
  bool get isExpanded => size == LayoutSize.expanded;

  /// The sidebar cannot show its full 280px form: either there is not enough
  /// width, or it has been turned into the horizontal bar.
  ///
  /// This is the predicate that `isNarrow || isVertical` and the second
  /// `isCompact` were both spelling out separately.
  bool get isRail => isCompact || isPortrait;

  /// Wide-only affordances (inline sliders, the full VOD toolbar, the header's
  /// separate action buttons) have room.
  bool get hasWideControls => isExpanded;

  /// Page padding, tightened when space is short.
  EdgeInsets get pagePadding =>
      EdgeInsets.all(isRail ? NeuSpace.s12 : NeuSpace.s24);

  @override
  bool operator ==(Object other) =>
      other is AppLayoutData &&
      other.size == size &&
      other.isPortrait == isPortrait;

  @override
  int get hashCode => Object.hash(size, isPortrait);

  @override
  String toString() => 'AppLayoutData($size, portrait: $isPortrait)';
}

/// Publishes [AppLayoutData] to the subtree.
///
/// Read with `AppLayout.of(context)`. Dependants rebuild only when the *band*
/// changes, not on every pixel of resize, because [AppLayoutData] compares by
/// value — dragging a window from 1400 to 1300 notifies nobody.
class AppLayout extends InheritedWidget {
  const AppLayout({Key? key, required this.data, required Widget child})
      : super(key: key, child: child);

  final AppLayoutData data;

  static AppLayoutData of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<AppLayout>();
    assert(widget != null, 'No AppLayout ancestor. Wrap the app shell in one.');
    return widget!.data;
  }

  /// For widgets that may be built outside the shell (dialogs pushed onto a
  /// root navigator, tests): falls back to measuring the media query.
  static AppLayoutData maybeOf(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<AppLayout>();
    if (widget != null) return widget.data;
    return AppLayoutData.fromSize(MediaQuery.sizeOf(context));
  }

  @override
  bool updateShouldNotify(AppLayout oldWidget) => oldWidget.data != data;
}
