import 'package:flutter/material.dart';

/// The line every transform bar shows telling the user what the next action
/// will affect.
///
/// One widget rather than three copies of the same string, because the wording
/// and the warning colour have to agree across the MIME and structured bars —
/// they are the same promise about the same editor selection.
class PanelScopeNote extends StatelessWidget {
  /// Whether the bar's actions can run at all.
  final bool enabled;

  /// Whether the editor currently has a selection. With no selection, a
  /// transform rewrites the whole document, which is worth warning about.
  final bool hasSelection;

  /// Shown in place of the scope line when the bar is disabled.
  final String disabledMessage;

  const PanelScopeNote({
    super.key,
    required this.enabled,
    required this.hasSelection,
    required this.disabledMessage,
  });

  /// Colour for the whole-document warning.
  ///
  /// Amber in both themes, but not the same amber: the light-theme value is
  /// darkened well past the usual accent, because a bright amber on a light
  /// surface is close to unreadable — which is exactly what the first attempt
  /// at this got wrong.
  static Color warningColor(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color(0xFFE3B341)
      : const Color(0xFF8A6100);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (!enabled) {
      return Text(
        disabledMessage,
        key: const ValueKey('panel-scope-disabled'),
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }
    if (hasSelection) {
      return Text(
        'Transforms the selection.',
        key: const ValueKey('panel-scope-selection'),
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }
    return Text(
      '⚠️ Transforms the whole document.',
      key: const ValueKey('panel-scope-document'),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: warningColor(theme.brightness),
      ),
    );
  }
}
