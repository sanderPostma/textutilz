import 'package:flutter/material.dart';

import 'markup_styling.dart';
import 'src/rust/api/structured.dart';

/// The list of validation problems for the active document.
///
/// Deliberately the same shape as [FindResultsPanel]: a fixed-height strip
/// under the editor, a header carrying the count, and rows that reveal their
/// location on double-click. Validation errors and search hits are the same
/// interaction — "here is a list of places, take me to one" — so they should
/// not be two different interactions to learn.
class ValidationResultsPanel extends StatefulWidget {
  /// The format the document was validated as, for the header.
  final StructuredLanguage language;

  /// Problems found, in document order. Empty means the document is valid.
  final List<StructuredDiagnostic> diagnostics;

  /// The source row text for each diagnostic, so a row can show its context
  /// without the panel reaching into the document itself.
  final List<String> contextLines;

  /// True when the document was too large to analyse. The empty list then means
  /// "not checked", which is a different thing from "no problems".
  final bool truncated;

  final VoidCallback? onClose;

  /// Called on double-click with the problem to reveal. The whole diagnostic
  /// is passed, not just its start, so the host can select the offending span
  /// rather than only placing the caret near it.
  final ValueChanged<StructuredDiagnostic>? onSelect;

  const ValidationResultsPanel({
    super.key,
    required this.language,
    required this.diagnostics,
    this.contextLines = const [],
    this.truncated = false,
    this.onClose,
    this.onSelect,
  });

  @override
  State<ValidationResultsPanel> createState() => _ValidationResultsPanelState();
}

class _ValidationResultsPanelState extends State<ValidationResultsPanel> {
  final ScrollController _scroll = ScrollController();

  /// The row the user last jumped to, kept highlighted so they can see where
  /// they are in a long list after the editor scrolls away.
  int? _selectedIndex;

  static const double _rowExtent = 26;

  /// Header height, the separator above it, and the full height when there are
  /// problems to list.
  static const double _headerHeight = 32;
  static const double _borderWidth = 1.0;
  static const double _listHeight = 180;

  /// Collapsed height: the header plus the border above it. The `Container`'s
  /// height covers the border too, so leaving it out overflows the column by
  /// exactly that pixel.
  static const double collapsedHeight = _headerHeight + _borderWidth;

  /// With nothing to report there is no list, so the panel collapses to its
  /// header rather than holding 148px of empty space open under the editor.
  double get _height => widget.diagnostics.isEmpty && !widget.truncated
      ? collapsedHeight
      : _listHeight;

  @override
  void didUpdateWidget(covariant ValidationResultsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A stale selection would highlight the wrong problem once the document is
    // revalidated and the list changes underneath it.
    if (oldWidget.diagnostics != widget.diagnostics) {
      _selectedIndex = null;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollTo(double offset) {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      offset.clamp(0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  Widget _scrollButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 16),
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      ),
    );
  }

  String get _headerText {
    final label = MarkupStyling.label(widget.language);
    if (widget.truncated) {
      return '$label: document too large to validate';
    }
    final count = widget.diagnostics.length;
    if (count == 0) return '$label is valid — no problems found';
    return '$label: $count ${count == 1 ? "problem" : "problems"}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final hasProblems = widget.diagnostics.isNotEmpty;

    return Container(
      height: _height,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: _borderWidth),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: scheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(
                  hasProblems
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  size: 16,
                  color: hasProblems
                      ? MarkupStyling.diagnosticUnderline(
                          StructuredSeverity.error,
                          scheme,
                        )
                      : scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _headerText,
                    key: const ValueKey('validation-header'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (hasProblems) ...[
                  _scrollButton(
                    tooltip: 'Top',
                    icon: Icons.vertical_align_top,
                    onPressed: () => _scrollTo(0),
                  ),
                  _scrollButton(
                    tooltip: 'Page up',
                    icon: Icons.keyboard_arrow_up,
                    onPressed: () => _scrollTo(_scroll.offset - _rowExtent * 5),
                  ),
                  _scrollButton(
                    tooltip: 'Page down',
                    icon: Icons.keyboard_arrow_down,
                    onPressed: () => _scrollTo(_scroll.offset + _rowExtent * 5),
                  ),
                  _scrollButton(
                    tooltip: 'Bottom',
                    icon: Icons.vertical_align_bottom,
                    onPressed: () => _scrollTo(double.infinity),
                  ),
                ],
                Tooltip(
                  message: 'Close validation results',
                  child: IconButton(
                    key: const ValueKey('validation-close'),
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: widget.onClose,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_height > _headerHeight)
            Expanded(child: _body(scheme, brightness)),
        ],
      ),
    );
  }

  Widget _body(ColorScheme scheme, Brightness brightness) {
    if (widget.truncated) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'This document is above the size limit for validation. '
            'Syntax colouring still works.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      itemCount: widget.diagnostics.length,
      itemExtent: _rowExtent,
      itemBuilder: (context, index) => _row(index, scheme, brightness),
    );
  }

  Widget _row(int index, ColorScheme scheme, Brightness brightness) {
    final diagnostic = widget.diagnostics[index];
    final row = diagnostic.row.toInt();
    final col = diagnostic.col.toInt();
    final context = index < widget.contextLines.length
        ? widget.contextLines[index].trim()
        : '';
    final selected = _selectedIndex == index;

    return ColoredBox(
      key: ValueKey('validation-highlight-$index'),
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.65)
          : Colors.transparent,
      child: InkWell(
        key: ValueKey('validation-result-$row-$col'),
        onDoubleTap: () {
          setState(() => _selectedIndex = index);
          widget.onSelect?.call(diagnostic);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(
                diagnostic.severity == StructuredSeverity.error
                    ? Icons.error_outline
                    : Icons.warning_amber_outlined,
                size: 14,
                color: MarkupStyling.diagnosticUnderline(
                  diagnostic.severity,
                  scheme,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 130,
                child: Text(
                  'Line ${row + 1}, Col ${col + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: scheme.primary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  context.isEmpty
                      ? diagnostic.message
                      : '${diagnostic.message}   $context',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
