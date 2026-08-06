import 'package:flutter/material.dart';
import 'package:textutilz/src/rust/api/search.dart';

class FindResultItem {
  final MatchSpan span;
  final String lineText;
  const FindResultItem(this.span, this.lineText);
}

/// Bottom-docked panel displaying all search matches in the current file.
class FindResultsPanel extends StatefulWidget {
  final String query;
  final List<FindResultItem> results;
  final bool isLoading;
  final String? error;
  final MatchSpan? currentMatch;
  final VoidCallback onClose;
  final ValueChanged<MatchSpan> onSelectResult;

  const FindResultsPanel({
    super.key,
    required this.query,
    required this.results,
    this.isLoading = false,
    this.error,
    this.currentMatch,
    required this.onClose,
    required this.onSelectResult,
  });

  @override
  State<FindResultsPanel> createState() => _FindResultsPanelState();
}

class _FindResultsPanelState extends State<FindResultsPanel> {
  final ScrollController _scrollController = ScrollController();
  (int, int)? _selectedLocation;

  @override
  void didUpdateWidget(covariant FindResultsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = widget.currentMatch;
    if (current != null) {
      _selectedLocation = (current.startRow.toInt(), current.startCol.toInt());
      return;
    }
    final selected = _selectedLocation;
    if (selected != null &&
        !widget.results.any(
          (item) =>
              item.span.startRow.toInt() == selected.$1 &&
              item.span.startCol.toInt() == selected.$2,
        )) {
      _selectedLocation = null;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollTo(double offset) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    _scrollController.animateTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  void _scrollTop() => _scrollTo(0);

  void _pageUp() {
    if (!_scrollController.hasClients) return;
    _scrollTo(
      _scrollController.offset - _scrollController.position.viewportDimension,
    );
  }

  void _pageDown() {
    if (!_scrollController.hasClients) return;
    _scrollTo(
      _scrollController.offset + _scrollController.position.viewportDimension,
    );
  }

  void _scrollBottom() {
    if (!_scrollController.hasClients) return;
    _scrollTo(_scrollController.position.maxScrollExtent);
  }

  Widget _scrollButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 17),
        onPressed: widget.results.isEmpty || widget.isLoading
            ? null
            : onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 1.0),
        ),
      ),
      child: Column(
        children: [
          // Header bar
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: scheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(Icons.search, size: 16, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.isLoading
                        ? 'Searching for "${widget.query}"…'
                        : 'Search Results: ${widget.results.length} ${widget.results.length == 1 ? "match" : "matches"} for "${widget.query}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (widget.isLoading) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                _scrollButton(
                  tooltip: 'Top',
                  icon: Icons.vertical_align_top,
                  onPressed: _scrollTop,
                ),
                _scrollButton(
                  tooltip: 'Page up',
                  icon: Icons.keyboard_arrow_up,
                  onPressed: _pageUp,
                ),
                _scrollButton(
                  tooltip: 'Page down',
                  icon: Icons.keyboard_arrow_down,
                  onPressed: _pageDown,
                ),
                _scrollButton(
                  tooltip: 'Bottom',
                  icon: Icons.vertical_align_bottom,
                  onPressed: _scrollBottom,
                ),
                Tooltip(
                  message: 'Close search results',
                  child: IconButton(
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
          // Results list
          Expanded(
            child: widget.error != null
                ? Center(
                    child: Text(
                      'Search failed: ${widget.error}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: scheme.error),
                    ),
                  )
                : widget.isLoading
                ? const SizedBox.shrink()
                : widget.results.isEmpty
                ? Center(
                    child: Text(
                      'No matches found.',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: widget.results.length,
                    itemExtent: 26,
                    itemBuilder: (context, index) {
                      final item = widget.results[index];
                      final row = item.span.startRow.toInt() + 1;
                      final column = item.span.startCol.toInt() + 1;
                      final location = (row - 1, column - 1);
                      final current = widget.currentMatch;
                      final activeLocation = current == null
                          ? _selectedLocation
                          : (
                              current.startRow.toInt(),
                              current.startCol.toInt(),
                            );
                      final selected = activeLocation == location;
                      return ColoredBox(
                        key: ValueKey('find-result-highlight-$index'),
                        color: selected
                            ? scheme.primaryContainer.withValues(alpha: 0.65)
                            : Colors.transparent,
                        child: InkWell(
                          key: ValueKey(
                            'find-result-${item.span.startRow}-${item.span.startCol}',
                          ),
                          mouseCursor: SystemMouseCursors.click,
                          onDoubleTap: () {
                            setState(() => _selectedLocation = location);
                            widget.onSelectResult(item.span);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                SizedBox(
                                  // Keep the location on one line. These rows
                                  // have a fixed extent, so wrapping would paint
                                  // the column beneath the following result.
                                  width: 150,
                                  child: Text(
                                    'Line $row, Col $column',
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w600,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    item.lineText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
