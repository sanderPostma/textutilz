import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:textutilz/find_state.dart';
import 'package:textutilz/fold_map.dart';
import 'package:textutilz/markup_styling.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/search.dart';
import 'package:textutilz/src/rust/api/structured.dart';

class SelectionRange {
  final int startRow;
  final int startCol;
  final int endRow;
  final int endCol;
  const SelectionRange(this.startRow, this.startCol, this.endRow, this.endCol);
}

class EditorSettings {
  static int tabSize = 4;
}

/// Width of the editor's horizontal scroll content, in logical pixels.
///
/// It must be wide enough that the caret placed at the end of the longest
/// relevant line — plus the small look-ahead used when scrolling the caret
/// into view — is reachable. If the content is narrower than that, scrolling
/// to the caret overscrolls and [ClampingScrollPhysics] settles it back (the
/// "bounce"), leaving the last word off-screen and uneditable.
double editorContentWidth(int maxLineLength, double charWidth) {
  const double caretPadding = 24.0; // > the 20px look-ahead in _scrollToCursor
  const double trailingChars =
      6.0; // a little breathing room past the last glyph
  return maxLineLength * charWidth + trailingChars * charWidth + caretPadding;
}

/// Normalize a selection anchor/head pair `(anchorRow, anchorCol)` →
/// `(headRow, headCol)` into `(startRow, startCol, endRow, endCol)` with
/// start always at or before end, regardless of which way the user dragged.
(int, int, int, int) normalizeSelection(
  int anchorRow,
  int anchorCol,
  int headRow,
  int headCol,
) {
  var sr = anchorRow;
  var sc = anchorCol;
  var er = headRow;
  var ec = headCol;
  if (sr > er || (sr == er && sc > ec)) {
    final tr = sr, tc = sc;
    sr = er;
    sc = ec;
    er = tr;
    ec = tc;
  }
  return (sr, sc, er, ec);
}

class CustomEditor extends StatefulWidget {
  /// The Rust-owned editable document. All text mutations and undo/redo go
  /// through this; the editor holds only view/cursor state.
  final EditSession session;
  final double fontSize;

  /// When true, a line-number gutter is drawn at the left; text and cursor
  /// shift right by the gutter width.
  final bool showLineNumbers;
  final void Function(int row, int col, int selChars, int selLines)?
  onCursorChanged;
  final VoidCallback? onContentChanged;
  final ValueChanged<double>? onFontSizeChanged;
  final bool readOnly;

  /// The document's detected format, or null for plain text. Text layout and
  /// editing stay owned by the editor; the language only selects which Rust
  /// lexer supplies presentation spans.
  final StructuredLanguage? markupLanguage;

  /// Validation problems to mark in the text. Supplied by the host from the
  /// last validation run; empty when nothing has been validated.
  final List<StructuredDiagnostic> diagnostics;

  /// Matches to highlight, and which of them is current. Supplied by the host
  /// from the find panel; already scoped to the visible rows.
  final List<MatchSpan> matches;
  final MatchSpan? currentMatch;

  /// Marked spans and bookmarked lines to display persistently across the editor.
  final List<MarkedSpan> markedSpans;
  final Set<int> markedLines;

  /// Fold start rows to collapse when this editor is built, restored with the
  /// session. Read once per document — later changes travel outwards through
  /// [onCollapsedFoldsChanged] and are not pushed back in, so the editor stays
  /// the owner of the live set while the tab is open.
  final Set<int> initialCollapsedFolds;

  /// Fired when the collapsed set changes, including when a rescan drops rows
  /// that no longer start a fold. The host stores it on the document so it
  /// survives a tab switch and a restart.
  final ValueChanged<Set<int>>? onCollapsedFoldsChanged;

  /// Fired whenever the visible row range may have changed (scroll, resize).
  /// The host re-reads [CustomEditorState.visibleRowRange] itself rather than
  /// this callback carrying the range, so it stays cheap to fire often.
  final VoidCallback? onViewportChanged;

  const CustomEditor({
    super.key,
    required this.session,
    this.fontSize = 14.0,
    this.showLineNumbers = false,
    this.readOnly = false,
    this.markupLanguage,
    this.onCursorChanged,
    this.diagnostics = const [],
    this.onContentChanged,
    this.onFontSizeChanged,
    this.matches = const [],
    this.currentMatch,
    this.markedSpans = const [],
    this.markedLines = const {},
    this.onViewportChanged,
    this.initialCollapsedFolds = const <int>{},
    this.onCollapsedFoldsChanged,
  });

  @override
  State<CustomEditor> createState() => CustomEditorState();
}

class CustomEditorState extends State<CustomEditor> {
  // ---- Structured-format presentation --------------------------------------

  /// The pair the caret is on or inside. Recomputed only when the caret moves
  /// or the document changes, never during paint.
  StructuredPair? _markupPair;

  // ---- Folding -------------------------------------------------------------

  /// Every collapsible region in the document, from the Rust lexer.
  List<StructuredFold> _folds = const [];

  /// Start rows of the regions the user has collapsed.
  final Set<int> _collapsedFolds = <int>{};

  /// Document rows to display rows. Rebuilt whenever either input changes.
  FoldMap _foldMap = FoldMap.identity(0);

  /// Row count the fold regions were last scanned for. Used to notice that the
  /// editor is showing a document nothing has scanned yet — which is how the
  /// fold gutter went missing on a freshly opened file.
  int? _foldsScannedForRows;

  /// Recomputing folds is a whole-document pass, so it is debounced rather than
  /// run per keystroke.
  Timer? _foldRefreshDebounce;
  static const Duration _foldRefreshDelay = Duration(milliseconds: 250);

  int get _displayRowCount => _foldMap.displayRowCount;

  /// Rows currently drawn, i.e. the document minus anything collapsed. Public
  /// so a test can assert that folding changed the view and nothing else.
  int get displayRowCount => _displayRowCount;

  /// The caret's document row.
  int get cursorRow => _cursorRow;

  /// Whether this document has any collapsible region at all. Drives whether
  /// the View menu's fold entries are offered.
  bool get hasFolds => _folds.isNotEmpty;

  int _displayToDoc(int slot) => _foldMap.displayToDoc(slot);

  int _docToDisplay(int row) => _foldMap.docToDisplay(row);

  /// The next visible row below [row], or [row] if there is none.
  int _rowBelow(int row) => _foldMap.nextVisible(row + 1) ?? row;

  /// The next visible row above [row], or [row] if there is none.
  int _rowAbove(int row) => _foldMap.previousVisible(row - 1) ?? row;

  /// The last visible row in the document.
  int get _lastVisibleRow =>
      _foldMap.previousVisible(math.max(0, _visualLineCount - 1)) ?? 0;

  /// Rebuild the map if the document's row count moved under it.
  ///
  /// Without this an unfolded document keeps the `FoldMap.identity(0)` it was
  /// constructed with, and every row lookup clamps to zero.
  void _syncFoldMap() {
    if (_foldMap.docRowCount != _visualLineCount) _rebuildFoldMap();
  }

  void _rebuildFoldMap() {
    _foldMap = FoldMap.from(
      docRowCount: _visualLineCount,
      folds: _folds,
      collapsed: _collapsedFolds,
    );
  }

  /// Re-read the fold regions for the current document.
  void _refreshFolds() {
    if (!mounted) return;
    _foldsScannedForRows = _visualLineCount;
    if (!_hasMarkup) {
      setState(() {
        _folds = const [];
        _collapsedFolds.clear();
        _rebuildFoldMap();
      });
      return;
    }
    List<StructuredFold> folds;
    try {
      folds = widget.session
          .markupAnalysis(language: widget.markupLanguage!)
          .folds;
    } catch (_) {
      folds = const [];
    }
    final before = _collapsedFolds.length;
    setState(() {
      _folds = folds;
      // Drop collapses whose region no longer exists, so an edit that deletes a
      // block does not leave rows hidden with no way to bring them back.
      final starts = folds.map((f) => f.startRow).toSet();
      _collapsedFolds.removeWhere((row) => !starts.contains(row));
      _rebuildFoldMap();
    });
    // A prune is a change like any other: the host should not persist rows
    // that no longer name a fold.
    if (_collapsedFolds.length != before) {
      widget.onCollapsedFoldsChanged?.call(Set<int>.of(_collapsedFolds));
    }
  }

  void _scheduleFoldRefresh() {
    _foldsScannedForRows = _visualLineCount;
    _foldRefreshDebounce?.cancel();
    _foldRefreshDebounce = Timer(_foldRefreshDelay, _refreshFolds);
  }

  /// Apply a change to the set of collapsed regions.
  ///
  /// Every fold command goes through here so the map is rebuilt and a stranded
  /// caret rescued exactly once, in one place.
  void _applyCollapseChange(void Function() mutate) {
    setState(() {
      mutate();
      _rebuildFoldMap();
      // A caret left inside a region that just closed would be editing text
      // nobody can see; move it to the header instead.
      if (_foldMap.isHidden(_cursorRow)) {
        _cursorRow = _foldMap.previousVisible(_cursorRow) ?? 0;
        _cursorCol = _cursorCol.clamp(0, _getLineLength(_cursorRow));
        _selStartRow = null;
        _selStartCol = null;
      }
    });
    // After the frame's own setState, not inside it: the host will set its own
    // state in response, and doing that from within ours is a build-time write.
    widget.onCollapsedFoldsChanged?.call(Set<int>.of(_collapsedFolds));
  }

  /// Collapse or expand the region starting at [docRow].
  void toggleFoldAt(int docRow) {
    if (!_folds.any((f) => f.startRow == docRow)) return;
    _applyCollapseChange(() {
      if (!_collapsedFolds.remove(docRow)) _collapsedFolds.add(docRow);
    });
  }

  /// Collapse every region in the document.
  void foldAll() => foldToLevel(1);

  /// Expand every region in the document.
  void unfoldAll() {
    if (_collapsedFolds.isEmpty) return;
    _applyCollapseChange(_collapsedFolds.clear);
  }

  /// Collapse every region nested [level] deep or deeper, and open everything
  /// above it. [level] is 1-based, as the user sees it: level 1 is the
  /// outermost region, so `foldToLevel(1)` is fold-all.
  ///
  /// This *replaces* the collapse set rather than adding to it — asking for
  /// level 2 after level 1 has to open the outer region again, or the answer
  /// would be indistinguishable from level 1.
  void foldToLevel(int level) {
    final depth = math.max(1, level) - 1;
    final wanted = _folds
        .where((f) => f.level >= depth)
        .map((f) => f.startRow)
        .toSet();
    if (wanted.length == _collapsedFolds.length &&
        wanted.containsAll(_collapsedFolds)) {
      return;
    }
    _applyCollapseChange(() {
      _collapsedFolds
        ..clear()
        ..addAll(wanted);
    });
  }

  /// Expand the regions nested exactly [level] deep, leaving the collapsed
  /// state of anything deeper alone — re-collapsing the parent hides them
  /// again with their own state intact.
  void unfoldLevel(int level) {
    final depth = math.max(1, level) - 1;
    final starts = _folds
        .where((f) => f.level == depth)
        .map((f) => f.startRow)
        .where(_collapsedFolds.contains)
        .toSet();
    if (starts.isEmpty) return;
    _applyCollapseChange(() => _collapsedFolds.removeAll(starts));
  }

  /// Collapse the innermost open region around the caret. Pressing it again
  /// therefore walks outwards, since the region just closed is skipped.
  void collapseAtCursor() {
    final fold = _innermostFoldAt(_cursorRow, collapsed: false);
    if (fold == null) return;
    _applyCollapseChange(() => _collapsedFolds.add(fold.startRow));
  }

  /// Expand the innermost collapsed region around the caret, the mirror of
  /// [collapseAtCursor].
  void expandAtCursor() {
    final fold = _innermostFoldAt(_cursorRow, collapsed: true);
    if (fold == null) return;
    _applyCollapseChange(() => _collapsedFolds.remove(fold.startRow));
  }

  /// The deepest region containing [docRow] that is currently collapsed or
  /// not, per [collapsed]. Null when there is none.
  StructuredFold? _innermostFoldAt(int docRow, {required bool collapsed}) {
    StructuredFold? best;
    for (final fold in _folds) {
      if (docRow < fold.startRow || docRow > fold.endRow) continue;
      if (_collapsedFolds.contains(fold.startRow) != collapsed) continue;
      if (best == null || fold.level > best.level) best = fold;
    }
    return best;
  }

  /// Expand every collapsed region hiding [docRow]. Called before an edit lands
  /// there, so text is never modified while invisible.
  void _revealRow(int docRow) {
    final hiding = _foldMap.collapsedRegionsHiding(
      docRow: docRow,
      folds: _folds,
      collapsed: _collapsedFolds,
    );
    if (hiding.isEmpty) return;
    _applyCollapseChange(() => _collapsedFolds.removeAll(hiding));
  }

  /// True when this document has a Rust lexer behind it.
  bool get _hasMarkup {
    final language = widget.markupLanguage;
    return language != null && MarkupStyling.isStructured(language);
  }

  /// Syntax tokens for `[from, to)`. Handed to the painter as a callback so
  /// only the rows actually being drawn are ever lexed.
  List<StructuredRowTokens> _markupTokensFor(int from, int to) {
    if (!_hasMarkup) return const [];
    try {
      return widget.session.markupTokens(
        language: widget.markupLanguage!,
        fromRow: BigInt.from(from),
        toRow: BigInt.from(to),
      );
    } catch (_) {
      // Colouring must never take the editor down. A document mid-edit can
      // briefly disagree with the row count the painter is working from.
      return const [];
    }
  }

  /// Refresh the matched-pair highlight for the caret's current position.
  void _updateMarkupPair() {
    if (!mounted) return;
    if (!_hasMarkup) {
      if (_markupPair != null) setState(() => _markupPair = null);
      return;
    }
    StructuredPair? found;
    try {
      found = widget.session.markupPairAt(
        language: widget.markupLanguage!,
        row: BigInt.from(_cursorRow),
        col: BigInt.from(_cursorCol),
      );
    } catch (_) {
      found = null;
    }
    if (found != _markupPair) {
      setState(() => _markupPair = found);
    }
  }

  // Ctrl+<key> combos the editor forwards to app-level shortcuts instead of
  // handling itself (save / open / close tab / new).
  static final Set<LogicalKeyboardKey> _bubbleShortcutKeys = {
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyO,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyN,
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyR,
    LogicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyG,
    LogicalKeyboardKey.keyM,
  };

  /// Alt+<digit> is the folding family (Alt+0 fold all, Alt+1..8 fold to a
  /// level). Kept apart from [_bubbleShortcutKeys] because that set is only
  /// consulted while Ctrl is down; these carry Alt instead, and would
  /// otherwise be typed into the document as digits.
  static final Set<LogicalKeyboardKey> _bubbleAltDigits = {
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
  };

  final ScrollController _vScroll = ScrollController();
  final ScrollController _hScroll = ScrollController();

  // Geometry derived from the font size, preserving the original 14px ratios
  // (charWidth 8.4 = 0.6×, rowHeight 20 ≈ 1.4286×).
  double get _fontSize => widget.fontSize;
  double get _rowHeight => _fontSize * (20.0 / 14.0);
  double get _charWidth => _fontSize * (8.4 / 14.0);

  int _cursorRow = 0;
  int _cursorCol = 0;

  int? _selStartRow;
  int? _selStartCol;
  bool _isBlockSelection = false;
  final List<SelectionRange> _multiSelections = [];
  DateTime? _lastTapTime;
  int _tapCount = 0;
  int? _lastNotifiedRow;
  int? _lastNotifiedCol;
  int? _lastNotifiedSelStartRow;
  int? _lastNotifiedSelStartCol;

  EditSession get _session => widget.session;
  int get _visualLineCount => _session.lineCount().toInt();

  /// First and last row currently on screen, for viewport-scoped search
  /// highlighting. Clamped to the document.
  (int, int) get visibleRowRange {
    if (!_vScroll.hasClients) return (0, 0);
    // Screen slots are display rows; callers want document rows. With a fold
    // collapsed the two differ, and the range still has to cover the collapsed
    // body — a match hidden inside it is a match the find panel must count.
    final firstSlot = (_vScroll.offset / _rowHeight).floor();
    final visible = (_vScroll.position.viewportDimension / _rowHeight).ceil();
    final lastSlot = (firstSlot + visible).clamp(0, _displayRowCount);
    final first = _displayToDoc(firstSlot.clamp(0, _displayRowCount));
    final last = lastSlot >= _displayRowCount
        ? _visualLineCount
        : _displayToDoc(lastSlot);
    return (first.clamp(0, _visualLineCount), last.clamp(0, _visualLineCount));
  }

  /// Select [span] and scroll it into view. Used by the find panel when the
  /// current match changes.
  void revealSpan(MatchSpan span) {
    // A match or diagnostic inside a collapsed region has to be shown, not just
    // scrolled to.
    _revealRow(span.startRow.toInt());
    _revealRow(span.endRow.toInt());
    setState(() {
      _selStartRow = span.startRow.toInt();
      _selStartCol = span.startCol.toInt();
      _isBlockSelection = false;
      _cursorRow = span.endRow.toInt();
      _cursorCol = span.endCol.toInt();
    });
    _scrollToCursor();
  }

  /// Jump to 1-indexed [lineNumber] in the editor.
  void gotoLine(int lineNumber) {
    if (_visualLineCount == 0) return;
    final targetRow = (lineNumber - 1)
        .clamp(0, math.max(0, _visualLineCount - 1))
        .toInt();
    _revealRow(targetRow);
    setState(() {
      _cursorRow = targetRow;
      _cursorCol = 0;
      _clearSelection();
    });
    _scrollToCursor();
    _focusNode.requestFocus();
  }

  /// Return keyboard focus to the document. Used when the find panel closes.
  void focusEditor() => _focusNode.requestFocus();

  /// Reconcile view-only state after the Rust session has re-indexed an
  /// externally changed file. Content and line-count ownership stay in Rust.
  void handleExternalReload() {
    final lastRow = math.max(0, _visualLineCount - 1);
    setState(() {
      _cursorRow = _cursorRow.clamp(0, lastRow).toInt();
      _cursorCol = _cursorCol
          .clamp(0, _session.line(vrow: BigInt.from(_cursorRow)).length)
          .toInt();
      _clearSelection();
      _multiSelections.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vScroll.hasClients) return;
      final max = _vScroll.position.maxScrollExtent;
      if (_vScroll.offset > max) _vScroll.jumpTo(max);
      widget.onViewportChanged?.call();
    });
  }

  /// The caret's current (row, column). Used to anchor a find refresh after an
  /// edit, so the current match stays where the user is working instead of
  /// jumping back to the top of the document.
  (int, int) get caretPosition => (_cursorRow, _cursorCol);

  /// The current linear selection as a search scope, or null when there is
  /// none. Backs the panel's "In selection" option.
  SpanScope? get selectionScope {
    if (!hasLinearSelection) return null;
    final (sr, sc, er, ec) = normalizeSelection(
      _selStartRow!,
      _selStartCol!,
      _cursorRow,
      _cursorCol,
    );
    return SpanScope(
      startRow: BigInt.from(sr),
      startCol: BigInt.from(sc),
      endRow: BigInt.from(er),
      endCol: BigInt.from(ec),
    );
  }

  /// Width of the line-number gutter in logical pixels (0 when hidden). Sized
  /// to the digit count of the last line plus one char of padding each side.
  double get _gutterWidth {
    // The fold column is independent of the line numbers: a document with
    // foldable structure gets its boxes whether or not numbers are shown.
    if (!widget.showLineNumbers) return _foldColumnWidth;
    final digits = math.max(2, _visualLineCount.toString().length);
    return (digits + 2) * _charWidth + _foldColumnWidth;
  }

  /// Width reserved for the fold boxes, zero when there is nothing to fold.
  double get _foldColumnWidth => _folds.isEmpty ? 0 : _rowHeight * 0.8;

  /// Exposed so a test can assert the fold column survives line numbers being
  /// switched off.
  double get foldColumnWidth => _foldColumnWidth;

  // ---- Session-backed text access & mutation ------------------------------

  /// Replace the entire document with [text] as one undoable step. Used by the
  /// MIME tools to write a transform result back into the editor.
  void replaceAll(
    String text, {
    bool requestFocus = true,
    bool ignoreReadOnly = false,
  }) {
    if (widget.readOnly && !ignoreReadOnly) return;
    setState(() {
      final c = _session.replaceAll(text: text);
      _cursorRow = c.row.toInt();
      _cursorCol = c.col.toInt();
      _selStartRow = null;
      _selStartCol = null;
    });
    widget.onContentChanged?.call();
    _scheduleFoldRefresh();
    if (requestFocus) _focusNode.requestFocus();
  }

  /// True when there is a (linear, non-column) selection MIME tools can scope to.
  bool get hasLinearSelection => hasSelection && !_isBlockSelection;

  /// Apply [transform] to the current linear selection (replacing just that
  /// span, undoably) if there is one, otherwise to the whole document.
  ///
  /// [transform] is invoked *before* any mutation, so if it throws (e.g. a
  /// decode over invalid input) the document is left untouched and the
  /// exception propagates to the caller.
  /// Returns true if it made changes.
  bool transformSelectionOrAll(String Function(String input) transform) {
    if (widget.readOnly) return false;
    if (_multiSelections.isNotEmpty) {
      final outputs = <String>[];
      for (final range in _multiSelections) {
        outputs.add(
          transform(
            _getRangeText(
              range.startRow,
              range.startCol,
              range.endRow,
              range.endCol,
            ),
          ),
        );
      }
      final sortedIndices = List<int>.generate(
        _multiSelections.length,
        (i) => i,
      );
      sortedIndices.sort((a, b) {
        final rA = _multiSelections[a];
        final rB = _multiSelections[b];
        if (rB.startRow != rA.startRow) {
          return rB.startRow.compareTo(rA.startRow);
        }
        return rB.startCol.compareTo(rA.startCol);
      });
      setState(() {
        _session.beginGroup();
        for (final idx in sortedIndices) {
          final range = _multiSelections[idx];
          final output = outputs[idx];
          int r1 = range.startRow;
          int c1 = range.startCol;
          int r2 = range.endRow;
          int c2 = range.endCol;
          if (r1 > r2 || (r1 == r2 && c1 > c2)) {
            final tr = r1;
            r1 = r2;
            r2 = tr;
            final tc = c1;
            c1 = c2;
            c2 = tc;
          }
          _applyDelete(r1, c1, r2, c2);
          _applyInsert(r1, c1, output);
        }
        _session.endGroup();
        _clearSelection();
      });
      widget.onContentChanged?.call();
      _scheduleFoldRefresh();
      _scheduleFoldRefresh();
      _scrollToCursor();
      _focusNode.requestFocus();
      return true;
    }
    if (hasLinearSelection) {
      final output = transform(_selectedLinearText());
      setState(() {
        int r1 = _selStartRow!, c1 = _selStartCol!;
        int r2 = _cursorRow, c2 = _cursorCol;
        if (r1 > r2 || (r1 == r2 && c1 > c2)) {
          final tr = r1;
          r1 = r2;
          r2 = tr;
          final tc = c1;
          c1 = c2;
          c2 = tc;
        }
        _session.beginGroup();
        _applyDelete(r1, c1, r2, c2);
        _applyInsert(r1, c1, output);
        _session.endGroup();
        _clearSelection();
      });
      widget.onContentChanged?.call();
      _scheduleFoldRefresh();
      _scheduleFoldRefresh();
      _scrollToCursor();
      _focusNode.requestFocus();
      return true;
    } else {
      replaceAll(transform(_session.contentString()));
      return true;
    }
  }

  String _getRangeText(int r1, int c1, int r2, int c2) {
    if (r1 > r2 || (r1 == r2 && c1 > c2)) {
      int temp = r1;
      r1 = r2;
      r2 = temp;
      temp = c1;
      c1 = c2;
      c2 = temp;
    }
    StringBuffer sb = StringBuffer();
    for (int i = r1; i <= r2; i++) {
      String line = _getLineText(i);
      if (i == r1 && i == r2) {
        int start = math.min(c1, line.length);
        int end = math.min(c2, line.length);
        sb.write(line.substring(start, end));
      } else if (i == r1) {
        int start = math.min(c1, line.length);
        sb.writeln(line.substring(start));
      } else if (i == r2) {
        int end = math.min(c2, line.length);
        sb.write(line.substring(0, end));
      } else {
        sb.writeln(line);
      }
    }
    return sb.toString();
  }

  /// The current linear selection as text (newline-joined across rows).
  String _selectedLinearText() {
    int r1 = _selStartRow!, c1 = _selStartCol!;
    int r2 = _cursorRow, c2 = _cursorCol;
    if (r1 > r2 || (r1 == r2 && c1 > c2)) {
      final tr = r1;
      r1 = r2;
      r2 = tr;
      final tc = c1;
      c1 = c2;
      c2 = tc;
    }
    final sb = StringBuffer();
    for (int i = r1; i <= r2; i++) {
      final line = _getLineText(i);
      if (i == r1 && i == r2) {
        sb.write(
          line.substring(math.min(c1, line.length), math.min(c2, line.length)),
        );
      } else if (i == r1) {
        sb.write(line.substring(math.min(c1, line.length)));
        sb.write('\n');
      } else if (i == r2) {
        sb.write(line.substring(0, math.min(c2, line.length)));
      } else {
        sb.write(line);
        sb.write('\n');
      }
    }
    return sb.toString();
  }

  /// Insert [text] at ([row], [col]); moves the cursor to the returned caret.
  void _applyInsert(int row, int col, String text) {
    if (widget.readOnly) return;
    final c = _session.insert(
      row: BigInt.from(row),
      col: BigInt.from(col),
      text: text,
    );
    _cursorRow = c.row.toInt();
    _cursorCol = c.col.toInt();
    widget.onContentChanged?.call();
    _scheduleFoldRefresh();
  }

  /// Delete the range [srow,scol]..[erow,ecol]; moves the cursor to the result.
  void _applyDelete(int srow, int scol, int erow, int ecol) {
    if (widget.readOnly) return;
    final c = _session.delete(
      srow: BigInt.from(srow),
      scol: BigInt.from(scol),
      erow: BigInt.from(erow),
      ecol: BigInt.from(ecol),
    );
    _cursorRow = c.row.toInt();
    _cursorCol = c.col.toInt();
    widget.onContentChanged?.call();
    _scheduleFoldRefresh();
  }

  int _nextWordBoundary(String line, int col) {
    if (col >= line.length) return line.length;
    bool isAlphaNumeric(int c) =>
        (c >= 48 && c <= 57) ||
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        c == 95;
    int startChar = line.codeUnitAt(col);
    bool startIsAlpha = isAlphaNumeric(startChar);
    bool startIsSpace = startChar == 32;
    for (int i = col + 1; i < line.length; i++) {
      int c = line.codeUnitAt(i);
      bool isAlpha = isAlphaNumeric(c);
      bool isSpace = c == 32;
      if (startIsSpace) {
        if (!isSpace) return i;
      } else if (startIsAlpha) {
        if (!isAlpha) return i;
      } else {
        if (isAlpha || isSpace) return i;
      }
    }
    return line.length;
  }

  int _prevWordBoundary(String line, int col) {
    if (col <= 0) return 0;
    if (col > line.length) return line.length;
    bool isAlphaNumeric(int c) =>
        (c >= 48 && c <= 57) ||
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        c == 95;
    int startChar = line.codeUnitAt(col - 1);
    bool startIsAlpha = isAlphaNumeric(startChar);
    bool startIsSpace = startChar == 32;
    for (int i = col - 2; i >= 0; i--) {
      int c = line.codeUnitAt(i);
      bool isAlpha = isAlphaNumeric(c);
      bool isSpace = c == 32;
      if (startIsSpace) {
        if (!isSpace) return i + 1;
      } else if (startIsAlpha) {
        if (!isAlpha) return i + 1;
      } else {
        if (isAlpha || isSpace) return i + 1;
      }
    }
    return 0;
  }

  int _nextCamelBoundary(String line, int col) {
    if (col >= line.length) return line.length;
    bool isUpper(int c) => c >= 65 && c <= 90;
    bool isLower(int c) => c >= 97 && c <= 122;
    bool isAlphaNumeric(int c) =>
        (c >= 48 && c <= 57) || isUpper(c) || isLower(c) || c == 95;
    for (int i = col + 1; i < line.length; i++) {
      int prev = line.codeUnitAt(i - 1);
      int curr = line.codeUnitAt(i);
      if (!isAlphaNumeric(prev) && isAlphaNumeric(curr)) return i;
      if (isAlphaNumeric(prev) && !isAlphaNumeric(curr)) return i;
      if (isLower(prev) && isUpper(curr)) return i;
      if (isUpper(prev) &&
          isUpper(curr) &&
          i + 1 < line.length &&
          isLower(line.codeUnitAt(i + 1)))
        return i;
      if (prev == 95 && curr != 95) return i;
    }
    return line.length;
  }

  int _prevCamelBoundary(String line, int col) {
    if (col <= 0) return 0;
    if (col > line.length) return line.length;
    bool isUpper(int c) => c >= 65 && c <= 90;
    bool isLower(int c) => c >= 97 && c <= 122;
    bool isAlphaNumeric(int c) =>
        (c >= 48 && c <= 57) || isUpper(c) || isLower(c) || c == 95;
    for (int i = col - 1; i > 0; i--) {
      int prev = line.codeUnitAt(i - 1);
      int curr = line.codeUnitAt(i);
      if (!isAlphaNumeric(prev) && isAlphaNumeric(curr)) return i;
      if (isAlphaNumeric(prev) && !isAlphaNumeric(curr)) return i;
      if (isLower(prev) && isUpper(curr)) return i;
      if (isUpper(prev) &&
          isUpper(curr) &&
          i + 1 < line.length &&
          isLower(line.codeUnitAt(i + 1)))
        return i;
      if (prev == 95 && curr != 95) return i;
    }
    return 0;
  }

  final FocusNode _focusNode = FocusNode();

  // Blinking caret.
  Timer? _blinkTimer;
  bool _caretVisible = true;

  // While Ctrl is held, the wheel zooms instead of scrolling.
  bool _ctrlHeld = false;

  @override
  void initState() {
    super.initState();
    _vScroll.addListener(() {
      setState(() {});
      widget.onViewportChanged?.call();
    });
    _hScroll.addListener(() => setState(() {}));
    _focusNode.addListener(_onFocusChange);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_focusNode.hasFocus) return;
      setState(() => _caretVisible = !_caretVisible);
    });
    // Restored collapses land before the first fold scan; that scan drops any
    // row that no longer starts a fold, so a document edited elsewhere since
    // the last run cannot leave text hidden with no box to reopen it.
    _collapsedFolds.addAll(widget.initialCollapsedFolds);
    // After the first frame, so the session is readable and setState is legal.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshFolds());
  }

  @override
  void didUpdateWidget(covariant CustomEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different document, or the same one re-detected as another format,
    // means the fold regions no longer describe what is on screen.
    if (oldWidget.session != widget.session ||
        oldWidget.markupLanguage != widget.markupLanguage) {
      _collapsedFolds
        ..clear()
        ..addAll(widget.initialCollapsedFolds);
      _foldsScannedForRows = null;
      _refreshFolds();
    }
  }

  bool _onHardwareKey(KeyEvent event) {
    final bool held = HardwareKeyboard.instance.isControlPressed;
    if (held != _ctrlHeld && mounted) setState(() => _ctrlHeld = held);
    return false; // never consume — just observe
  }

  void _handleFontZoom(PointerScrollEvent event) {
    if (widget.onFontSizeChanged == null) return;
    final double next =
        (widget.fontSize + (event.scrollDelta.dy < 0 ? 1.0 : -1.0)).clamp(
          8.0,
          40.0,
        );
    if (next != widget.fontSize) widget.onFontSizeChanged!(next);
  }

  void _onFocusChange() {
    // Show the caret solid on focus; repaint on blur.
    setState(() => _caretVisible = true);
  }

  /// Reset the caret to solid-visible so it doesn't blink out mid-action.
  void _wakeCaret() {
    _caretVisible = true;
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _foldRefreshDebounce?.cancel();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _focusNode.removeListener(_onFocusChange);
    _vScroll.dispose();
    _hScroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> saveFile() async {
    _session.save();
    if (mounted) setState(() {});
  }

  // ---- Public API for the ribbon's Edit menu -----------------------------
  // Same operations as the Ctrl+Z/Y/X/C/V shortcuts, callable from the menu.
  bool get canUndo => _session.canUndo();
  bool get canRedo => _session.canRedo();
  bool get hasSelection => _selStartRow != null && _selStartCol != null;

  void menuUndo() {
    setState(_undo);
    _focusNode.requestFocus();
  }

  void menuRedo() {
    setState(_redo);
    _focusNode.requestFocus();
  }

  void menuCopy() {
    _copySelection();
    _focusNode.requestFocus();
  }

  void menuCut() {
    if (!hasSelection) return;
    setState(() {
      _copySelection();
      _deleteSelection();
    });
    _focusNode.requestFocus();
  }

  Future<void> menuPaste() async {
    await _pasteText();
    if (mounted) _focusNode.requestFocus();
  }

  // Called from within _handleKey's setState.
  void _undo() {
    if (widget.readOnly) return;
    final c = _session.undo();
    if (c == null) return;
    _clearSelection();
    _cursorRow = c.row.toInt().clamp(0, math.max(0, _visualLineCount - 1));
    _cursorCol = c.col.toInt();
    widget.onContentChanged?.call();
    _scheduleFoldRefresh();
    _scrollToCursor();
  }

  void _redo() {
    if (widget.readOnly) return;
    final c = _session.redo();
    if (c == null) return;
    _clearSelection();
    _cursorRow = c.row.toInt().clamp(0, math.max(0, _visualLineCount - 1));
    _cursorCol = c.col.toInt();
    widget.onContentChanged?.call();
    _scheduleFoldRefresh();
    _scrollToCursor();
  }

  void _clearSelection() {
    _selStartRow = null;
    _selStartCol = null;
    _multiSelections.clear();
  }

  /// Break undo coalescing so the next typed run is a fresh undo step. Called
  /// on caret moves, clicks, and focus changes.
  void _breakCoalescing() => _session.breakCoalescing();

  /// Delete the current selection via the session. For block (column)
  /// selections, each row's span is deleted as its own operation, grouped so
  /// one undo reverts the whole block.
  ///
  /// When [keepBlankLines] is true (Ctrl+Delete on a multi-row selection), the
  /// selected text is removed but the emptied lines are left in place instead
  /// of the gap being closed — the line count is preserved.
  void _deleteSelection({bool keepBlankLines = false}) {
    if (widget.readOnly) return;
    if (_multiSelections.isNotEmpty) {
      final sorted = List<SelectionRange>.from(_multiSelections);
      sorted.sort((a, b) {
        if (b.startRow != a.startRow) {
          return b.startRow.compareTo(a.startRow);
        }
        return b.startCol.compareTo(a.startCol);
      });
      _session.beginGroup();
      for (final range in sorted) {
        int r1 = range.startRow;
        int c1 = range.startCol;
        int r2 = range.endRow;
        int c2 = range.endCol;
        if (r1 > r2 || (r1 == r2 && c1 > c2)) {
          int temp = r1;
          r1 = r2;
          r2 = temp;
          temp = c1;
          c1 = c2;
          c2 = temp;
        }
        _applyDelete(r1, c1, r2, c2);
      }
      _session.endGroup();
      _multiSelections.clear();
      _selStartRow = null;
      _selStartCol = null;
      if (sorted.isNotEmpty) {
        final first = sorted.last;
        _cursorRow = first.startRow;
        _cursorCol = first.startCol;
      }
      widget.onContentChanged?.call();
      _scheduleFoldRefresh();
      _scheduleFoldRefresh();
      return;
    }

    if (_selStartRow == null || _selStartCol == null) return;

    if (_isBlockSelection) {
      int minR = math.min(_selStartRow!, _cursorRow);
      int maxR = math.max(_selStartRow!, _cursorRow);
      int minC = math.min(_selStartCol!, _cursorCol);
      int maxC = math.max(_selStartCol!, _cursorCol);

      _session.beginGroup();
      for (int i = minR; i <= maxR; i++) {
        final len = _getLineLength(i);
        final start = math.min(minC, len);
        final end = math.min(maxC, len);
        if (end > start) _applyDelete(i, start, i, end);
      }
      _session.endGroup();
      _cursorRow = minR;
      _cursorCol = minC;
    } else {
      // Normalize so (r1,c1) precedes (r2,c2).
      int r1 = _selStartRow!, c1 = _selStartCol!;
      int r2 = _cursorRow, c2 = _cursorCol;
      if (r1 > r2 || (r1 == r2 && c1 > c2)) {
        final tr = r1;
        r1 = r2;
        r2 = tr;
        final tc = c1;
        c1 = c2;
        c2 = tc;
      }

      if (keepBlankLines && r1 != r2) {
        // Capture the trailing part of the last line before mutating, then
        // clear each row's selected span (no join) and pull that tail up onto
        // the first line — leaving the in-between rows blank.
        final len2 = _getLineLength(r2);
        final tail2 = _getLineText(r2).substring(math.min(c2, len2));
        _session.beginGroup();
        _applyDelete(r1, c1, r1, _getLineLength(r1));
        for (int i = r1 + 1; i <= r2; i++) {
          _applyDelete(i, 0, i, _getLineLength(i));
        }
        if (tail2.isNotEmpty) _applyInsert(r1, c1, tail2);
        _session.endGroup();
        _cursorRow = r1;
        _cursorCol = c1;
      } else {
        _applyDelete(r1, c1, r2, c2);
      }
    }

    _clearSelection();
    _scrollToCursor();
  }

  /// Swap the full contents of two lines as a single undo step.
  void _swapLines(int a, int b) {
    if (widget.readOnly) return;
    final contentA = _getLineText(a);
    final contentB = _getLineText(b);
    final lenA = contentA.length;
    final lenB = contentB.length;
    _session.beginGroup();
    if (lenA > 0) _applyDelete(a, 0, a, lenA);
    if (contentB.isNotEmpty) _applyInsert(a, 0, contentB);
    if (lenB > 0) _applyDelete(b, 0, b, lenB);
    if (contentA.isNotEmpty) _applyInsert(b, 0, contentA);
    _session.endGroup();
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;

    bool ctrl = HardwareKeyboard.instance.isControlPressed;
    bool altOnly = HardwareKeyboard.instance.isAltPressed && !ctrl;
    if (ctrl && _bubbleShortcutKeys.contains(event.logicalKey)) {
      return;
    }
    // Ctrl+Alt+F is fold-at-caret, not the Ctrl+F above; Alt+<digit> is
    // fold-to-level. Both belong to `_handleGlobalShortcut`.
    if (altOnly && _bubbleAltDigits.contains(event.logicalKey)) {
      return;
    }

    setState(() {
      _wakeCaret();
      bool ctrl = HardwareKeyboard.instance.isControlPressed;
      bool shift = HardwareKeyboard.instance.isShiftPressed;
      bool alt = HardwareKeyboard.instance.isAltPressed;
      bool meta = HardwareKeyboard.instance.isMetaPressed;

      bool isModifier =
          event.logicalKey == LogicalKeyboardKey.controlLeft ||
          event.logicalKey == LogicalKeyboardKey.controlRight ||
          event.logicalKey == LogicalKeyboardKey.shiftLeft ||
          event.logicalKey == LogicalKeyboardKey.shiftRight ||
          event.logicalKey == LogicalKeyboardKey.altLeft ||
          event.logicalKey == LogicalKeyboardKey.altRight ||
          event.logicalKey == LogicalKeyboardKey.metaLeft ||
          event.logicalKey == LogicalKeyboardKey.metaRight;

      if (isModifier) return;

      bool isMovementKey =
          (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight ||
          event.logicalKey == LogicalKeyboardKey.pageUp ||
          event.logicalKey == LogicalKeyboardKey.pageDown ||
          event.logicalKey == LogicalKeyboardKey.home ||
          event.logicalKey == LogicalKeyboardKey.end);

      if (isMovementKey) {
        // Any caret move ends the current typing run for undo purposes.
        _breakCoalescing();
        bool isLineMove =
            ctrl &&
            shift &&
            !alt &&
            (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                event.logicalKey == LogicalKeyboardKey.arrowDown);
        bool isScroll =
            ctrl &&
            !shift &&
            !alt &&
            (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                event.logicalKey == LogicalKeyboardKey.arrowDown);

        if (isScroll) {
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _vScroll.jumpTo(math.max(0, _vScroll.offset - _rowHeight));
          } else {
            _vScroll.jumpTo(
              math.min(
                _vScroll.position.maxScrollExtent,
                _vScroll.offset + _rowHeight,
              ),
            );
          }
          return;
        }

        if (isLineMove) {
          if (widget.readOnly) return;
          _clearSelection();
          final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
          final col = _cursorCol; // preserve the caret column across the move
          if (up && _cursorRow > 0) {
            _swapLines(_cursorRow, _cursorRow - 1);
            _cursorRow--;
            _cursorCol = col;
            _scrollToCursor();
          } else if (!up && _cursorRow < _visualLineCount - 1) {
            _swapLines(_cursorRow, _cursorRow + 1);
            _cursorRow++;
            _cursorCol = col;
            _scrollToCursor();
          }
          return;
        }

        if (!shift) {
          _selStartRow = null;
          _selStartCol = null;
        } else {
          _selStartRow ??= _cursorRow;
          _selStartCol ??= _cursorCol;
        }

        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _cursorRow = _rowAbove(_cursorRow);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _cursorRow = _rowBelow(_cursorRow);
        } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
          _cursorRow = _displayToDoc(
            (_docToDisplay(_cursorRow) -
                    (_vScroll.position.viewportDimension ~/ _rowHeight))
                .clamp(0, math.max(0, _displayRowCount - 1)),
          );
        } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
          _cursorRow = _displayToDoc(
            (_docToDisplay(_cursorRow) +
                    (_vScroll.position.viewportDimension ~/ _rowHeight))
                .clamp(0, math.max(0, _displayRowCount - 1)),
          );
        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          if (ctrl || alt) {
            String line = _getLineText(_cursorRow);
            if (_cursorCol == 0 && _cursorRow > 0) {
              _cursorRow--;
              _cursorCol = _getLineText(_cursorRow).length;
            } else {
              _cursorCol = alt
                  ? _prevCamelBoundary(line, _cursorCol)
                  : _prevWordBoundary(line, _cursorCol);
            }
          } else {
            _cursorCol = (_cursorCol - 1).clamp(0, _getLineLength(_cursorRow));
          }
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (ctrl || alt) {
            String line = _getLineText(_cursorRow);
            if (_cursorCol >= line.length &&
                _cursorRow < _visualLineCount - 1) {
              _cursorRow++;
              _cursorCol = 0;
            } else {
              _cursorCol = alt
                  ? _nextCamelBoundary(line, _cursorCol)
                  : _nextWordBoundary(line, _cursorCol);
            }
          } else {
            _cursorCol = (_cursorCol + 1).clamp(0, _getLineLength(_cursorRow));
          }
        } else if (event.logicalKey == LogicalKeyboardKey.home) {
          if (ctrl) _cursorRow = 0; // Ctrl+Home → document top
          _cursorCol = 0;
        } else if (event.logicalKey == LogicalKeyboardKey.end) {
          if (ctrl) _cursorRow = _lastVisibleRow; // Ctrl+End → document bottom
          _cursorCol = _getLineLength(_cursorRow);
        }
        _scrollToCursor();
        return;
      }
      if (ctrl && !alt) {
        final label = event.logicalKey.keyLabel.toUpperCase();
        if (label == 'C') {
          _copySelection();
          return;
        } else if (label == 'A') {
          _selStartRow = 0;
          _selStartCol = 0;
          _cursorRow = _lastVisibleRow;
          _cursorCol = _getLineLength(_cursorRow);

          _session.copyToClipboard();
          return;
        }

        if (widget.readOnly) return;

        if (label == 'Z') {
          if (shift) {
            _redo();
          } else {
            _undo();
          }
          _notifyCursor();
          return;
        } else if (label == 'Y') {
          _redo();
          _notifyCursor();
          return;
        } else if (label == 'X') {
          if (_selStartRow != null && _selStartCol != null) {
            _copySelection();
            _deleteSelection();
          }
          return;
        } else if (label == 'V') {
          _pasteText();
          return;
        } else if (label == 'D') {
          // Duplicate the current line below it.
          final line = _getLineText(_cursorRow);
          _applyInsert(_cursorRow, _getLineLength(_cursorRow), '\n$line');
          _scrollToCursor();
          return;
        }
      }

      if (widget.readOnly) return;

      if (event.logicalKey == LogicalKeyboardKey.backspace ||
          event.logicalKey == LogicalKeyboardKey.delete) {
        if (_selStartRow != null && _selStartCol != null) {
          // Ctrl+Delete keeps the emptied lines instead of closing the gap.
          _deleteSelection(
            keepBlankLines:
                ctrl && event.logicalKey == LogicalKeyboardKey.delete,
          );
        } else if (event.logicalKey == LogicalKeyboardKey.backspace) {
          if (_cursorCol > 0) {
            _applyDelete(_cursorRow, _cursorCol - 1, _cursorRow, _cursorCol);
          } else if (_cursorRow > 0) {
            // Join with the previous line.
            final prevLen = _getLineLength(_cursorRow - 1);
            _applyDelete(_cursorRow - 1, prevLen, _cursorRow, 0);
          }
          _scrollToCursor();
        } else {
          // Forward delete.
          final len = _getLineLength(_cursorRow);
          if (_cursorCol < len) {
            _applyDelete(_cursorRow, _cursorCol, _cursorRow, _cursorCol + 1);
          } else if (_cursorRow < _visualLineCount - 1) {
            // Join with the next line.
            _applyDelete(_cursorRow, len, _cursorRow + 1, 0);
          }
          _scrollToCursor();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (_selStartRow != null && _selStartCol != null) {
          _session.beginGroup();
          _deleteSelection();
          _applyInsert(_cursorRow, _cursorCol, '\n');
          _session.endGroup();
        } else {
          _applyInsert(_cursorRow, _cursorCol, '\n');
        }
        _scrollToCursor();
      } else if (event.logicalKey == LogicalKeyboardKey.tab) {
        final int tab = EditorSettings.tabSize;
        final bool multiRowSel =
            _selStartRow != null &&
            _selStartCol != null &&
            _selStartRow != _cursorRow;
        if (!shift) {
          if (multiRowSel) {
            // Indent each selected row; group so one undo reverts the block.
            int minR = math.min(_selStartRow!, _cursorRow);
            int maxR = math.max(_selStartRow!, _cursorRow);
            _session.beginGroup();
            for (int i = minR; i <= maxR; i++) {
              _applyInsert(i, 0, ' ' * tab);
            }
            _session.endGroup();
            _selStartCol = _selStartCol! + tab;
            _cursorCol += tab;
            _scrollToCursor();
          } else {
            // Insert spaces to the next tab stop.
            int spaces = tab - (_cursorCol % tab);
            _applyInsert(_cursorRow, _cursorCol, ' ' * spaces);
            _scrollToCursor();
          }
        } else {
          // Dedent: remove up to `tab` leading spaces per row.
          int minR = _cursorRow;
          int maxR = _cursorRow;
          if (_selStartRow != null && _selStartCol != null) {
            minR = math.min(_selStartRow!, _cursorRow);
            maxR = math.max(_selStartRow!, _cursorRow);
          }
          _session.beginGroup();
          for (int i = minR; i <= maxR; i++) {
            String line = _getLineText(i);
            int removed = 0;
            while (removed < tab &&
                removed < line.length &&
                line[removed] == ' ') {
              removed++;
            }
            if (removed > 0) {
              _applyDelete(i, 0, i, removed);
              if (i == _cursorRow)
                _cursorCol = math.max(0, _cursorCol - removed);
              if (i == _selStartRow)
                _selStartCol = math.max(0, _selStartCol! - removed);
            }
          }
          _session.endGroup();
          _scrollToCursor();
        }
        return;
      } else {
        if (!ctrl && !alt && !meta) {
          if (event.character != null && event.character!.isNotEmpty) {
            String char = event.character!;
            if (char.codeUnitAt(0) >= 32 && char.codeUnitAt(0) != 127) {
              if (_selStartRow != null && _selStartCol != null) {
                // Replace selection with the typed char, atomically.
                _session.beginGroup();
                _deleteSelection();
                _applyInsert(_cursorRow, _cursorCol, char);
                _session.endGroup();
              } else {
                _applyInsert(_cursorRow, _cursorCol, char);
              }
              _scrollToCursor();
            }
          }
        }
      }
      _notifyCursor();
    });
  }

  void _copySelection() {
    if (_selStartRow == null || _selStartCol == null) return;

    int r1 = _selStartRow!;
    int c1 = _selStartCol!;
    int r2 = _cursorRow;
    int c2 = _cursorCol;

    if (r1 > r2 || (r1 == r2 && c1 > c2)) {
      int temp = r1;
      r1 = r2;
      r2 = temp;
      temp = c1;
      c1 = c2;
      c2 = temp;
    }

    // Fast path: if copying the entire document, do it natively in Rust
    if (r1 == 0 &&
        c1 == 0 &&
        r2 == _visualLineCount - 1 &&
        c2 == _getLineLength(r2)) {
      _session.copyToClipboard();
      return;
    }

    if (_multiSelections.isNotEmpty) {
      final text = _multiSelections
          .map(
            (range) => _getRangeText(
              range.startRow,
              range.startCol,
              range.endRow,
              range.endCol,
            ),
          )
          .join('\n');
      Clipboard.setData(ClipboardData(text: text));
      return;
    }

    // For normal range copying, fetch the whole content once if it spans multiple lines to prevent N FFI roundtrips
    StringBuffer sb = StringBuffer();
    if (_isBlockSelection) {
      if (r2 - r1 > 50) {
        final allLines = _session.contentString().split('\n');
        for (int i = r1; i <= r2; i++) {
          final line = allLines[i];
          final start = math.min(c1, line.length);
          final end = math.min(c2, line.length);
          sb.writeln(line.substring(start, end));
        }
      } else {
        for (int i = r1; i <= r2; i++) {
          final line = _getLineText(i);
          final start = math.min(c1, line.length);
          final end = math.min(c2, line.length);
          sb.writeln(line.substring(start, end));
        }
      }
    } else {
      if (r2 - r1 > 50) {
        final allLines = _session.contentString().split('\n');
        for (int i = r1; i <= r2; i++) {
          final line = allLines[i];
          if (i == r1 && i == r2) {
            final start = math.min(c1, line.length);
            final end = math.min(c2, line.length);
            sb.write(line.substring(start, end));
          } else if (i == r1) {
            final start = math.min(c1, line.length);
            sb.writeln(line.substring(start));
          } else if (i == r2) {
            final end = math.min(c2, line.length);
            sb.write(line.substring(0, end));
          } else {
            sb.writeln(line);
          }
        }
      } else {
        for (int i = r1; i <= r2; i++) {
          final line = _getLineText(i);
          if (i == r1 && i == r2) {
            final start = math.min(c1, line.length);
            final end = math.min(c2, line.length);
            sb.write(line.substring(start, end));
          } else if (i == r1) {
            final start = math.min(c1, line.length);
            sb.writeln(line.substring(start));
          } else if (i == r2) {
            final end = math.min(c2, line.length);
            sb.write(line.substring(0, end));
          } else {
            sb.writeln(line);
          }
        }
      }
    }
    Clipboard.setData(ClipboardData(text: sb.toString()));
  }

  void _selectWordAtCursor({required bool caseSensitive}) {
    final line = _getLineText(_cursorRow);
    if (line.isEmpty) return;

    int col = _cursorCol.clamp(0, line.length);
    if (col == line.length && col > 0) {
      col--;
    }

    final wordChar = RegExp(r'[a-zA-Z0-9_]');
    if (col >= line.length || !wordChar.hasMatch(line[col])) {
      return;
    }

    int startCol = col;
    while (startCol > 0 && wordChar.hasMatch(line[startCol - 1])) {
      startCol--;
    }

    int endCol = col;
    while (endCol < line.length && wordChar.hasMatch(line[endCol])) {
      endCol++;
    }

    final wholeWord = line.substring(startCol, endCol);
    if (wholeWord.isEmpty) return;

    int selStart;
    int selEnd;

    if (caseSensitive) {
      final subWords = splitSubWords(wholeWord);
      int relativeCol = col - startCol;
      if (relativeCol >= wholeWord.length) {
        relativeCol = wholeWord.length - 1;
      }
      relativeCol = math.max(0, relativeCol);
      final match = subWords.firstWhere(
        (sw) => relativeCol >= sw.$1 && relativeCol < sw.$2,
        orElse: () => (0, wholeWord.length),
      );
      selStart = startCol + match.$1;
      selEnd = startCol + match.$2;
    } else {
      selStart = startCol;
      selEnd = endCol;
    }

    setState(() {
      _multiSelections.clear();
      _selStartRow = _cursorRow;
      _selStartCol = selStart;
      _cursorCol = selEnd;
    });
  }

  List<(int, int)> splitSubWords(String word) {
    if (word.isEmpty) return [];
    final List<(int, int)> ranges = [];
    int start = 0;

    while (start < word.length) {
      if (word[start] == '_') {
        start++;
        continue;
      }

      int end = start + 1;
      if (end < word.length) {
        if (_isUpper(word[start])) {
          if (_isUpper(word[end])) {
            while (end < word.length && _isUpper(word[end])) {
              if (end + 1 < word.length &&
                  _isUpper(word[end]) &&
                  _isLower(word[end + 1])) {
                break;
              }
              end++;
            }
          } else {
            while (end < word.length && _isLower(word[end])) {
              end++;
            }
          }
        } else if (_isLower(word[start])) {
          while (end < word.length && _isLower(word[end])) {
            end++;
          }
        } else if (_isDigit(word[start])) {
          while (end < word.length && _isDigit(word[end])) {
            end++;
          }
        } else {
          while (end < word.length && word[end] == word[start]) {
            end++;
          }
        }
      }

      ranges.add((start, end));
      start = end;
    }
    return ranges;
  }

  bool isSubWordBoundary(String s, int idx) {
    if (idx <= 0 || idx >= s.length) return true;

    final cPrev = s[idx - 1];
    final cCurr = s[idx];

    final wordChar = RegExp(r'[a-zA-Z0-9_]');
    final prevIsWord = wordChar.hasMatch(cPrev);
    final currIsWord = wordChar.hasMatch(cCurr);

    if (prevIsWord != currIsWord) return true;
    if (!prevIsWord) return false;
    if (cPrev == '_' || cCurr == '_') return true;

    if (_isLower(cPrev) && _isUpper(cCurr)) return true;
    if (_isUpper(cPrev) && _isUpper(cCurr)) {
      if (idx + 1 < s.length && _isLower(s[idx + 1])) {
        return true;
      }
    }

    final prevIsDigit = _isDigit(cPrev);
    final currIsDigit = _isDigit(cCurr);
    if (prevIsDigit != currIsDigit) return true;

    return false;
  }

  bool _isUpper(String char) =>
      char.codeUnitAt(0) >= 65 && char.codeUnitAt(0) <= 90;
  bool _isLower(String char) =>
      char.codeUnitAt(0) >= 97 && char.codeUnitAt(0) <= 122;
  bool _isDigit(String char) =>
      char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;

  Future<void> _pasteText() async {
    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data == null || data.text == null || data.text!.isEmpty) return;
    if (!mounted) return;
    final String text = data.text!
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    setState(() {
      if (_selStartRow != null && _selStartCol != null) {
        _session.beginGroup();
        _deleteSelection();
        _applyInsert(_cursorRow, _cursorCol, text);
        _session.endGroup();
      } else {
        _applyInsert(_cursorRow, _cursorCol, text);
      }
      _breakCoalescing();
      _scrollToCursor();
      _notifyCursor();
    });
  }

  String _getLineText(int vRow) {
    if (vRow < 0 || vRow >= _visualLineCount) return "";
    return _session.line(vrow: BigInt.from(vRow));
  }

  int _getLineLength(int row) {
    return _getLineText(row).length;
  }

  /// Length (in characters) of the widest line the horizontal scroll region
  /// needs to accommodate: the cursor's line plus every currently-visible line.
  /// Bounded by the visible row range, so it stays cheap on huge files.
  int _maxRelevantLineLength() {
    int maxLen = _getLineLength(_cursorRow);
    // hasClients isn't enough: on the first build of a freshly-mounted editor
    // (e.g. a restored Edit tab) the position exists but its viewport hasn't
    // been laid out yet, so reading viewportDimension would deref a null.
    if (_vScroll.hasClients &&
        _vScroll.position.hasViewportDimension &&
        _visualLineCount > 0) {
      final double vp = _vScroll.position.viewportDimension;
      final double off = _vScroll.offset;
      final int firstSlot = (off / _rowHeight).floor().clamp(
        0,
        math.max(0, _displayRowCount - 1),
      );
      final int lastSlot = ((off + vp) / _rowHeight).ceil().clamp(
        0,
        _displayRowCount,
      );
      for (int slot = firstSlot; slot < lastSlot; slot++) {
        final int len = _getLineLength(_displayToDoc(slot));
        if (len > maxLen) maxLen = len;
      }
    }
    return maxLen;
  }

  void _scrollToCursor() {
    // Deferred to after the frame so the scroll extents reflect the width this
    // rebuild lays out (which grows to fit the cursor's line). Targets are
    // clamped to maxScrollExtent so a jump never overscrolls — an overscroll
    // would make ClampingScrollPhysics settle back with a visible bounce.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The caret's *screen* row, which is not its document row once a
      // region above it is collapsed.
      final double cursorY = _docToDisplay(_cursorRow) * _rowHeight;
      // Painted caret sits past the gutter, so follow it in the same space.
      final double cursorX = _gutterWidth + _cursorCol * _charWidth;

      if (_vScroll.hasClients) {
        final double maxV = _vScroll.position.maxScrollExtent;
        final double vp = _vScroll.position.viewportDimension;
        if (cursorY < _vScroll.offset) {
          _vScroll.jumpTo(cursorY.clamp(0.0, maxV));
        } else if (cursorY + _rowHeight > _vScroll.offset + vp) {
          _vScroll.jumpTo((cursorY + _rowHeight - vp).clamp(0.0, maxV));
        }
      }

      if (_hScroll.hasClients) {
        final double maxH = _hScroll.position.maxScrollExtent;
        final double vp = _hScroll.position.viewportDimension;
        if (cursorX < _hScroll.offset) {
          _hScroll.jumpTo(cursorX.clamp(0.0, maxH));
        } else if (cursorX + 20 > _hScroll.offset + vp) {
          _hScroll.jumpTo((cursorX + 20 - vp).clamp(0.0, maxH));
        }
      }
    });
  }

  void _notifyCursor() {
    // Before the callback guard: the matched-pair highlight has to follow the
    // caret whether or not a host is listening for cursor updates.
    _updateMarkupPair();
    if (widget.onCursorChanged == null) return;
    if (_cursorRow == _lastNotifiedRow &&
        _cursorCol == _lastNotifiedCol &&
        _selStartRow == _lastNotifiedSelStartRow &&
        _selStartCol == _lastNotifiedSelStartCol) {
      return;
    }

    _lastNotifiedRow = _cursorRow;
    _lastNotifiedCol = _cursorCol;
    _lastNotifiedSelStartRow = _selStartRow;
    _lastNotifiedSelStartCol = _selStartCol;

    int selChars = 0;
    int selLines = 0;

    if (_selStartRow != null && _selStartCol != null) {
      if (_isBlockSelection) {
        selLines = (_cursorRow - _selStartRow!).abs() + 1;
        selChars = (_cursorCol - _selStartCol!).abs();
      } else {
        selLines = (_cursorRow - _selStartRow!).abs() + 1;
        selChars = _session
            .selectionCharCount(
              r1: BigInt.from(_selStartRow!),
              c1: BigInt.from(_selStartCol!),
              r2: BigInt.from(_cursorRow),
              c2: BigInt.from(_cursorCol),
            )
            .toInt();
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.onCursorChanged != null) {
        widget.onCursorChanged!(
          _cursorRow + 1,
          _cursorCol + 1,
          selChars,
          selLines,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncFoldMap();
    // Catch-all for a document this editor has never scanned — a tab restored
    // at startup, or one whose format was detected after the editor mounted.
    // Guarded by the row count so it runs once per document size, not per frame.
    if (_foldsScannedForRows != _visualLineCount) {
      _scheduleFoldRefresh();
    }
    _notifyCursor();
    double totalHeight = _displayRowCount * _rowHeight;
    double totalWidth =
        editorContentWidth(_maxRelevantLineLength(), _charWidth) + _gutterWidth;
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            HardwareKeyboard.instance.isControlPressed) {
          _handleFontZoom(event);
        }
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          // Let Alt+X (toggle menu) bubble up.
          if (HardwareKeyboard.instance.isAltPressed &&
              event.logicalKey == LogicalKeyboardKey.keyX) {
            return KeyEventResult.ignored;
          }
          // Let app-level shortcuts (save / open / close tab / new) bubble up.
          if (HardwareKeyboard.instance.isControlPressed &&
              _bubbleShortcutKeys.contains(event.logicalKey)) {
            return KeyEventResult.ignored;
          }
          // Alt+<digit> is fold-to-level, which `_handleGlobalShortcut` owns.
          // This is the guard that actually delivers it: the matching one in
          // [_handleKey] only stops the digit being typed into the document,
          // and the `handled` below would otherwise consume the event before
          // the shell ever sees it.
          if (HardwareKeyboard.instance.isAltPressed &&
              !HardwareKeyboard.instance.isControlPressed &&
              _bubbleAltDigits.contains(event.logicalKey)) {
            return KeyEventResult.ignored;
          }
          _handleKey(event);
          return KeyEventResult.handled;
        },
        child: GestureDetector(
          onTapDown: (details) {
            _focusNode.requestFocus();
            _breakCoalescing();
            double y =
                details.localPosition.dy +
                (_vScroll.hasClients ? _vScroll.offset : 0);
            double x =
                details.localPosition.dx +
                (_hScroll.hasClients ? _hScroll.offset : 0);

            // The fold column sits inside the gutter, which does not scroll
            // horizontally, so it is hit-tested against the raw pointer x.
            if (_foldColumnWidth > 0 &&
                details.localPosition.dx >= _gutterWidth - _foldColumnWidth &&
                details.localPosition.dx < _gutterWidth) {
              final int slot = (y / _rowHeight)
                  .floor()
                  .clamp(0, math.max(0, _displayRowCount - 1))
                  .toInt();
              final row = _displayToDoc(slot);
              if (_folds.any((f) => f.startRow == row)) {
                toggleFoldAt(row);
                return;
              }
            }

            final now = DateTime.now();
            if (_lastTapTime != null &&
                now.difference(_lastTapTime!) <
                    const Duration(milliseconds: 300)) {
              _tapCount = (_tapCount + 1) % 4;
            } else {
              _tapCount = 1;
            }
            _lastTapTime = now;

            setState(() {
              _cursorRow = _displayToDoc(
                (y / _rowHeight).floor().clamp(0, _displayRowCount - 1),
              );
              int unboundedCol = math.max(
                0,
                ((x - _gutterWidth) / _charWidth).round(),
              );
              if (HardwareKeyboard.instance.isAltPressed) {
                _cursorCol = unboundedCol;
              } else {
                _cursorCol = unboundedCol.clamp(0, _getLineLength(_cursorRow));
              }

              if (_tapCount == 1) {
                final ctrl = HardwareKeyboard.instance.isControlPressed;
                if (ctrl) {
                  _selectWordAtCursor(caseSensitive: true);
                } else {
                  if (!HardwareKeyboard.instance.isShiftPressed) {
                    _selStartRow = null;
                    _selStartCol = null;
                    _multiSelections.clear();
                  } else {
                    _selStartRow ??= _cursorRow;
                    _selStartCol ??= _cursorCol;
                  }
                }
              } else if (_tapCount == 2) {
                final ctrl = HardwareKeyboard.instance.isControlPressed;
                _selectWordAtCursor(caseSensitive: ctrl);
              } else if (_tapCount == 3) {
                _multiSelections.clear();
                _selStartRow = _cursorRow;
                _selStartCol = 0;
                _cursorCol = _getLineLength(_cursorRow);
                _tapCount = 0;
              }
            });
          },
          onPanStart: (details) {
            _focusNode.requestFocus();
            _breakCoalescing();
            double y =
                details.localPosition.dy +
                (_vScroll.hasClients ? _vScroll.offset : 0);
            double x =
                details.localPosition.dx +
                (_hScroll.hasClients ? _hScroll.offset : 0);
            setState(() {
              _cursorRow = _displayToDoc(
                (y / _rowHeight).floor().clamp(0, _displayRowCount - 1),
              );
              int unboundedCol = math.max(
                0,
                ((x - _gutterWidth) / _charWidth).round(),
              );
              _isBlockSelection = HardwareKeyboard.instance.isAltPressed;
              if (_isBlockSelection) {
                _cursorCol = unboundedCol;
              } else {
                _cursorCol = unboundedCol.clamp(0, _getLineLength(_cursorRow));
              }
              _selStartRow = _cursorRow;
              _selStartCol = _cursorCol;
              _multiSelections.clear();
            });
          },
          onPanUpdate: (details) {
            double y =
                details.localPosition.dy +
                (_vScroll.hasClients ? _vScroll.offset : 0);
            double x =
                details.localPosition.dx +
                (_hScroll.hasClients ? _hScroll.offset : 0);
            setState(() {
              _cursorRow = _displayToDoc(
                (y / _rowHeight).floor().clamp(0, _displayRowCount - 1),
              );
              int unboundedCol = math.max(
                0,
                ((x - _gutterWidth) / _charWidth).round(),
              );
              if (_isBlockSelection) {
                _cursorCol = unboundedCol;
              } else {
                _cursorCol = unboundedCol.clamp(0, _getLineLength(_cursorRow));
              }
            });
          },
          child: Stack(
            children: [
              // The actual canvas drawing the text
              Positioned.fill(
                child: CustomPaint(
                  painter: EditorPainter(
                    getLineText: _getLineText,
                    visualLineCount: _displayRowCount,
                    foldMap: _foldMap,
                    folds: _folds,
                    collapsedFolds: _collapsedFolds,
                    scrollY: _vScroll.hasClients ? _vScroll.offset : 0,
                    scrollX: _hScroll.hasClients ? _hScroll.offset : 0,
                    cursorRow: _cursorRow,
                    cursorCol: _cursorCol,
                    selStartRow: _selStartRow,
                    selStartCol: _selStartCol,
                    isBlockSelection: _isBlockSelection,
                    multiSelections: _multiSelections,
                    caretOn: _focusNode.hasFocus && _caretVisible,
                    fontSize: _fontSize,
                    textColor: Theme.of(context).brightness == Brightness.light
                        ? Colors.black
                        : Colors.white,
                    brightness: Theme.of(context).brightness,
                    markupTokensFor: _markupTokensFor,
                    markupPair: _markupPair,
                    diagnostics: widget.diagnostics,
                    gutterWidth: _gutterWidth,
                    gutterBg: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    gutterFg: Theme.of(
                      context,
                    ).colorScheme.onSurface.withOpacity(0.45),
                    matches: widget.matches,
                    currentMatch: widget.currentMatch,
                    markedSpans: widget.markedSpans,
                    markedLines: widget.markedLines,
                  ),
                ),
              ),

              // Invisible scrollbars to give us native scrolling & mouse wheel
              Scrollbar(
                controller: _hScroll,
                thumbVisibility: true,
                notificationPredicate: (notif) =>
                    notif.metrics.axis == Axis.horizontal,
                child: Scrollbar(
                  controller: _vScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _vScroll,
                    scrollDirection: Axis.vertical,
                    physics: _ctrlHeld
                        ? const NeverScrollableScrollPhysics()
                        : const ClampingScrollPhysics(),
                    child: SizedBox(
                      height: totalHeight,
                      width: double.infinity,
                      child: SingleChildScrollView(
                        controller: _hScroll,
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: SizedBox(width: totalWidth, height: totalHeight),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EditorPainter extends CustomPainter {
  final int visualLineCount;
  final double scrollY;
  final double scrollX;
  final int cursorRow;
  final int cursorCol;
  final int? selStartRow;
  final int? selStartCol;
  final bool isBlockSelection;
  final List<SelectionRange>? multiSelections;
  final String Function(int) getLineText;
  final bool caretOn;
  final Color textColor;
  final Brightness brightness;

  /// Syntax tokens for a row range, straight from the Rust lexer. Called once
  /// per paint for the visible rows only; null for a plain-text document.
  final List<StructuredRowTokens> Function(int from, int to)? markupTokensFor;

  /// The delimiter pair the caret is on or inside, washed to show the match.
  final StructuredPair? markupPair;

  /// Validation problems, marked with a red underline where they occur.
  final List<StructuredDiagnostic> diagnostics;

  /// Document rows to screen rows. Identity when nothing is collapsed.
  final FoldMap foldMap;

  /// Collapsible regions, for the gutter's boxes and guide lines.
  final List<StructuredFold> folds;

  /// Start rows of the regions currently collapsed.
  final Set<int> collapsedFolds;

  final double fontSize;

  /// Line-number gutter: width (0 = hidden) and its colors.
  final double gutterWidth;
  final Color gutterBg;
  final Color gutterFg;

  /// Matches visible in the current viewport. Painted beneath the text.
  final List<MatchSpan> matches;

  /// The match the find panel is currently on, accented above the rest.
  final MatchSpan? currentMatch;

  /// Marked spans and bookmarked lines.
  final List<MarkedSpan> markedSpans;
  final Set<int> markedLines;

  final Color matchColor;
  final Color currentMatchColor;

  double get rowHeight => fontSize * (20.0 / 14.0);
  double get charWidth => fontSize * (8.4 / 14.0);

  /// The strip at the gutter's right edge carrying the fold boxes and guides.
  /// Zero when the document has nothing to fold, so a plain-text file keeps the
  /// gutter it always had.
  double get foldColumnWidth => folds.isEmpty ? 0 : rowHeight * 0.8;

  double get foldBoxSize => math.min(rowHeight * 0.55, 11.0);

  EditorPainter({
    required this.fontSize,
    required this.visualLineCount,
    required this.scrollY,
    required this.scrollX,
    required this.cursorRow,
    required this.cursorCol,
    required this.selStartRow,
    required this.selStartCol,
    required this.isBlockSelection,
    this.multiSelections,
    required this.getLineText,
    required this.caretOn,
    required this.textColor,
    required this.brightness,
    this.markupTokensFor,
    this.markupPair,
    this.diagnostics = const [],
    required this.foldMap,
    this.folds = const [],
    this.collapsedFolds = const {},
    this.gutterWidth = 0,
    this.gutterBg = const Color(0xFF2A2A2A),
    this.gutterFg = const Color(0x80FFFFFF),
    this.matches = const [],
    this.currentMatch,
    this.markedSpans = const [],
    this.markedLines = const {},
    // The hex editor's modified-byte yellow (0xFFFFF9BD), carried over for
    // visual consistency. It is opaque there because that view also flips the
    // text to dark; here highlights sit under the editor's normal light-on-dark
    // text, so it runs at ~44% alpha — enough to read as yellow rather than the
    // muted grey-green the old 25% amber produced, while keeping text legible.
    this.matchColor = const Color(0x70FFF9BD),
    this.currentMatchColor = const Color(0xB3FFA726),
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    // Text layer is drawn in content space, shifted right by the gutter and
    // left by the horizontal scroll. Isolated in save/restore so the gutter can
    // be painted afterwards in fixed screen space, occluding scrolled text.
    canvas.save();
    canvas.translate(gutterWidth - scrollX, 0);

    final int firstVisibleRow = (scrollY / rowHeight).floor().clamp(
      0,
      visualLineCount,
    );
    final int visibleRowCount = (size.height / rowHeight).ceil() + 1;
    final int lastVisibleRow = (firstVisibleRow + visibleRowCount).clamp(
      0,
      visualLineCount,
    );

    // `firstVisibleRow`/`lastVisibleRow` are screen slots. With a region
    // collapsed they are no longer document rows, so everything positioned by
    // row goes through these two.
    int docOf(int slot) => foldMap.displayToDoc(slot);
    double yOfDoc(int docRow) =>
        (foldMap.docToDisplay(docRow) * rowHeight) - scrollY;

    // The document rows actually on screen, in order.
    final List<int> visibleDocRows = [
      for (int slot = firstVisibleRow; slot < lastVisibleRow; slot++)
        docOf(slot),
    ];

    // Syntax tokens for exactly those rows. Collapsing splits them into
    // contiguous runs; one call per run keeps a collapsed 10,000-row block from
    // being lexed just because it sits between two visible rows.
    final Map<int, List<StructuredToken>> markupTokens = {};
    if (markupTokensFor != null && visibleDocRows.isNotEmpty) {
      int runStart = visibleDocRows.first;
      int previous = runStart;
      void flush(int endExclusive) {
        for (final row in markupTokensFor!(runStart, endExclusive)) {
          markupTokens[row.row] = row.tokens;
        }
      }

      for (final row in visibleDocRows.skip(1)) {
        if (row != previous + 1) {
          flush(previous + 1);
          runStart = row;
        }
        previous = row;
      }
      flush(previous + 1);
    }

    // Match highlights are painted AFTER the selection (see below), not before.
    // `revealSpan` selects the current match, and the selection layer is a 40%
    // blue wash — drawing highlights underneath it turned the current match
    // grey-green until the user clicked into the editor and cleared the
    // selection. Highlights still sit under the text, so both stay legible.
    // The viewport check inside the loop is a *drawing* guard, not the scoping
    // guarantee — it keeps a span that runs off the screen from painting rows
    // nobody can see. What limits find highlights to the viewport in the first
    // place is `_runViewportScan`, which is what hands this its spans.
    void paintSpan(MatchSpan span, Color color) {
      final paint = Paint()..color = color;
      final startRow = span.startRow.toInt();
      final endRow = span.endRow.toInt();
      for (int r = startRow; r <= endRow; r++) {
        if (foldMap.isHidden(r)) continue;
        final slot = foldMap.docToDisplay(r);
        if (slot < firstVisibleRow || slot > lastVisibleRow) {
          continue;
        }
        final line = getLineText(r);
        final from = (r == startRow) ? span.startCol.toInt() : 0;
        final to = (r == endRow) ? span.endCol.toInt() : line.length;
        final y = (slot * rowHeight) - scrollY;
        canvas.drawRect(
          Rect.fromLTWH(
            from * charWidth,
            y,
            (to - from) * charWidth,
            rowHeight,
          ),
          paint,
        );
      }
    }

    // Draw selection first so text renders on top
    if (multiSelections != null && multiSelections!.isNotEmpty) {
      Paint selPaint = Paint()..color = Colors.blue.withOpacity(0.4);
      for (final range in multiSelections!) {
        int r1 = range.startRow;
        int c1 = range.startCol;
        int r2 = range.endRow;
        int c2 = range.endCol;
        if (r1 > r2 || (r1 == r2 && c1 > c2)) {
          int temp = r1;
          r1 = r2;
          r2 = temp;
          temp = c1;
          c1 = c2;
          c2 = temp;
        }
        final int startRow = math.max(r1, firstVisibleRow);
        final int endRow = math.min(r2, lastVisibleRow);
        for (int i = startRow; i <= endRow; i++) {
          String line = getLineText(i);
          double startX = (i == r1) ? c1 * charWidth : 0;
          double endX = (i == r2)
              ? c2 * charWidth
              : (line.length * charWidth + charWidth);
          double y = (i * rowHeight) - scrollY;
          canvas.drawRect(
            Rect.fromLTRB(startX, y, endX, y + rowHeight),
            selPaint,
          );
        }
      }
    } else if (selStartRow != null && selStartCol != null) {
      Paint selPaint = Paint()..color = Colors.blue.withOpacity(0.4);

      if (isBlockSelection) {
        int minR = math.min(selStartRow!, cursorRow);
        int maxR = math.max(selStartRow!, cursorRow);
        int minC = math.min(selStartCol!, cursorCol);
        int maxC = math.max(selStartCol!, cursorCol);

        final int startRow = math.max(minR, firstVisibleRow);
        final int endRow = math.min(maxR, lastVisibleRow);
        for (int i = startRow; i <= endRow; i++) {
          double startX = minC * charWidth;
          double endX = maxC * charWidth;
          double y = (i * rowHeight) - scrollY;
          canvas.drawRect(
            Rect.fromLTRB(startX, y, endX, y + rowHeight),
            selPaint,
          );
        }
      } else {
        int r1 = selStartRow!;
        int c1 = selStartCol!;
        int r2 = cursorRow;
        int c2 = cursorCol;

        if (r1 > r2 || (r1 == r2 && c1 > c2)) {
          int temp = r1;
          r1 = r2;
          r2 = temp;
          temp = c1;
          c1 = c2;
          c2 = temp;
        }

        final int startRow = math.max(r1, firstVisibleRow);
        final int endRow = math.min(r2, lastVisibleRow);
        for (int i = startRow; i <= endRow; i++) {
          String line = getLineText(i);

          double startX = (i == r1) ? c1 * charWidth : 0;
          double endX = (i == r2)
              ? c2 * charWidth
              : (line.length * charWidth + charWidth);
          double y = (i * rowHeight) - scrollY;

          canvas.drawRect(
            Rect.fromLTRB(startX, y, endX, y + rowHeight),
            selPaint,
          );
        }
      }
    }

    // Persistent marked spans
    for (final m in markedSpans) {
      paintSpan(m.span, m.color);
    }

    // Find highlights go on top of the selection wash so the current match
    // stays readable as "current" while the panel still holds focus, then the
    // text is drawn over both.
    for (final m in matches) {
      paintSpan(m, matchColor);
    }
    if (currentMatch != null) {
      paintSpan(currentMatch!, currentMatchColor);
    }

    // The matched delimiter pair. Painted as a wash under the text so the
    // delimiters keep their syntax colour: the highlight adds information
    // rather than replacing it.
    final pair = markupPair;
    if (pair != null) {
      final wash = Paint()..color = MarkupStyling.matchHighlight(brightness);
      void washDelimiter(int row, int col, int len) {
        if (len == 0 || foldMap.isHidden(row)) return;
        final slot = foldMap.docToDisplay(row);
        if (slot < firstVisibleRow || slot >= lastVisibleRow) return;
        final y = (slot * rowHeight) - scrollY;
        canvas.drawRect(
          Rect.fromLTWH(col * charWidth, y, len * charWidth, rowHeight),
          wash,
        );
      }

      washDelimiter(pair.openRow, pair.openCol, pair.openLen);
      washDelimiter(pair.closeRow, pair.closeCol, pair.closeLen);
    }

    final TextPainter textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (int slot = firstVisibleRow; slot < lastVisibleRow; slot++) {
      final int i = docOf(slot);
      String line = getLineText(i);

      // Trailing spaces highlight
      int trailingSpaceCount = 0;
      for (int j = line.length - 1; j >= 0; j--) {
        if (line[j] == ' ') {
          trailingSpaceCount++;
        } else {
          break;
        }
      }

      if (trailingSpaceCount > 0) {
        Paint trailingPaint = Paint()..color = Colors.grey.withOpacity(0.3);
        double startX = (line.length - trailingSpaceCount) * charWidth;
        double endX = line.length * charWidth;
        double y = (slot * rowHeight) - scrollY;
        canvas.drawRect(
          Rect.fromLTRB(startX, y, endX, y + rowHeight),
          trailingPaint,
        );
      }

      final baseStyle = TextStyle(
        fontFamily: 'monospace',
        fontSize: fontSize,
        fontWeight: FontWeight.w500,
        color: textColor,
      );
      final rowTokens = markupTokens[i];
      textPainter.text = rowTokens == null
          ? TextSpan(text: line, style: baseStyle)
          : MarkupStyling.styledLine(
              line: line,
              tokens: rowTokens,
              baseStyle: baseStyle,
              brightness: brightness,
            );

      textPainter.layout();
      textPainter.paint(canvas, Offset(0, (slot * rowHeight) - scrollY));

      // A collapsed region draws a rule across the rest of its header row,
      // standing in for the text it is hiding.
      if (collapsedFolds.contains(i)) {
        final double y = (slot * rowHeight) - scrollY + rowHeight / 2;
        final double from = textPainter.width + charWidth;
        canvas.drawLine(
          Offset(from, y),
          Offset(from + size.width, y),
          Paint()
            ..color = MarkupStyling.collapsedRule(brightness)
            ..strokeWidth = 1.0,
        );
      }
    }

    // Validation problems, marked with a red squiggle beneath the offending
    // span. Painted after the text so the mark stays visible over it, and only
    // for rows on screen.
    if (diagnostics.isNotEmpty) {
      for (final diagnostic in diagnostics) {
        final startRow = diagnostic.row;
        final endRow = diagnostic.endRow;
        final color = MarkupStyling.diagnosticUnderline(
          diagnostic.severity,
          brightness,
        );
        for (int row = startRow; row <= endRow; row++) {
          if (foldMap.isHidden(row)) continue;
          final slot = foldMap.docToDisplay(row);
          if (slot < firstVisibleRow || slot >= lastVisibleRow) continue;
          final lineLength = getLineText(row).length;
          final from = row == startRow ? diagnostic.col : 0;
          final to = row == endRow ? diagnostic.endCol : lineLength;
          // A problem reported at a single point — an unterminated construct at
          // end of input, say — still has to be visible, so give it a
          // character's width rather than nothing.
          final startX = from * charWidth;
          final endX = math.max(to, from + 1) * charWidth;
          final y = (slot * rowHeight) - scrollY + rowHeight - 2;
          _paintSquiggle(canvas, startX, endX, y, color);
        }
      }
    }

    // Draw cursor
    final int cursorSlot = foldMap.docToDisplay(cursorRow);
    if (caretOn &&
        !foldMap.isHidden(cursorRow) &&
        cursorSlot >= firstVisibleRow &&
        cursorSlot <= lastVisibleRow) {
      String lineTilCursor = "";
      String fullLine = getLineText(cursorRow);

      if (cursorCol <= fullLine.length) {
        lineTilCursor = fullLine.substring(0, cursorCol);
      } else {
        lineTilCursor = fullLine;
      }

      textPainter.text = TextSpan(
        text: lineTilCursor,
        style: TextStyle(fontFamily: 'monospace', fontSize: fontSize),
      );
      textPainter.layout();
      double cursorX = textPainter.width;

      Paint cursorPaint = Paint()
        ..color = (textColor == Colors.black
            ? const Color(0xFF00008B)
            : Colors.yellow)
        ..strokeWidth = 2.0;
      double cursorYStart = (cursorSlot * rowHeight) - scrollY + 2;
      double cursorYEnd = cursorYStart + rowHeight - 4;

      canvas.drawLine(
        Offset(cursorX, cursorYStart),
        Offset(cursorX, cursorYEnd),
        cursorPaint,
      );
    }

    // Done with the text layer; drop its translate.
    canvas.restore();

    // Gutter (screen space): opaque strip + right border + right-aligned
    // numbers, occluding any text scrolled underneath it.
    if (gutterWidth > 0) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, gutterWidth, size.height),
        Paint()..color = gutterBg,
      );
      canvas.drawLine(
        Offset(gutterWidth, 0),
        Offset(gutterWidth, size.height),
        Paint()
          ..color = gutterFg.withOpacity(0.25)
          ..strokeWidth = 1.0,
      );

      final int firstSlot = (scrollY / rowHeight).floor().clamp(
        0,
        visualLineCount,
      );
      final int rowsShown = (size.height / rowHeight).ceil() + 1;
      final int lastSlot = (firstSlot + rowsShown).clamp(0, visualLineCount);
      final TextPainter numPainter = TextPainter(
        textDirection: TextDirection.ltr,
      );
      final foldStarts = {for (final f in folds) f.startRow: f};
      final guideColor = MarkupStyling.foldGuide(brightness);

      for (int slot = firstSlot; slot < lastSlot; slot++) {
        final int i = docOf(slot);
        final double rowTop = (slot * rowHeight) - scrollY;
        final double yCenter = rowTop + rowHeight / 2;

        if (markedLines.contains(i)) {
          canvas.drawCircle(
            Offset(6, yCenter),
            3.5,
            Paint()..color = const Color(0xFFE91E63),
          );
        }

        numPainter.text = TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: fontSize,
            color: gutterFg,
          ),
        );
        numPainter.layout();
        final double x =
            gutterWidth - foldColumnWidth - charWidth - numPainter.width;
        final double y = rowTop + (rowHeight - numPainter.height) / 2;
        numPainter.paint(canvas, Offset(x, y));

        // ---- fold column ----
        final double cx = gutterWidth - foldColumnWidth / 2;
        final fold = foldStarts[i];
        final stroke = Paint()
          ..color = guideColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;

        if (fold != null) {
          final collapsed = collapsedFolds.contains(i);
          final double half = foldBoxSize / 2;
          final box = Rect.fromCenter(
            center: Offset(cx, yCenter),
            width: foldBoxSize,
            height: foldBoxSize,
          );
          canvas.drawRect(box, stroke);
          // Minus when open, plus when collapsed — the Notepad++ convention.
          canvas.drawLine(
            Offset(cx - half + 2, yCenter),
            Offset(cx + half - 2, yCenter),
            stroke,
          );
          if (collapsed) {
            canvas.drawLine(
              Offset(cx, yCenter - half + 2),
              Offset(cx, yCenter + half - 2),
              stroke,
            );
          } else {
            // The guide runs from the box down to the region's last row.
            canvas.drawLine(
              Offset(cx, yCenter + half),
              Offset(cx, rowTop + rowHeight),
              stroke,
            );
          }
        } else if (_rowIsInsideAnOpenFold(i)) {
          // Continuation of a guide started above.
          final bool last = _isLastRowOfAnOpenFold(i);
          canvas.drawLine(
            Offset(cx, rowTop),
            Offset(cx, last ? yCenter : rowTop + rowHeight),
            stroke,
          );
          if (last) {
            // The little foot that closes the bracket.
            canvas.drawLine(
              Offset(cx, yCenter),
              Offset(cx + foldBoxSize / 2, yCenter),
              stroke,
            );
          }
        }
      }
    }
  }

  /// True when [docRow] lies inside a fold that is currently expanded, so the
  /// gutter should draw a guide line through it.
  bool _rowIsInsideAnOpenFold(int docRow) {
    for (final fold in folds) {
      if (collapsedFolds.contains(fold.startRow)) continue;
      if (docRow > fold.startRow && docRow <= fold.endRow) return true;
    }
    return false;
  }

  bool _isLastRowOfAnOpenFold(int docRow) {
    for (final fold in folds) {
      if (collapsedFolds.contains(fold.startRow)) continue;
      if (docRow == fold.endRow) return true;
    }
    return false;
  }

  /// A wavy underline from [startX] to [endX] with its baseline at [y].
  ///
  /// A wave rather than a straight rule so it cannot be mistaken for the
  /// underline used elsewhere, and so it reads as an error at a glance.
  void _paintSquiggle(
    Canvas canvas,
    double startX,
    double endX,
    double y,
    Color color,
  ) {
    if (endX <= startX) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    // Wave period scales with the font so the squiggle stays proportionate
    // when the view is zoomed.
    final period = math.max(4.0, charWidth * 0.75);
    final amplitude = math.max(1.0, period * 0.22);
    final path = Path()..moveTo(startX, y);
    var x = startX;
    var up = true;
    while (x < endX) {
      final next = math.min(x + period / 2, endX);
      path.quadraticBezierTo(
        (x + next) / 2,
        up ? y - amplitude : y + amplitude,
        next,
        y,
      );
      x = next;
      up = !up;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant EditorPainter oldDelegate) {
    return true; // For now, just repaint on any state change
  }
}
