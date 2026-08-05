import 'package:flutter/material.dart';

/// The chrome shared by every bar docked above the editor — the find bar and
/// the MIME/edit tool bars.
///
/// Owns the surface, the optional centered title tab, and the close button.
/// The caller supplies only its controls.
///
/// Layout contract, inherited from the find bar and guarded by width-sweep
/// tests: the close button is RIGID and must stay reachable at every width;
/// [child] is given the remaining space and must be able to shrink or wrap
/// rather than overflow.
class DockedBar extends StatelessWidget {
  /// Shown in a rounded tab centered on the bar's top edge. When null no tab
  /// is drawn at all — that is how the find bar keeps its original look.
  final String? title;

  final Widget child;
  final VoidCallback onClose;

  const DockedBar({
    super.key,
    this.title,
    required this.child,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) _titleTab(scheme, title!),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: child),
              _closeButton(),
            ],
          ),
        ],
      ),
    );
  }

  /// A pill with rounded BOTTOM corners in the bar's own colour, sitting in an
  /// otherwise transparent row, so it reads as hanging from the chrome above
  /// rather than as a heading inside the bar.
  Widget _titleTab(ColorScheme scheme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _closeButton() => IconButton(
        icon: const Icon(Icons.close, size: 18),
        tooltip: 'Close (Esc)',
        onPressed: onClose,
        visualDensity: VisualDensity.compact,
      );
}
