import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme/neu_theme.dart';
import '../../theme/theme_notifier.dart';
import '../neumorphic/neu_button.dart';
import '../neumorphic/neu_icon_action.dart';
import '../interactive_popover.dart';
import 'app_layout.dart';

/// One bulk action offered while a selection is active.
class SelectionAction {
  const SelectionAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tone = SelectionTone.neutral,
  });

  final String label;
  final IconData icon;

  /// Null renders the action disabled - used while nothing is selected.
  final VoidCallback? onPressed;
  final SelectionTone tone;
}

enum SelectionTone { neutral, accent, positive, destructive }

/// The toolbar shown while a multi-selection is active.
///
/// It REPLACES the normal toolbar rather than growing out of it, which is the
/// whole point. The old version appended four labelled buttons, a count, a
/// progress ring and two icon buttons to the row that already held the display
/// controls, with no compact branch anywhere - so below roughly 1100px it
/// simply overflowed. A stopgap Wrap stopped the overflow stripes but left a
/// toolbar that reflowed to three lines on a narrow window.
///
/// Replacing bounds the width budget: whatever the window size, this bar holds
/// a count, two selection controls and the actions, and the actions collapse
/// into an overflow menu when they do not fit.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    Key? key,
    required this.selectedCount,
    required this.onSelectAllVisible,
    required this.onClear,
    required this.onExit,
    required this.actions,
  }) : super(key: key);

  final int selectedCount;
  final VoidCallback onSelectAllVisible;
  final VoidCallback onClear;

  /// Leaves selection mode entirely and returns the normal toolbar.
  final VoidCallback onExit;

  final List<SelectionAction> actions;

  Color _foreground(SelectionTone tone, bool isDark) => switch (tone) {
        SelectionTone.neutral => NeuTheme.text(isDark),
        SelectionTone.accent => themeNotifier.accentInk,
        SelectionTone.positive => NeuTheme.liveText(isDark),
        SelectionTone.destructive => NeuTheme.dangerText(isDark),
      };

  @override
  Widget build(BuildContext context) {
    final isDark = themeNotifier.isDarkTheme;

    // Grown with Windows' Text size (textGrowthOf). Unscaled, at 125% this
    // picked the full layout at 1280 wide, its labels outgrew the budget and
    // the count's side overflowed into the actions.
    final textGrowth = textGrowthOf(context);

    return LayoutBuilder(builder: (context, constraints) {
      // Measured from the widest label set at 100% text: the count and the
      // two selection controls need ~300px, each labelled action ~140.
      // 130 was short of Unwatched's ~150, and the four the channel page
      // shows need 841: from 820, where 130 picked this layout, to 840 the
      // count's All and None overflowed into the actions.
      final full = constraints.maxWidth >=
          (300 + actions.length * 140) * textGrowth;

      final count = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _Shrinkable(
              child: Text(
                selectedCount == 0
                    ? 'Select videos'
                    : '$selectedCount selected',
                style: NeuType.label(isDark),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: NeuSpace.s12),
          _textButton('All', onSelectAllVisible, isDark),
          const SizedBox(width: NeuSpace.s6),
          _textButton('None', selectedCount == 0 ? null : onClear, isDark),
        ],
      );

      return Container(
        padding: const EdgeInsets.symmetric(
            horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
        decoration: NeuTheme.raisedDecoration(
          isDark,
          radius: NeuRadius.r12,
          border: Border.all(
              color: themeNotifier.primaryColor.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            NeuIconAction(
              icon: Icons.close,
              tooltip: 'Leave selection mode (Esc)',
              size: NeuActionSize.sm,
              onPressed: onExit,
            ),
            const SizedBox(width: NeuSpace.s12),
            // The rest keeps its two ends at the bar's two edges, as the
            // Spacer between them did. The labelled actions do not shrink,
            // so beside them the count's side has whatever is left. The
            // Actions menu does, and there the count and the menu's label
            // give way only once both ends no longer fit (splitTwoEnds): a
            // Row split them two parts to one whatever each needed, which cut
            // one short while there was still room for both.
            Expanded(
              child: full
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(child: count),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final action in actions) ...[
                              const SizedBox(width: NeuSpace.s8),
                              _actionButton(action, isDark),
                            ],
                          ],
                        ),
                      ],
                    )
                  : _TwoEnds(start: count, end: _overflow(context, isDark)),
            ),
          ],
        ),
      );
    });
  }

  Widget _textButton(String label, VoidCallback? onPressed, bool isDark) {
    return NeuButton(
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(
          horizontal: NeuSpace.s12, vertical: NeuSpace.s6),
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      child: Text(label, style: NeuType.captionMetrics),
    );
  }

  Widget _actionButton(SelectionAction action, bool isDark) {
    final ink = _foreground(action.tone, isDark);
    return NeuButton(
      onPressed: action.onPressed,
      padding: const EdgeInsets.symmetric(
          horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
      borderRadius: BorderRadius.circular(NeuRadius.r8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(action.icon, size: 15, color: ink),
          const SizedBox(width: NeuSpace.s6),
          Text(action.label, style: NeuType.captionStrong(isDark, color: ink)),
        ],
      ),
    );
  }

  /// Narrow windows: the actions move into a popover rather than wrapping the
  /// bar onto a second and third line.
  Widget _overflow(BuildContext context, bool isDark) {
    return InteractivePopover(
      popoverBuilder: (context, close) => Container(
        width: 220,
        padding: const EdgeInsets.all(NeuSpace.s6),
        decoration: NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final action in actions)
              Padding(
                padding: const EdgeInsets.only(bottom: NeuSpace.s4),
                child: NeuButton(
                  onPressed: action.onPressed == null
                      ? null
                      : () {
                          close();
                          action.onPressed!();
                        },
                  padding: const EdgeInsets.symmetric(
                      horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
                  borderRadius: BorderRadius.circular(NeuRadius.r8),
                  child: Row(
                    children: [
                      Icon(action.icon,
                          size: 15, color: _foreground(action.tone, isDark)),
                      const SizedBox(width: NeuSpace.s8),
                      Text(action.label,
                          style: NeuType.caption(isDark,
                              color: _foreground(action.tone, isDark))),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      // NOT a NeuButton. InteractivePopover opens on its own GestureDetector,
      // and a button child WINS the gesture arena with its internal handler -
      // which here was a no-op, so tapping "Actions" did nothing at all. The
      // trigger is a plain raised surface; the popover owns the tap.
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: NeuSpace.s12, vertical: NeuSpace.s8),
          decoration:
              NeuTheme.raisedDecoration(isDark, radius: NeuRadius.r8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: _Shrinkable(
                  child: Text(
                    'Actions',
                    style: NeuType.captionStrong(isDark),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: NeuSpace.s4),
              Icon(Icons.arrow_drop_down,
                  size: 16, color: NeuTheme.subtext(isDark)),
            ],
          ),
        ),
      ),
    );
  }
}

/// How a row [available] wide is shared between its two ends, which want
/// [start] and [end]: each gets what it wants while both fit. Past that, the
/// end that wants less than its share - [startShare] of the row for the
/// start, the rest for the end - keeps what it wants, and the other gives
/// way; only when both want more than their shares is it [startShare] to
/// the rest.
///
/// Neither end is given less than what it cannot do without - [startMin],
/// [endMin]: its buttons and icons, which do not shrink, where its label
/// does - while the other end can still give way. A share smaller than that
/// overflowed the count's All and None at large text sizes, while the
/// Actions label beside them could still have ellipsized.
({double start, double end}) splitTwoEnds(
    double available, double start, double end,
    {double startShare = 2 / 3, double startMin = 0, double endMin = 0}) {
  if (start + end <= available) return (start: start, end: end);
  final startCap = available * startShare;
  final endCap = available - startCap;
  final double s;
  if (start <= startCap) {
    s = start;
  } else if (end <= endCap) {
    s = available - end;
  } else {
    s = startCap;
  }
  if (s < startMin) {
    final grown = math.max(s, math.min(startMin, available - endMin));
    return (start: grown, end: available - grown);
  }
  if (available - s < endMin) {
    final shrunk = math.max(math.min(startMin, s), available - endMin);
    return (start: shrunk, end: available - shrunk);
  }
  return (start: s, end: available - s);
}

/// [child], reporting no minimum width of its own: a label that ellipsizes,
/// so the row it sits in can tell what it cannot do without (the buttons
/// beside it) from what can give way (this). A Text's minimum is its
/// longest word.
class _Shrinkable extends SingleChildRenderObjectWidget {
  const _Shrinkable({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderShrinkable();
}

class _RenderShrinkable extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;
}

/// [start] at the row's left edge and [end] at its right, sized by
/// [splitTwoEnds] from what each would take, and centred across the row.
class _TwoEnds extends MultiChildRenderObjectWidget {
  _TwoEnds({required Widget start, required Widget end})
      : super(children: [start, end]);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTwoEnds();
}

class _TwoEndsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderTwoEnds extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _TwoEndsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _TwoEndsParentData> {
  RenderBox get _start => firstChild!;
  RenderBox get _end => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TwoEndsParentData) {
      child.parentData = _TwoEndsParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _start.getMinIntrinsicWidth(height) + _end.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _start.getMaxIntrinsicWidth(height) + _end.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => math.max(
      _start.getMinIntrinsicHeight(width), _end.getMinIntrinsicHeight(width));

  @override
  double computeMaxIntrinsicHeight(double width) => math.max(
      _start.getMaxIntrinsicHeight(width), _end.getMaxIntrinsicHeight(width));

  /// The two ends' constraints: as wide as [splitTwoEnds] allows, and no
  /// taller than the row.
  (BoxConstraints, BoxConstraints) _childConstraints(
      BoxConstraints constraints) {
    final wantStart = _start.getMaxIntrinsicWidth(double.infinity);
    final wantEnd = _end.getMaxIntrinsicWidth(double.infinity);
    // Their minimums are what cannot give way: the labels in them are
    // _Shrinkable, so what is left is buttons, gaps and icons.
    final split = constraints.hasBoundedWidth
        ? splitTwoEnds(constraints.maxWidth, wantStart, wantEnd,
            startMin: _start.getMinIntrinsicWidth(double.infinity),
            endMin: _end.getMinIntrinsicWidth(double.infinity))
        : (start: wantStart, end: wantEnd);
    BoxConstraints upTo(double width) =>
        BoxConstraints(maxWidth: width, maxHeight: constraints.maxHeight);
    return (upTo(split.start), upTo(split.end));
  }

  Size _sizeFor(BoxConstraints constraints, Size start, Size end) =>
      constraints.constrain(Size(
          constraints.hasBoundedWidth
              ? constraints.maxWidth
              : start.width + end.width,
          math.max(start.height, end.height)));

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final (start, end) = _childConstraints(constraints);
    return _sizeFor(
        constraints, _start.getDryLayout(start), _end.getDryLayout(end));
  }

  @override
  void performLayout() {
    final (start, end) = _childConstraints(constraints);
    _start.layout(start, parentUsesSize: true);
    _end.layout(end, parentUsesSize: true);
    size = _sizeFor(constraints, _start.size, _end.size);
    (_start.parentData! as _TwoEndsParentData).offset =
        Offset(0, (size.height - _start.size.height) / 2);
    (_end.parentData! as _TwoEndsParentData).offset = Offset(
        size.width - _end.size.width, (size.height - _end.size.height) / 2);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
