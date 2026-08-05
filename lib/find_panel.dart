import 'package:flutter/material.dart';

import 'find_state.dart';
import 'src/rust/api/search.dart';

/// The persistent find/replace panel. Docked above the editor rather than
/// floating over it, so the document stays fully visible while stepping.
class FindPanel extends StatefulWidget {
  final FindController controller;
  final VoidCallback onClose;

  /// Called whenever the current match changes, so the host can scroll to it.
  final ValueChanged<MatchSpan> onReveal;

  const FindPanel({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onReveal,
  });

  @override
  State<FindPanel> createState() => FindPanelState();
}

class FindPanelState extends State<FindPanel> {
  final FocusNode _queryFocus = FocusNode();

  FindController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _queryFocus.requestFocus());
  }

  /// Re-focus the query field. The panel widget isn't recreated when it's
  /// already open, so `initState`'s one-shot focus doesn't re-run on a
  /// repeated Ctrl+F — this lets the host ask for it explicitly instead.
  void requestQueryFocus() => _queryFocus.requestFocus();

  @override
  void dispose() {
    c.removeListener(_onControllerChanged);
    _queryFocus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    final m = c.currentMatch;
    if (m != null) {
      // Deferred to avoid triggering a setState (via revealSpan's scroll)
      // while this widget's own build/listener callback is still in flight.
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReveal(m));
    }
  }

  Future<void> _next() async => c.stepForward();
  Future<void> _prev() async => c.stepBackward();

  /// A compact inline option toggle. Every one carries a tooltip naming the
  /// option and its Notepad++ equivalent.
  Widget _toggle({
    required String label,
    required String tooltip,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: value ? scheme.primary.withValues(alpha: 0.20) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: enabled
                  ? (value ? scheme.primary : scheme.onSurfaceVariant)
                  : scheme.outline,
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchModeSelector() {
    return Tooltip(
      message: 'Search mode',
      child: DropdownButton<SearchMode>(
        value: c.searchMode,
        isDense: true,
        underline: const SizedBox.shrink(),
        style: const TextStyle(fontSize: 12),
        items: const [
          DropdownMenuItem(value: SearchMode.normal, child: Text('Normal')),
          DropdownMenuItem(value: SearchMode.extended, child: Text('Extended')),
          DropdownMenuItem(value: SearchMode.regex, child: Text('Regex')),
        ],
        onChanged: (m) {
          if (m == null) return;
          setState(() => c.searchMode = m);
          c.scheduleRefresh();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasError = c.regexError != null;

    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16),
          const SizedBox(width: 6),
          SizedBox(
            width: 260,
            child: Tooltip(
              message: c.regexError ?? 'Find what',
              child: TextField(
                controller: c.query,
                focusNode: _queryFocus,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Find what…',
                  border: const OutlineInputBorder(),
                  enabledBorder: hasError
                      ? OutlineInputBorder(
                          borderSide: BorderSide(color: scheme.error))
                      : null,
                ),
                onChanged: (_) => c.scheduleRefresh(),
                onSubmitted: (_) => _next(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _toggle(
            label: 'Aa',
            tooltip: 'Match case',
            value: c.matchCase,
            onChanged: (v) {
              setState(() => c.matchCase = v);
              c.scheduleRefresh();
            },
          ),
          _toggle(
            label: 'ab|',
            tooltip: 'Match whole word only',
            value: c.wholeWord,
            onChanged: (v) {
              setState(() => c.wholeWord = v);
              c.scheduleRefresh();
            },
          ),
          _toggle(
            label: '↺',
            tooltip: 'Wrap around',
            value: c.wrapAround,
            onChanged: (v) => setState(() => c.wrapAround = v),
          ),
          _toggle(
            label: '⌗',
            tooltip: 'In selection',
            value: c.inSelection,
            enabled: c.scope != null,
            onChanged: (v) {
              setState(() => c.inSelection = v);
              c.scheduleRefresh();
            },
          ),
          _toggle(
            label: '. *',
            tooltip: '. matches newline (regex mode only)',
            value: c.dotMatchesNewline,
            enabled: c.searchMode == SearchMode.regex,
            onChanged: (v) {
              setState(() => c.dotMatchesNewline = v);
              c.scheduleRefresh();
            },
          ),
          const SizedBox(width: 6),
          _searchModeSelector(),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            tooltip: 'Previous match (Shift+F3)',
            onPressed: c.canStepBackward ? _prev : null,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            tooltip: 'Next match (F3)',
            onPressed: c.canStepForward ? _next : null,
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 6),
          Text(
            c.counterLabel,
            style: TextStyle(
              fontSize: 12,
              color: hasError ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Count all matches',
            child: TextButton(
              onPressed: c.query.text.isEmpty || hasError ? null : c.recount,
              child: const Text('Count'),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close (Esc)',
            onPressed: widget.onClose,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
