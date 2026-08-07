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

  /// An action button on a tool bar: the edit bars' operations.
  ///
  /// Tonal rather than outlined, so it reads as a *button* at a glance and
  /// matches the bar's title band, which uses the same container colour.
  static ChipThemeData chip(ColorScheme scheme) => ChipThemeData(
    backgroundColor: scheme.secondaryContainer,
    disabledColor: scheme.surfaceContainerHigh,
    labelStyle: TextStyle(
      fontSize: fontSize,
      color: scheme.onSecondaryContainer,
    ),
    side: BorderSide.none,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
  );

  /// The label colour a disabled chip takes.
  ///
  /// [ChipThemeData.labelStyle] applies to both states, so the disabled colour
  /// has to be applied by the caller; a disabled chip that keeps the enabled
  /// label colour looks enabled, which is the whole point of the state.
  static Color disabledLabel(ColorScheme scheme) =>
      scheme.onSurfaceVariant.withValues(alpha: 0.5);

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

  /// The primary action on a tool bar — the one that applies the transform.
  /// Filled, because there is exactly one of them per bar and it is the thing
  /// the user came for.
  static ButtonStyle primaryButton(ColorScheme scheme) =>
      FilledButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
      );
}
