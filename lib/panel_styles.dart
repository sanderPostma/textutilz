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
  /// Tonal, not primary-filled: a bar carries up to eight of these and they
  /// are peers. A row of eight primary-coloured buttons is a row with no
  /// emphasis in it at all, which is the same as having none.
  static ButtonStyle actionButton(ColorScheme scheme) => FilledButton.styleFrom(
    backgroundColor: scheme.secondaryContainer,
    foregroundColor: scheme.onSecondaryContainer,
    disabledBackgroundColor: scheme.surfaceContainerHigh,
    disabledForegroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.5),
    textStyle: const TextStyle(fontSize: fontSize),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    minimumSize: Size.zero,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  );

  /// A segmented control on a tool bar: Encode/Decode, EOL flavour, URL
  /// variant.
  static ButtonStyle segmented(ColorScheme scheme) => ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
