import 'package:flutter/material.dart';

/// The chrome shared by every bar docked above the editor — the find bar and
/// the MIME/edit tool bars.
///
/// Owns the surface, the optional full-width title band, and the close
/// button. The caller supplies only its controls.
///
/// Layout contract, inherited from the find bar and guarded by width-sweep
/// tests: the close button is RIGID and must stay reachable at every width;
/// [child] is given the remaining space and must be able to shrink or wrap
/// rather than overflow.
///
/// Vertically, the close button aligns to [child]'s FIRST row, not the
/// centre of [child] as a whole. This matters once [child] is a multi-row
/// `Column` (e.g. the find bar's query row plus its replace row): the button
/// stays pinned where the first row put it instead of drifting toward the
/// middle as more rows are added below.
class DockedBar extends StatelessWidget {
  /// Shown centered in a full-width band across the bar's top edge. When null
  /// no band is drawn — that is how the find bar keeps its original look.
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) _titleBand(scheme, title!),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: child),
                _closeButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A full-width band naming the bar, in its own colour so it separates
  /// visually from the controls below rather than reading as one of them.
  ///
  /// Both colours come from the active `ColorScheme`, so the band tracks the
  /// light and dark themes without either being special-cased:
  /// `secondaryContainer` is a muted accent in both, and
  /// `onSecondaryContainer` is the contrast-correct text colour Material
  /// pairs with it.
  Widget _titleBand(ColorScheme scheme, String text) => Container(
    width: double.infinity,
    color: scheme.secondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
        color: scheme.onSecondaryContainer,
      ),
    ),
  );

  /// The close button, sized down from Material's default.
  ///
  /// A stock [IconButton] is 40px square even at compact density, and since it
  /// is the tallest thing in the control row it — not the controls — set every
  /// one-row bar's height. Trimming it to 28px is the single largest saving
  /// available in this chrome, and 28px is still a comfortable mouse target;
  /// this is a desktop app, not a touch one.
  Widget _closeButton() => IconButton(
    icon: const Icon(Icons.close, size: 18),
    tooltip: 'Close (Esc)',
    onPressed: onClose,
    visualDensity: VisualDensity.compact,
    style: IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
  );
}
