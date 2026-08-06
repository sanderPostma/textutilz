import 'dart:async';

import 'package:flutter/widgets.dart';

import 'find_results_panel.dart';
import 'src/rust/api/edit_session.dart';
import 'src/rust/api/search.dart';

/// Which face the panel is showing. The query controller is shared between
/// them, so switching carries the typed text over.
enum FindPanelMode { find, replace, mark }

/// Matches loaded per paged scan. Mirrors SEARCH_WINDOW_ROWS in search.rs.
const int kSearchWindowRows = 4096;

/// Load the next window once the cursor is this close to a loaded edge.
const int kPrefetchMargin = 20;

/// Coalesce keystrokes before scanning.
const Duration kMatchDebounce = Duration(milliseconds: 150);

class MarkedSpan {
  final MatchSpan span;
  final Color color;
  const MarkedSpan(this.span, this.color);
}

/// Owns the find/replace view state: the query, the options, which windows
/// have been scanned, and which match is current. All matching itself happens
/// in Rust — this class only decides *what to ask for and when*.
class FindController extends ChangeNotifier {
  final TextEditingController query = TextEditingController();
  final TextEditingController replacement = TextEditingController();

  FindPanelMode _mode = FindPanelMode.find;
  FindPanelMode get mode => _mode;

  SearchMode searchMode = SearchMode.normal;
  bool matchCase = true;
  bool wholeWord = false;
  bool wrapAround = true;
  bool inSelection = false;
  bool dotMatchesNewline = false;
  bool bookmarkLine = false;

  List<MarkedSpan> markedSpans = [];
  Set<int> markedLines = {};

  /// Re-case each replacement to follow the case of the text it replaces
  /// (ALL CAPS -> ALL CAPS, Capitalised -> Capitalised, lower -> lower).
  /// Mixed-case matches keep the typed replacement verbatim. Rust owns the
  /// rule; this is only the toggle.
  bool preserveCase = false;

  /// Limits the search when [inSelection] is on. Set by the host from the
  /// editor's current selection.
  SpanScope? scope;

  EditSession? _session;
  EditSession? get session => _session;
  int _lineCount = 0;

  final List<MatchSpan> _loaded = [];
  List<MatchSpan> get loaded => List.unmodifiable(_loaded);

  int _currentIndex = -1;
  int get currentIndex => _currentIndex;
  MatchSpan? get currentMatch =>
      (_currentIndex >= 0 && _currentIndex < _loaded.length)
      ? _loaded[_currentIndex]
      : null;

  /// Rows already scanned: [0, _loadedTo). Scanning always starts at row 0
  /// (see `refresh`), so there is no separate lower bound to track.
  int _loadedTo = 0;

  int? _exactTotal;
  int? get exactTotal => _exactTotal;

  bool _sweepRunning = false;
  bool get sweepRunning => _sweepRunning;

  String? _regexError;
  String? get regexError => _regexError;

  /// Bumped on every query/option change. A scan result carrying a stale
  /// generation is discarded rather than appended out of order.
  int _generation = 0;

  Timer? _debounce;
  Future<void>? _sweep;

  /// Point the controller at a document. Clears matches; query and options
  /// persist across tabs, matching Notepad++.
  void attach(EditSession? session, int lineCount) {
    _session = session;
    _lineCount = lineCount;
    _generation++;
    _resetMatches();
    _resetSearchResults();
    _notify();
  }

  /// Tell the controller the document grew or shrank. Paging is bounded by
  /// this, so an edit that adds or removes rows has to update it or later
  /// windows are never scanned (or are scanned past the end).
  void setLineCount(int lineCount) {
    _lineCount = lineCount;
  }

  void setMode(FindPanelMode m) {
    _mode = m;
    _notify();
  }

  /// Re-run the search after a debounce. Call on every keystroke.
  void scheduleRefresh() {
    // Find All rows are a snapshot of this exact query/options combination.
    // Keeping them visible after the query changes would let a click select a
    // span that no longer belongs to the find bar's current match set.
    if (isSearchResultsVisible) {
      _resetSearchResults();
      _notify();
    }
    _debounce?.cancel();
    _debounce = Timer(kMatchDebounce, refresh);
  }

  void _resetMatches() {
    _loaded.clear();
    _currentIndex = -1;
    _loadedTo = 0;
    _exactTotal = null;
    // A sweep from a superseded scan would otherwise never clear this: it
    // checks the generation before writing, and a reset here starts no
    // replacement sweep to do so on its behalf.
    _sweepRunning = false;
  }

  SearchQuery _buildQuery() => SearchQuery(
    pattern: query.text,
    mode: searchMode,
    matchCase: matchCase,
    wholeWord: wholeWord,
    dotMatchesNewline: dotMatchesNewline,
  );

  /// The query as it would be sent to Rust right now. Exposed so the host
  /// can run its own independent scans (e.g. viewport-scoped highlighting)
  /// using the exact same pattern/options without duplicating how they're
  /// packaged into a [SearchQuery].
  SearchQuery get currentQuery => _buildQuery();

  /// The scope actually in force right now: the host-supplied selection when
  /// "In selection" is on, otherwise null (whole document). Every scan —
  /// paging, counting, replacing, and the host's viewport highlighting —
  /// passes this straight to Rust, which is the only place that decides what
  /// "in scope" means (`span_in_scope`). Dart deliberately does no filtering
  /// of its own, so the highlighted set can never disagree with the counted
  /// set.
  SpanScope? get activeScope => inSelection ? scope : null;

  /// Matches to paint for rows `[firstRow, lastRow)`, honouring the active
  /// scope. This is an independent scan from the paging cursor: it covers
  /// only what is on screen, so its cost is proportional to the viewport
  /// rather than to the document or to how far stepping has paged in.
  ///
  /// Lives here rather than in the host so that highlighting shares one code
  /// path — and one scope — with the counter and with Replace All.
  Future<List<MatchSpan>> scanViewport(int firstRow, int lastRow) async {
    final s = _session;
    if (s == null || query.text.isEmpty || firstRow >= lastRow) return const [];
    return s.findInRows(
      query: _buildQuery(),
      fromRow: BigInt.from(firstRow),
      toRow: BigInt.from(lastRow),
      scope: activeScope,
    );
  }

  /// Discard loaded matches and scan forward from the top until at least one
  /// match is found or the document is exhausted.
  ///
  /// When [anchorRow]/[anchorCol] are given, the current match becomes the
  /// first match at or after that position instead of the first in the
  /// document. This is what keeps the cursor from jumping backwards after an
  /// edit or a single replace.
  Future<void> refresh({int? anchorRow, int? anchorCol}) async {
    _debounce?.cancel();
    final gen = ++_generation;

    if (_session == null || query.text.isEmpty) {
      _resetMatches();
      _regexError = null;
      _notify();
      return;
    }

    final error = validateQuery(query: _buildQuery());
    if (error != null) {
      _resetMatches();
      _regexError = error;
      _notify();
      return;
    }
    _regexError = null;
    _resetMatches();

    await _loadForward(gen);
    if (gen != _generation || _isDisposed) return;

    _currentIndex = _anchorIndex(anchorRow, anchorCol);
    // An unanchored refresh is a new search the user just asked for, so the
    // first match should be scrolled to. An *anchored* one is a re-scan after
    // the document changed under us: the current match is re-derived from
    // where the caret already is, and scrolling there would fight the user.
    if (anchorRow == null) _revealTick++;
    _notify();
    unawaited(_startSweep(gen));
  }

  /// Index of the first loaded match at or after the anchor, or 0 when there
  /// is no anchor or nothing follows it.
  int _anchorIndex(int? anchorRow, int? anchorCol) {
    if (_loaded.isEmpty) return -1;
    if (anchorRow == null || anchorCol == null) return 0;
    for (int i = 0; i < _loaded.length; i++) {
      final s = _loaded[i];
      final row = s.startRow.toInt();
      final col = s.startCol.toInt();
      if (row > anchorRow || (row == anchorRow && col >= anchorCol)) return i;
    }
    return 0;
  }

  /// Scan windows forward until a match is found or the end is reached.
  Future<void> _loadForward(int gen) async {
    while (_loadedTo < _lineCount) {
      await _loadNextWindow(gen);
      if (gen != _generation) return;
      if (_loaded.isNotEmpty) return;
    }
  }

  /// Bumped only when the *user* asked to move to a match: a step, a wrap, a
  /// replace, or a freshly typed query. The host scrolls the editor to the
  /// current match when this changes, and only then.
  ///
  /// A plain `notifyListeners` is far too broad a signal for that: the
  /// controller also notifies when a background sweep resolves the exact
  /// total, when a prefetch lands, and when the document is re-scanned after
  /// an edit. Revealing on those would drag the editor back to the current
  /// match after the user had scrolled elsewhere, and — worse — would steal
  /// the caret mid-keystroke every time the post-edit re-scan settled.
  int _revealTick = 0;
  int get revealTick => _revealTick;

  bool get canStepForward =>
      _loaded.isNotEmpty &&
      (wrapAround ||
          _currentIndex < _loaded.length - 1 ||
          _loadedTo < _lineCount);

  bool get canStepBackward =>
      _loaded.isNotEmpty && (wrapAround || _currentIndex > 0);

  Future<void> stepForward() async {
    if (_loaded.isEmpty) return;
    final gen = _generation;
    if (_currentIndex < _loaded.length - 1) {
      _currentIndex++;
      _revealTick++;
      _notify();
      _maybePrefetch();
      return;
    }
    // Page forward until a further match turns up or the document runs out.
    // One window is not enough: `_loadForward` stops as soon as `_loaded` is
    // non-empty, which it already is here, so a window with no matches in it
    // would drop through to the wrap below while matches still lay ahead.
    while (_loadedTo < _lineCount && _currentIndex >= _loaded.length - 1) {
      await _loadNextWindow(gen);
      if (gen != _generation) return;
    }
    if (_currentIndex < _loaded.length - 1) {
      _currentIndex++;
      _revealTick++;
      _notify();
      // Same as the fast path above: having just moved, keep the window
      // after this one warm so the *next* press doesn't wait either.
      _maybePrefetch();
      return;
    }
    // Only wrap once the document really is exhausted. With several
    // `stepForward()` calls in flight, a step whose window load joined
    // another's can arrive here with matches still unscanned ahead of it, and
    // wrapping then would jump the user back to the first match mid-document.
    if (wrapAround && _loadedTo >= _lineCount) {
      _currentIndex = 0;
      _revealTick++;
      _notify();
    }
  }

  /// Step to the previous loaded match, or wrap to the last match when
  /// [wrapAround] is on. Scanning always starts at row 0 (see `refresh`), so
  /// there is never a preceding, not-yet-loaded window to page in — unlike
  /// `stepForward`, this never needs to fetch anything to move backward
  /// within already-loaded matches.
  Future<void> stepBackward() async {
    if (_loaded.isEmpty) return;
    final gen = _generation;
    if (_currentIndex > 0) {
      _currentIndex--;
      _revealTick++;
      _notify();
      _maybePrefetch();
      return;
    }
    if (wrapAround) {
      // Wrapping to the end needs every match loaded.
      while (_loadedTo < _lineCount) {
        await _loadNextWindow(gen);
        if (gen != _generation) return;
      }
      _currentIndex = _loaded.length - 1;
      _revealTick++;
      _notify();
    }
  }

  Future<void> _loadForwardOneWindow(int gen) async {
    final from = _loadedTo;
    final to = (from + kSearchWindowRows).clamp(0, _lineCount);
    final found = await _session!.findInRows(
      query: _buildQuery(),
      fromRow: BigInt.from(from),
      toRow: BigInt.from(to),
      scope: activeScope,
    );
    if (gen != _generation) return;
    _loadedTo = to;
    _loaded.addAll(found);
  }

  /// The single in-flight window load, or null when none is running.
  ///
  /// Every path that pages in a window — a background prefetch, a step that
  /// ran off the loaded edge, and the backward-wrap sweep — goes through
  /// [_loadNextWindow], so at most one request for the next window exists at
  /// a time. Without this, two paths could each read `_loadedTo` before their
  /// first await, request the SAME window, and both append its matches:
  /// duplicates in `loaded`, a counter reading e.g. "30 of 25", and F3
  /// visiting a line twice.
  ///
  /// A caller arriving while a load is in flight *awaits* it rather than
  /// skipping it: it got here because the user pressed a key and expects to
  /// move once the window lands.
  Future<void>? _windowLoad;

  /// Load the next unscanned window, or join the one already in flight.
  Future<void> _loadNextWindow(int gen) {
    final pending = _windowLoad;
    if (pending != null) return pending;
    late final Future<void> load;
    load = _loadForwardOneWindow(gen).whenComplete(() {
      // Only clear our own; a later load may already have claimed the slot.
      if (identical(_windowLoad, load)) _windowLoad = null;
    });
    _windowLoad = load;
    return load;
  }

  /// Load the adjacent window in the background when the cursor nears an edge,
  /// so the next arrow press never waits on a scan.
  void _maybePrefetch() {
    if (_windowLoad != null) return;
    final gen = _generation;
    if (_loaded.length - _currentIndex <= kPrefetchMargin &&
        _loadedTo < _lineCount) {
      unawaited(
        _loadNextWindow(gen).then((_) {
          if (gen == _generation) _notify();
        }),
      );
    }
  }

  /// Count every match in the background so the counter can resolve from
  /// "1 of 3+" to "1 of 3".
  Future<void> _startSweep(int gen) async {
    // Disposed mid-flight: don't start new work, and in particular don't read
    // `query.text` — the TextEditingControllers are gone by now.
    if (_session == null || _isDisposed) return;
    _sweepRunning = true;
    _sweepGen = gen;
    _notify();
    final future = () async {
      final total = await _session!.countMatches(
        query: _buildQuery(),
        scope: activeScope,
      );
      if (gen != _generation) return;
      _exactTotal = total.toInt();
      _sweepRunning = false;
      _notify();
    }();
    _sweep = future;
    await future;
  }

  /// The generation the in-flight sweep was started for. A sweep for a
  /// superseded generation discards its own result, so waiting on it resolves
  /// nothing — [recount] has to start a fresh one instead.
  int _sweepGen = -1;

  /// Test hook: wait for the in-flight sweep to finish.
  Future<void> awaitSweep() async => _sweep == null ? null : await _sweep;

  /// The Count button: resolve the exact total now. Reuses the in-flight
  /// sweep when there is one rather than scanning the document twice — but
  /// only when that sweep is for the *current* generation. A sweep started
  /// before the query or options changed throws its own result away, so
  /// awaiting it would return the stale previous total.
  Future<int?> recount() async {
    if (_sweepRunning && _sweepGen == _generation) {
      await awaitSweep();
      if (_sweepGen == _generation && _exactTotal != null) return _exactTotal;
    }
    await _startSweep(_generation);
    return _exactTotal;
  }

  String get counterLabel {
    if (_regexError != null) return 'Invalid pattern';
    if (query.text.isEmpty) return '';
    if (_loaded.isEmpty) return 'No results';
    final position = _currentIndex + 1;
    if (_exactTotal != null) return '$position of $_exactTotal';
    final soFar = _loaded.length;
    return _loadedTo >= _lineCount
        ? '$position of $soFar'
        : '$position of $soFar+';
  }

  /// Replace the current match and advance. Returns the number replaced (0 or 1).
  Future<int> replaceCurrent() async {
    final span = currentMatch;
    if (span == null || _session == null) return 0;
    final caret = await _session!.replaceSpan(
      query: _buildQuery(),
      span: span,
      replacement: replacement.text,
      preserveCase: preserveCase,
    );
    _lineCount = _session!.lineCount().toInt();
    // Anchor past the text just written, so the next match is the one after
    // it rather than an earlier one that is still in the document.
    await refresh(anchorRow: caret.row.toInt(), anchorCol: caret.col.toInt());
    _revealTick++;
    _notify();
    return 1;
  }

  /// Replace every match (within scope when In selection is on) as one undo
  /// step. Returns the number replaced.
  Future<int> replaceAll() async {
    if (_session == null) return 0;
    final n = await _session!.replaceAllInRows(
      query: _buildQuery(),
      replacement: replacement.text,
      scope: activeScope,
      preserveCase: preserveCase,
    );
    _lineCount = _session!.lineCount().toInt();
    await refresh();
    return n.toInt();
  }

  static const List<Color> markColors = [
    Color(0x8000E5FF), // Cyan
    Color(0x80FF9100), // Orange
    Color(0x80C6FF00), // Lime
    Color(0x80E040FB), // Purple
    Color(0x8000E676), // Green
    Color(0x80FF1744), // Red
  ];

  int _markColorIndex = 0;

  /// Mark all matches across the document (or within scope if active).
  /// Appends newly marked spans with the next cycling color, preserving past marks.
  Future<int> markAll() async {
    final s = _session;
    if (s == null || query.text.isEmpty) {
      _notify();
      return 0;
    }
    final found = await s.findInRows(
      query: _buildQuery(),
      fromRow: BigInt.zero,
      toRow: BigInt.from(_lineCount),
      scope: activeScope,
    );
    final color = markColors[_markColorIndex % markColors.length];
    _markColorIndex++;
    for (final span in found) {
      markedSpans.add(MarkedSpan(span, color));
      if (bookmarkLine) {
        markedLines.add(span.startRow.toInt());
      }
    }
    _notify();
    return found.length;
  }

  /// Clear all active marks and bookmarked lines.
  void clearMarks() {
    markedSpans.clear();
    markedLines.clear();
    _markColorIndex = 0;
    _notify();
  }

  List<FindResultItem> _searchResults = const [];
  List<FindResultItem> get searchResults => List.unmodifiable(_searchResults);
  bool isSearchResultsVisible = false;
  bool isSearchResultsLoading = false;
  String searchResultsQuery = '';
  String? searchResultsError;

  int _findAllGeneration = 0;

  void _resetSearchResults() {
    _findAllGeneration++;
    _searchResults = const [];
    isSearchResultsVisible = false;
    isSearchResultsLoading = false;
    searchResultsQuery = '';
    searchResultsError = null;
  }

  /// Find all matches across the document and populate the bottom dock.
  ///
  /// The scan is paged so a large document is never copied across the bridge
  /// in one enormous request. Results from a superseded query, edit, or tab
  /// switch are discarded using [_findAllGeneration].
  Future<int> findAll() async {
    final s = _session;
    if (s == null || query.text.isEmpty) {
      _resetSearchResults();
      _notify();
      return 0;
    }

    final searchQuery = _buildQuery();
    final error = validateQuery(query: searchQuery);
    if (error != null) {
      _findAllGeneration++;
      _searchResults = const [];
      isSearchResultsVisible = true;
      isSearchResultsLoading = false;
      searchResultsQuery = query.text;
      searchResultsError = error;
      _notify();
      return 0;
    }

    final generation = ++_findAllGeneration;
    final resultQuery = query.text;
    final resultScope = activeScope;
    final lineCount = _lineCount;
    final found = <MatchSpan>[];

    _searchResults = const [];
    isSearchResultsVisible = true;
    isSearchResultsLoading = true;
    searchResultsQuery = resultQuery;
    searchResultsError = null;
    _notify();

    try {
      for (int from = 0; from < lineCount; from += kSearchWindowRows) {
        final to = (from + kSearchWindowRows).clamp(0, lineCount);
        final page = await s.findInRows(
          query: searchQuery,
          fromRow: BigInt.from(from),
          toRow: BigInt.from(to),
          scope: resultScope,
        );
        if (generation != _findAllGeneration || !identical(s, _session)) {
          return 0;
        }
        found.addAll(page);
      }

      _searchResults = found
          .map((span) {
            String lineText;
            try {
              lineText = s.line(vrow: span.startRow);
            } catch (_) {
              lineText = '';
            }
            return FindResultItem(span, lineText);
          })
          .toList(growable: false);
    } catch (error) {
      if (generation != _findAllGeneration || !identical(s, _session)) {
        return 0;
      }
      _searchResults = const [];
      searchResultsError = error.toString();
    }

    if (generation != _findAllGeneration || !identical(s, _session)) return 0;
    isSearchResultsLoading = false;
    _notify();
    return _searchResults.length;
  }

  /// Hide the bottom search results pane.
  void closeSearchResults() {
    _findAllGeneration++;
    isSearchResultsVisible = false;
    isSearchResultsLoading = false;
    _notify();
  }

  /// Make a Find All row the same current match used by the find bar and the
  /// editor's accented match layer.
  void selectSearchResult(MatchSpan span) {
    final index = _searchResults.indexWhere(
      (item) =>
          item.span.startRow == span.startRow &&
          item.span.startCol == span.startCol &&
          item.span.endRow == span.endRow &&
          item.span.endCol == span.endCol,
    );
    if (index < 0) return;

    // Invalidate paging/count work for the previous partial match list, then
    // promote the already-complete Find All snapshot into the stepping list.
    _generation++;
    _loaded
      ..clear()
      ..addAll(_searchResults.map((item) => item.span));
    _loadedTo = _lineCount;
    _exactTotal = _loaded.length;
    _sweepRunning = false;
    _currentIndex = index;
    _revealTick++;
    _notify();
  }

  /// Extracts the marked text (or bookmarked lines if bookmarkLine is set) as a single string.
  String copyMarkedText() {
    final s = _session;
    if (s == null || markedSpans.isEmpty) return '';
    final StringBuffer sb = StringBuffer();
    if (bookmarkLine && markedLines.isNotEmpty) {
      final sortedLines = markedLines.toList()..sort();
      for (final lineIdx in sortedLines) {
        try {
          sb.writeln(s.line(vrow: BigInt.from(lineIdx)));
        } catch (_) {}
      }
    } else {
      for (final item in markedSpans) {
        final span = item.span;
        try {
          final r1 = span.startRow.toInt();
          final c1 = span.startCol.toInt();
          final r2 = span.endRow.toInt();
          final c2 = span.endCol.toInt();
          if (r1 == r2) {
            final line = s.line(vrow: BigInt.from(r1));
            final end = c2.clamp(0, line.length);
            final start = c1.clamp(0, end);
            sb.writeln(line.substring(start, end));
          } else {
            for (int r = r1; r <= r2; r++) {
              final line = s.line(vrow: BigInt.from(r));
              if (r == r1) {
                sb.writeln(line.substring(c1.clamp(0, line.length)));
              } else if (r == r2) {
                sb.write(line.substring(0, c2.clamp(0, line.length)));
              } else {
                sb.writeln(line);
              }
            }
            sb.writeln();
          }
        } catch (_) {}
      }
    }
    return sb.toString();
  }

  /// Notify listeners unless this controller has already been disposed.
  ///
  /// Scans, sweeps and prefetches all notify *after* an await, by which time
  /// the host may have torn the panel down — and `ChangeNotifier` throws
  /// "A FindController was used after being disposed" in that case. Every
  /// post-await notification goes through here.
  void _notify() {
    if (_isDisposed) return;
    notifyListeners();
  }

  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    // Retire the generation as well as flagging disposal. `_notify` already
    // guards the disposed case, but a `_loadForward` or sweep loop already in
    // flight tests the generation, not the flag, and would otherwise page the
    // whole document after the panel closed.
    _generation++;
    _debounce?.cancel();
    query.dispose();
    replacement.dispose();
    super.dispose();
  }
}
