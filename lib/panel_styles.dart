import 'package:flutter/material.dart';

/// Shared control styling for the docked tool bars.
///
/// The bars were built one at a time and each reached for whatever Material
/// widget fitted, at its default styling. On a dark theme that left the edit
/// bars' [ActionChip]s reading as flat black rectangles — Material 3's default
/// chip is a transparent surface with a hairline outline, which disappears
/// against the bar's own `surfaceContainerHighest` — sitting next to filled
/// buttons on the MIME and structured bars. Same job, three appearances.
///
/// So the styling lives here rather than in each panel, and it is derived from
/// the [ColorScheme] for the same reason the syntax palette is: a fixed colour
/// is only correct for the theme it was picked against.
///
/// Every style keeps the density the height budget depends on — Material's
/// stock 48px tap target makes a single wrap run 48px tall on its own, which
/// blows the ceilings pinned in `test/tool_bar_layout_test.dart`.
class PanelStyles {
  const PanelStyles._();

  /// Font size shared by every control on a bar.
  static const double fontSize = 13;

  /// **The** action button on a tool bar — every operation on every bar.
  ///
  /// One style and one widget ([FilledButton]) rather than a chip here and a
  /// filled button there. The bars were built separately and ended up with
  /// three appearances for the same job: outlined chips on the edit bars,
  /// lavender filled buttons on the structured bars, another filled button for
  /// MIME's Apply. Different widgets also mean different shapes and heights,
  /// so no amount of colour-matching would have made them agree.
  ///
  /// Primary-filled — the bright one. An earlier version made these tonal, on
  /// the argument that a bar carries up to eight peers and eight bright
  /// buttons is a row with no emphasis in it. That was wrong in the app: the
  /// bars sit on `surfaceContainerHighest`, where a tonal button barely
  /// separates from its own background, and the MIME bar's bright Apply was
  /// the one everybody read as correct. Consistency was the ask; this is the
  /// colour to be consistent *with*.
  static ButtonStyle actionButton(ColorScheme scheme) => FilledButton.styleFrom(
    backgroundColor: scheme.primary,
    foregroundColor: scheme.onPrimary,
    disabledBackgroundColor: scheme.onSurface.withValues(alpha: 0.12),
    disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
    textStyle: const TextStyle(fontSize: fontSize),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    // 8 rather than 6 vertical: 4px taller overall, asked for after seeing
    // them in the app. The bars' height ceilings are measured, so this shows
    // up there rather than silently eating the budget.
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    minimumSize: Size.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  );

  /// A segmented control on a tool bar: Encode/Decode, EOL flavour, URL
  /// variant.
  static ButtonStyle segmented(ColorScheme scheme) => ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    ),
    textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: fontSize)),
    side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
  );

  /// MIME's Apply once had a style of its own — primary-filled, on the
  /// argument that it is the one button on its bar that is not a peer. In the
  /// app that argument lost: a lavender `primary` pill next to
  /// `secondaryContainer` ones does not read as "this one matters", it reads
  /// as "these were built by different people". [actionButton] is the only
  /// button style now.
}
