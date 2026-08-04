import 'dart:async';

import 'package:flutter/widgets.dart';

import 'src/rust/api/edit_session.dart';
import 'src/rust/api/search.dart';

/// Which face the panel is showing. The query controller is shared between
/// them, so switching carries the typed text over.
enum FindPanelMode { find, replace }

/// Matches loaded per paged scan. Mirrors SEARCH_WINDOW_ROWS in search.rs.
const int kSearchWindowRows = 4096;

/// Load the next window once the cursor is this close to a loaded edge.
const int kPrefetchMargin = 20;

/// Coalesce keystrokes before scanning.
const Duration kMatchDebounce = Duration(milliseconds: 150);

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

  /// Rows already scanned: [_loadedFrom, _loadedTo).
  int _loadedFrom = 0;
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
    notifyListeners();
  }

  void setMode(FindPanelMode m) {
    _mode = m;
    notifyListeners();
  }

  /// Re-run the search after a debounce. Call on every keystroke.
  void scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(kMatchDebounce, refresh);
  }

  void _resetMatches() {
    _loaded.clear();
    _currentIndex = -1;
    _loadedFrom = 0;
    _loadedTo = 0;
    _exactTotal = null;
  }

  SearchQuery _buildQuery() => SearchQuery(
        pattern: query.text,
        mode: searchMode,
        matchCase: matchCase,
        wholeWord: wholeWord,
        dotMatchesNewline: dotMatchesNewline,
      );

  SpanScope? get _activeScope => inSelection ? scope : null;

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
      notifyListeners();
      return;
    }

    final error = validateQuery(query: _buildQuery());
    if (error != null) {
      _resetMatches();
      _regexError = error;
      notifyListeners();
      return;
    }
    _regexError = null;
    _resetMatches();

    await _loadForward(gen);
    if (gen != _generation) return;

    _currentIndex = _anchorIndex(anchorRow, anchorCol);
    notifyListeners();
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
      final from = _loadedTo;
      final to = (from + kSearchWindowRows).clamp(0, _lineCount);
      final found = await _session!.findInRows(
        query: _buildQuery(),
        fromRow: BigInt.from(from),
        toRow: BigInt.from(to),
      );
      if (gen != _generation) return;
      _loadedTo = to;
      _loaded.addAll(_inScope(found));
      if (_loaded.isNotEmpty) return;
    }
  }

  /// Scan windows backward until a match is found or the top is reached.
  Future<void> _loadBackward(int gen) async {
    while (_loadedFrom > 0) {
      final to = _loadedFrom;
      final from = (to - kSearchWindowRows).clamp(0, _lineCount);
      final found = await _session!.findInRows(
        query: _buildQuery(),
        fromRow: BigInt.from(from),
        toRow: BigInt.from(to),
      );
      if (gen != _generation) return;
      _loadedFrom = from;
      final fresh = _inScope(found);
      final hadIndex = _currentIndex >= 0;
      _loaded.insertAll(0, fresh);
      if (hadIndex) _currentIndex += fresh.length;
      if (fresh.isNotEmpty) return;
    }
  }

  List<MatchSpan> _inScope(List<MatchSpan> spans) {
    final sc = _activeScope;
    if (sc == null) return spans;
    return spans.where((s) {
      final afterStart = s.startRow > sc.startRow ||
          (s.startRow == sc.startRow && s.startCol >= sc.startCol);
      final beforeEnd = s.endRow < sc.endRow ||
          (s.endRow == sc.endRow && s.endCol <= sc.endCol);
      return afterStart && beforeEnd;
    }).toList();
  }

  bool get canStepForward =>
      _loaded.isNotEmpty &&
      (wrapAround || _currentIndex < _loaded.length - 1 || _loadedTo < _lineCount);

  bool get canStepBackward =>
      _loaded.isNotEmpty && (wrapAround || _currentIndex > 0 || _loadedFrom > 0);

  Future<void> stepForward() async {
    if (_loaded.isEmpty) return;
    if (_currentIndex < _loaded.length - 1) {
      _currentIndex++;
      notifyListeners();
      _maybePrefetch();
      return;
    }
    if (_loadedTo < _lineCount) {
      await _loadForward(_generation);
      if (_currentIndex < _loaded.length - 1) {
        _currentIndex++;
        notifyListeners();
        return;
      }
    }
    if (wrapAround) {
      _currentIndex = 0;
      notifyListeners();
    }
  }

  Future<void> stepBackward() async {
    if (_loaded.isEmpty) return;
    if (_currentIndex > 0) {
      _currentIndex--;
      notifyListeners();
      _maybePrefetch();
      return;
    }
    if (_loadedFrom > 0) {
      await _loadBackward(_generation);
      if (_currentIndex > 0) {
        _currentIndex--;
        notifyListeners();
        return;
      }
    }
    if (wrapAround) {
      // Wrapping to the end needs every match loaded.
      while (_loadedTo < _lineCount) {
        await _loadForwardOneWindow(_generation);
      }
      _currentIndex = _loaded.length - 1;
      notifyListeners();
    }
  }

  Future<void> _loadForwardOneWindow(int gen) async {
    final from = _loadedTo;
    final to = (from + kSearchWindowRows).clamp(0, _lineCount);
    final found = await _session!.findInRows(
      query: _buildQuery(),
      fromRow: BigInt.from(from),
      toRow: BigInt.from(to),
    );
    if (gen != _generation) return;
    _loadedTo = to;
    _loaded.addAll(_inScope(found));
  }

  /// Load the adjacent window in the background when the cursor nears an edge,
  /// so the next arrow press never waits on a scan.
  void _maybePrefetch() {
    final gen = _generation;
    if (_loaded.length - _currentIndex <= kPrefetchMargin &&
        _loadedTo < _lineCount) {
      unawaited(_loadForwardOneWindow(gen).then((_) {
        if (gen == _generation) notifyListeners();
      }));
    } else if (_currentIndex <= kPrefetchMargin && _loadedFrom > 0) {
      unawaited(_loadBackward(gen).then((_) {
        if (gen == _generation) notifyListeners();
      }));
    }
  }

  /// Count every match in the background so the counter can resolve from
  /// "1 of 3+" to "1 of 3".
  Future<void> _startSweep(int gen) async {
    if (_session == null) return;
    _sweepRunning = true;
    notifyListeners();
    final future = () async {
      final total = await _session!.countMatches(
        query: _buildQuery(),
        scope: _activeScope,
      );
      if (gen != _generation) return;
      _exactTotal = total.toInt();
      _sweepRunning = false;
      notifyListeners();
    }();
    _sweep = future;
    await future;
  }

  /// Test hook: wait for the in-flight sweep to finish.
  Future<void> awaitSweep() async => _sweep == null ? null : await _sweep;

  /// The Count button: resolve the exact total now. Reuses the in-flight
  /// sweep when there is one rather than scanning the document twice.
  Future<int?> recount() async {
    if (_sweepRunning) {
      await awaitSweep();
    } else {
      await _startSweep(_generation);
    }
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
    );
    _lineCount = _session!.lineCount().toInt();
    // Anchor past the text just written, so the next match is the one after
    // it rather than an earlier one that is still in the document.
    await refresh(anchorRow: caret.row.toInt(), anchorCol: caret.col.toInt());
    return 1;
  }

  /// Replace every match (within scope when In selection is on) as one undo
  /// step. Returns the number replaced.
  Future<int> replaceAll() async {
    if (_session == null) return 0;
    final n = await _session!.replaceAllInRows(
      query: _buildQuery(),
      replacement: replacement.text,
      scope: _activeScope,
    );
    _lineCount = _session!.lineCount().toInt();
    await refresh();
    return n.toInt();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    replacement.dispose();
    super.dispose();
  }
}
