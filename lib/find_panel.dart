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
    _revealedTick = c.revealTick;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _queryFocus.requestFocus(),
    );
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

  /// The value of [FindController.revealTick] we last scrolled for.
  int _revealedTick = 0;

  @override
  void didUpdateWidget(FindPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _revealedTick = widget.controller.revealTick;
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // The controller notifies for plenty of things that are not "the user
    // moved to a match": a background sweep resolving the exact total, a
    // prefetch landing, the document being re-scanned after a keystroke.
    // Revealing on those would yank the editor back to the current match
    // after the user had scrolled away, and would fight the caret while
    // typing. `revealTick` changes only on a deliberate move.
    if (c.revealTick == _revealedTick) return;
    _revealedTick = c.revealTick;
    final m = c.currentMatch;
    if (m == null) return;
    // Deferred to avoid triggering a setState (via revealSpan's scroll)
    // while this widget's own build/listener callback is still in flight.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReveal(m));
  }

  Future<void> _next() async => c.stepForward();
  Future<void> _prev() async => c.stepBackward();

  /// Report a replace that Rust rejected. Without this the failure surfaces
  /// only as an unhandled async error and the button appears to do nothing.
  void _reportFailure(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Replace failed: $error')),
    );
  }

  Future<void> _replaceCurrent() async {
    try {
      await c.replaceCurrent();
    } catch (e) {
      // e.g. the document was edited under the panel, so the stored span no
      // longer holds the matched text ("match text no longer matches the
      // pattern" from expand_for_span).
      _reportFailure(e);
    }
  }

  Future<void> _replaceAll() async {
    final int n;
    try {
      n = await c.replaceAll();
    } catch (e) {
      _reportFailure(e);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(n == 1 ? '1 replacement' : '$n replacements')),
    );
  }

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

  Widget _leadingIcon() => const Icon(Icons.search, size: 16);

  Widget _modeToggle() => Tooltip(
    message: c.mode == FindPanelMode.find
        ? 'Switch to Replace'
        : 'Switch to Find',
    child: IconButton(
      icon: Icon(
        c.mode == FindPanelMode.find
            ? Icons.keyboard_arrow_right
            : Icons.keyboard_arrow_down,
        size: 16,
      ),
      visualDensity: VisualDensity.compact,
      onPressed: () => c.setMode(
        c.mode == FindPanelMode.find
            ? FindPanelMode.replace
            : FindPanelMode.find,
      ),
    ),
  );

  /// The query field is `Flexible` rather than a fixed `SizedBox(width:
  /// 260)`, so it shrinks (down to [minWidth]) instead of forcing the row
  /// wider than the available space. `ConstrainedBox` caps its growth at
  /// 260 too, so it doesn't balloon to fill a very wide window either — it
  /// keeps the same footprint it always had whenever there's room for it.
  /// `flex: 2` (relative to the other flexible siblings — see `_findRow`'s
  /// doc comment) keeps its guaranteed share comfortably above [minWidth]
  /// even at the narrowest width this panel is expected to survive.
  Widget _queryField(bool hasError) {
    final scheme = Theme.of(context).colorScheme;
    return Flexible(
      flex: 2,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 40, maxWidth: 260),
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
                      borderSide: BorderSide(color: scheme.error),
                    )
                  : null,
            ),
            onChanged: (_) => c.scheduleRefresh(),
            onSubmitted: (_) => _next(),
          ),
        ),
      ),
    );
  }

  /// The option toggles plus the search-mode dropdown — the middle cluster
  /// that's least critical to keep pinned, so it's the first thing allowed
  /// to wrap or compress when space is tight.
  List<Widget> _optionWidgets() => [
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
    _searchModeSelector(),
  ];

  /// The option toggles and search-mode dropdown, in an `Expanded` +
  /// horizontally-scrolling `SingleChildScrollView`. Unlike a fixed-size
  /// cluster, this can never force the row wider than its allotted share:
  /// `SingleChildScrollView` always renders at exactly the size it's given
  /// and scrolls whatever doesn't fit, rather than overflowing it. These are
  /// the least essential controls in the row, so they're the first thing
  /// allowed to become scroll-to-reach when space is tight.
  ///
  /// This is `Expanded`, not `Flexible` — deliberately. An earlier version
  /// used `Flexible` here and wrapped the scroll view in `IntrinsicWidth` to
  /// try to make it shrink-wrap to content instead of always filling its
  /// budget. That combination is unreliable: `IntrinsicWidth` over a
  /// scrollable produced an inconsistent layout (sibling widgets measured as
  /// overlapping the toggle cluster's own reported bounds), which is a known
  /// rough edge of asking a `Viewport`-based widget for its intrinsic size.
  /// `Expanded` avoids the whole class of problem by not asking for
  /// shrink-wrapping at all: it *always* fully consumes its flex share,
  /// which is exactly what `SingleChildScrollView` does anyway — so nothing
  /// is wasted or double-counted, and the layout math in `_findRow` stays
  /// simple and predictable (see that doc comment for why predictability
  /// here is what keeps the close button pinned to the right edge).
  Widget _optionCluster() {
    return Expanded(
      flex: 6,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(spacing: 6, children: _optionWidgets()),
      ),
    );
  }

  Widget _prevArrow() => IconButton(
    icon: const Icon(Icons.keyboard_arrow_up, size: 18),
    tooltip: 'Previous match (Shift+F3)',
    onPressed: c.canStepBackward ? _prev : null,
    visualDensity: VisualDensity.compact,
  );

  Widget _nextArrow() => IconButton(
    icon: const Icon(Icons.keyboard_arrow_down, size: 18),
    tooltip: 'Next match (F3)',
    onPressed: c.canStepForward ? _next : null,
    visualDensity: VisualDensity.compact,
  );

  /// The match counter can grow arbitrarily wide with a big document — e.g.
  /// "1 of 20000+" — so it's `Expanded` with `overflow: ellipsis` rather
  /// than a plain `Text`: a long label truncates instead of pushing the row
  /// wider than the space it was given. `Expanded` (not `Flexible`) for the
  /// same reason as `_optionCluster`: it always fully consumes its flex
  /// share, so it can't leave unpredictable unused budget behind for
  /// `Spacer` to fail to reclaim.
  Widget _counterLabel(bool hasError) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      flex: 1,
      child: Text(
        c.counterLabel,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: TextStyle(
          fontSize: 12,
          color: hasError ? scheme.error : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _closeButton() => IconButton(
    icon: const Icon(Icons.close, size: 18),
    tooltip: 'Close (Esc)',
    onPressed: widget.onClose,
    visualDensity: VisualDensity.compact,
  );

  /// The find row's single layout, built to be structurally incapable of
  /// overflowing at any width or with any content — there is no width
  /// threshold to tune and no content assumption to outgrow:
  ///
  /// - The parts that can grow without bound (the query text, the option
  ///   toggles, the match counter) are each wrapped in `Flexible`/`Expanded`,
  ///   which hard-caps their rendered width to a bounded share of whatever
  ///   space is actually available — the inner widget (`TextField`,
  ///   `SingleChildScrollView`, ellipsized `Text`) always accepts that bound
  ///   rather than insisting on more, so none of them can push the `Row`'s
  ///   total width past its constraint. That alone is enough to guarantee no
  ///   overflow at any width, for any content.
  /// - The parts that must always stay reachable (the step arrows and the
  ///   close button) stay rigid, fixed-size widgets outside any
  ///   `Flexible`/`Expanded`.
  /// - `Spacer` still works because the outer container is a plain `Row`,
  ///   not a `Wrap` — so the close button keeps its pin to the far right
  ///   edge, not just at "wide enough" widths.
  ///
  /// The flex weights (query: 2, option cluster: 6, counter: 1, spacer: 3)
  /// are chosen for a second reason beyond avoiding overflow — getting
  /// `Spacer` an *accurate* share of the truly-left-over space, so the close
  /// button visually lands near the true right edge rather than stranded
  /// mid-row. `Flex`'s space division happens once, up front, and is never
  /// renegotiated: a flexible child that renders *smaller* than its
  /// allotted share doesn't hand the difference to `Spacer` — that space is
  /// simply gone. `_optionCluster` and `_counterLabel` are `Expanded`
  /// specifically so they can't under-use their share (a `SingleChildScrollView`
  /// or a boxed `Text` always fully occupies the width it's given). The
  /// query field is the one exception — it's capped at 260px and so *can*
  /// render smaller than its share — but giving it a modest flex weight (2,
  /// versus the option cluster's 6) keeps its typical share close to 260 in
  /// the first place, so how much goes unclaimed stays small.
  Widget _findRow(bool hasError) {
    return Row(
      spacing: 6,
      children: [
        _leadingIcon(),
        _modeToggle(),
        _queryField(hasError),
        _optionCluster(),
        _prevArrow(),
        _nextArrow(),
        _counterLabel(hasError),
        const Spacer(flex: 3),
        _closeButton(),
      ],
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _findRow(hasError),
          if (c.mode == FindPanelMode.replace) ...[
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                const SizedBox(width: 22),
                SizedBox(
                  width: 260,
                  child: Tooltip(
                    message: 'Replace with',
                    child: TextField(
                      controller: c.replacement,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Replace with…',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _replaceCurrent(),
                    ),
                  ),
                ),
                _toggle(
                  label: 'Aa→',
                  tooltip: 'Preserve case — re-case each replacement to match '
                      'the text it replaces (ALL CAPS, Capitalised, lower). '
                      'Mixed-case matches keep what you typed.',
                  value: c.preserveCase,
                  onChanged: (v) => setState(() => c.preserveCase = v),
                ),
                Tooltip(
                  message: 'Replace the current match',
                  child: TextButton(
                    onPressed: c.currentMatch != null ? _replaceCurrent : null,
                    child: const Text('Replace'),
                  ),
                ),
                Tooltip(
                  message: c.inSelection
                      ? 'Replace every match within the selection'
                      : 'Replace every match in the document',
                  child: TextButton(
                    onPressed: c.loaded.isNotEmpty ? _replaceAll : null,
                    child: Text(
                      c.inSelection
                          ? 'Replace All in selection'
                          : 'Replace All',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
