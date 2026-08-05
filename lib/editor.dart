import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/search.dart';

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
  const double trailingChars = 6.0; // a little breathing room past the last glyph
  return maxLineLength * charWidth + trailingChars * charWidth + caretPadding;
}

/// Normalize a selection anchor/head pair `(anchorRow, anchorCol)` →
/// `(headRow, headCol)` into `(startRow, startCol, endRow, endCol)` with
/// start always at or before end, regardless of which way the user dragged.
(int, int, int, int) normalizeSelection(int anchorRow, int anchorCol, int headRow, int headCol) {
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
  final void Function(int row, int col, int selChars, int selLines)? onCursorChanged;
  final VoidCallback? onContentChanged;
  final ValueChanged<double>? onFontSizeChanged;
  final bool readOnly;

  /// Matches to highlight, and which of them is current. Supplied by the host
  /// from the find panel; already scoped to the visible rows.
  final List<MatchSpan> matches;
  final MatchSpan? currentMatch;

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
    this.onCursorChanged,
    this.onContentChanged,
    this.onFontSizeChanged,
    this.matches = const [],
    this.currentMatch,
    this.onViewportChanged,
  });

  @override
  State<CustomEditor> createState() => CustomEditorState();
}

class CustomEditorState extends State<CustomEditor> {
  // Ctrl+<key> combos the editor forwards to app-level shortcuts instead of
  // handling itself (save / open / close tab / new).
  static final Set<LogicalKeyboardKey> _bubbleShortcutKeys = {
    LogicalKeyboardKey.keyS,
    LogicalKeyboardKey.keyO,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyN,
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.keyH,
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
    final first = (_vScroll.offset / _rowHeight).floor();
    final visible = (_vScroll.position.viewportDimension / _rowHeight).ceil();
    final last = (first + visible).clamp(0, _visualLineCount);
    return (first.clamp(0, _visualLineCount), last);
  }

  /// Select [span] and scroll it into view. Used by the find panel when the
  /// current match changes.
  void revealSpan(MatchSpan span) {
    setState(() {
      _selStartRow = span.startRow.toInt();
      _selStartCol = span.startCol.toInt();
      _isBlockSelection = false;
      _cursorRow = span.endRow.toInt();
      _cursorCol = span.endCol.toInt();
    });
    _scrollToCursor();
  }

  /// Return keyboard focus to the document. Used when the find panel closes.
  void focusEditor() => _focusNode.requestFocus();

  /// The current linear selection as a search scope, or null when there is
  /// none. Backs the panel's "In selection" option.
  SpanScope? get selectionScope {
    if (!hasLinearSelection) return null;
    final (sr, sc, er, ec) = normalizeSelection(_selStartRow!, _selStartCol!, _cursorRow, _cursorCol);
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
    if (!widget.showLineNumbers) return 0;
    final digits = math.max(2, _visualLineCount.toString().length);
    return (digits + 2) * _charWidth;
  }

  // ---- Session-backed text access & mutation ------------------------------

  /// Replace the entire document with [text] as one undoable step. Used by the
  /// MIME tools to write a transform result back into the editor.
  void replaceAll(String text, {bool requestFocus = true, bool ignoreReadOnly = false}) {
    if (widget.readOnly && !ignoreReadOnly) return;
    setState(() {
      final c = _session.replaceAll(text: text);
      _cursorRow = c.row.toInt();
      _cursorCol = c.col.toInt();
      _selStartRow = null;
      _selStartCol = null;
    });
    widget.onContentChanged?.call();
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
        outputs.add(transform(_getRangeText(range.startRow, range.startCol, range.endRow, range.endCol)));
      }
      final sortedIndices = List<int>.generate(_multiSelections.length, (i) => i);
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
            final tr = r1; r1 = r2; r2 = tr;
            final tc = c1; c1 = c2; c2 = tc;
          }
          _applyDelete(r1, c1, r2, c2);
          _applyInsert(r1, c1, output);
        }
        _session.endGroup();
        _clearSelection();
      });
      widget.onContentChanged?.call();
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
          final tr = r1; r1 = r2; r2 = tr;
          final tc = c1; c1 = c2; c2 = tc;
        }
        _session.beginGroup();
        _applyDelete(r1, c1, r2, c2);
        _applyInsert(r1, c1, output);
        _session.endGroup();
        _clearSelection();
      });
      widget.onContentChanged?.call();
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
      int temp = r1; r1 = r2; r2 = temp;
      temp = c1; c1 = c2; c2 = temp;
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
      final tr = r1; r1 = r2; r2 = tr;
      final tc = c1; c1 = c2; c2 = tc;
    }
    final sb = StringBuffer();
    for (int i = r1; i <= r2; i++) {
      final line = _getLineText(i);
      if (i == r1 && i == r2) {
        sb.write(line.substring(math.min(c1, line.length), math.min(c2, line.length)));
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
    final c = _session.insert(row: BigInt.from(row), col: BigInt.from(col), text: text);
    _cursorRow = c.row.toInt();
    _cursorCol = c.col.toInt();
    widget.onContentChanged?.call();
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
  }

  int _nextWordBoundary(String line, int col) {
    if (col >= line.length) return line.length;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
    int startChar = line.codeUnitAt(col);
    bool startIsAlpha = isAlphaNumeric(startChar);
    bool startIsSpace = startChar == 32;
    for (int i = col + 1; i < line.length; i++) {
      int c = line.codeUnitAt(i);
      bool isAlpha = isAlphaNumeric(c);
      bool isSpace = c == 32;
      if (startIsSpace) { if (!isSpace) return i; }
      else if (startIsAlpha) { if (!isAlpha) return i; }
      else { if (isAlpha || isSpace) return i; }
    }
    return line.length;
  }

  int _prevWordBoundary(String line, int col) {
    if (col <= 0) return 0;
    if (col > line.length) return line.length;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
    int startChar = line.codeUnitAt(col - 1);
    bool startIsAlpha = isAlphaNumeric(startChar);
    bool startIsSpace = startChar == 32;
    for (int i = col - 2; i >= 0; i--) {
      int c = line.codeUnitAt(i);
      bool isAlpha = isAlphaNumeric(c);
      bool isSpace = c == 32;
      if (startIsSpace) { if (!isSpace) return i + 1; }
      else if (startIsAlpha) { if (!isAlpha) return i + 1; }
      else { if (isAlpha || isSpace) return i + 1; }
    }
    return 0;
  }

  int _nextCamelBoundary(String line, int col) {
    if (col >= line.length) return line.length;
    bool isUpper(int c) => c >= 65 && c <= 90;
    bool isLower(int c) => c >= 97 && c <= 122;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || isUpper(c) || isLower(c) || c == 95;
    for (int i = col + 1; i < line.length; i++) {
      int prev = line.codeUnitAt(i - 1);
      int curr = line.codeUnitAt(i);
      if (!isAlphaNumeric(prev) && isAlphaNumeric(curr)) return i;
      if (isAlphaNumeric(prev) && !isAlphaNumeric(curr)) return i;
      if (isLower(prev) && isUpper(curr)) return i;
      if (isUpper(prev) && isUpper(curr) && i + 1 < line.length && isLower(line.codeUnitAt(i + 1))) return i;
      if (prev == 95 && curr != 95) return i;
    }
    return line.length;
  }

  int _prevCamelBoundary(String line, int col) {
    if (col <= 0) return 0;
    if (col > line.length) return line.length;
    bool isUpper(int c) => c >= 65 && c <= 90;
    bool isLower(int c) => c >= 97 && c <= 122;
    bool isAlphaNumeric(int c) => (c >= 48 && c <= 57) || isUpper(c) || isLower(c) || c == 95;
    for (int i = col - 1; i > 0; i--) {
      int prev = line.codeUnitAt(i - 1);
      int curr = line.codeUnitAt(i);
      if (!isAlphaNumeric(prev) && isAlphaNumeric(curr)) return i;
      if (isAlphaNumeric(prev) && !isAlphaNumeric(curr)) return i;
      if (isLower(prev) && isUpper(curr)) return i;
      if (isUpper(prev) && isUpper(curr) && i + 1 < line.length && isLower(line.codeUnitAt(i + 1))) return i;
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
  }

  bool _onHardwareKey(KeyEvent event) {
    final bool held = HardwareKeyboard.instance.isControlPressed;
    if (held != _ctrlHeld && mounted) setState(() => _ctrlHeld = held);
    return false; // never consume — just observe
  }

  void _handleFontZoom(PointerScrollEvent event) {
    if (widget.onFontSizeChanged == null) return;
    final double next =
        (widget.fontSize + (event.scrollDelta.dy < 0 ? 1.0 : -1.0)).clamp(8.0, 40.0);
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
          int temp = r1; r1 = r2; r2 = temp;
          temp = c1; c1 = c2; c2 = temp;
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
        final tr = r1; r1 = r2; r2 = tr;
        final tc = c1; c1 = c2; c2 = tc;
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
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyS) {
      return;
    }

    setState(() {
      _wakeCaret();
      bool ctrl = HardwareKeyboard.instance.isControlPressed;
      bool shift = HardwareKeyboard.instance.isShiftPressed;
      bool alt = HardwareKeyboard.instance.isAltPressed;
      bool meta = HardwareKeyboard.instance.isMetaPressed;

      bool isModifier = event.logicalKey == LogicalKeyboardKey.controlLeft ||
                        event.logicalKey == LogicalKeyboardKey.controlRight ||
                        event.logicalKey == LogicalKeyboardKey.shiftLeft ||
                        event.logicalKey == LogicalKeyboardKey.shiftRight ||
                        event.logicalKey == LogicalKeyboardKey.altLeft ||
                        event.logicalKey == LogicalKeyboardKey.altRight ||
                        event.logicalKey == LogicalKeyboardKey.metaLeft ||
                        event.logicalKey == LogicalKeyboardKey.metaRight;

      if (isModifier) return;

      bool isMovementKey = (event.logicalKey == LogicalKeyboardKey.arrowUp ||
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
        bool isLineMove = ctrl && shift && !alt && (event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.arrowDown);
        bool isScroll = ctrl && !shift && !alt && (event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.arrowDown);

        if (isScroll) {
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _vScroll.jumpTo(math.max(0, _vScroll.offset - _rowHeight));
          } else {
            _vScroll.jumpTo(math.min(_vScroll.position.maxScrollExtent, _vScroll.offset + _rowHeight));
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
          _cursorRow = (_cursorRow - 1).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _cursorRow = (_cursorRow + 1).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
          _cursorRow = (_cursorRow - (_vScroll.position.viewportDimension ~/ _rowHeight)).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
          _cursorRow = (_cursorRow + (_vScroll.position.viewportDimension ~/ _rowHeight)).clamp(0, _visualLineCount - 1);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          if (ctrl || alt) {
            String line = _getLineText(_cursorRow);
            if (_cursorCol == 0 && _cursorRow > 0) {
              _cursorRow--;
              _cursorCol = _getLineText(_cursorRow).length;
            } else {
              _cursorCol = alt ? _prevCamelBoundary(line, _cursorCol) : _prevWordBoundary(line, _cursorCol);
            }
          } else {
            _cursorCol = (_cursorCol - 1).clamp(0, _getLineLength(_cursorRow));
          }
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (ctrl || alt) {
            String line = _getLineText(_cursorRow);
            if (_cursorCol >= line.length && _cursorRow < _visualLineCount - 1) {
              _cursorRow++;
              _cursorCol = 0;
            } else {
              _cursorCol = alt ? _nextCamelBoundary(line, _cursorCol) : _nextWordBoundary(line, _cursorCol);
            }
          } else {
            _cursorCol = (_cursorCol + 1).clamp(0, _getLineLength(_cursorRow));
          }
        } else if (event.logicalKey == LogicalKeyboardKey.home) {
          if (ctrl) _cursorRow = 0; // Ctrl+Home → document top
          _cursorCol = 0;
        } else if (event.logicalKey == LogicalKeyboardKey.end) {
          if (ctrl) _cursorRow = _visualLineCount - 1; // Ctrl+End → document bottom
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
          _cursorRow = math.max(0, _visualLineCount - 1);
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

      if (event.logicalKey == LogicalKeyboardKey.backspace || event.logicalKey == LogicalKeyboardKey.delete) {
        if (_selStartRow != null && _selStartCol != null) {
          // Ctrl+Delete keeps the emptied lines instead of closing the gap.
          _deleteSelection(
            keepBlankLines: ctrl && event.logicalKey == LogicalKeyboardKey.delete,
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
        final bool multiRowSel = _selStartRow != null &&
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
            while (removed < tab && removed < line.length && line[removed] == ' ') {
              removed++;
            }
            if (removed > 0) {
              _applyDelete(i, 0, i, removed);
              if (i == _cursorRow) _cursorCol = math.max(0, _cursorCol - removed);
              if (i == _selStartRow) _selStartCol = math.max(0, _selStartCol! - removed);
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
      int temp = r1; r1 = r2; r2 = temp;
      temp = c1; c1 = c2; c2 = temp;
    }
    
    // Fast path: if copying the entire document, do it natively in Rust
    if (r1 == 0 && c1 == 0 && r2 == _visualLineCount - 1 && c2 == _getLineLength(r2)) {
      _session.copyToClipboard();
      return;
    }
    
    if (_multiSelections.isNotEmpty) {
      final text = _multiSelections.map((range) => _getRangeText(range.startRow, range.startCol, range.endRow, range.endCol)).join('\n');
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
              if (end + 1 < word.length && _isUpper(word[end]) && _isLower(word[end + 1])) {
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

  bool _isUpper(String char) => char.codeUnitAt(0) >= 65 && char.codeUnitAt(0) <= 90;
  bool _isLower(String char) => char.codeUnitAt(0) >= 97 && char.codeUnitAt(0) <= 122;
  bool _isDigit(String char) => char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;

  Future<void> _pasteText() async {
    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data == null || data.text == null || data.text!.isEmpty) return;
    if (!mounted) return;
    final String text =
        data.text!.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
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
      int first = (off / _rowHeight).floor().clamp(0, _visualLineCount - 1);
      int last = ((off + vp) / _rowHeight).ceil().clamp(0, _visualLineCount);
      for (int r = first; r < last; r++) {
        final int len = _getLineLength(r);
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
      final double cursorY = _cursorRow * _rowHeight;
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
         selChars = _session.selectionCharCount(
           r1: BigInt.from(_selStartRow!),
           c1: BigInt.from(_selStartCol!),
           r2: BigInt.from(_cursorRow),
           c2: BigInt.from(_cursorCol),
         ).toInt();
      }
    }
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.onCursorChanged != null) {
        widget.onCursorChanged!(_cursorRow + 1, _cursorCol + 1, selChars, selLines);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _notifyCursor();
    double totalHeight = _visualLineCount * _rowHeight;
    double totalWidth = editorContentWidth(_maxRelevantLineLength(), _charWidth) + _gutterWidth;
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
        if (HardwareKeyboard.instance.isAltPressed && event.logicalKey == LogicalKeyboardKey.keyX) {
          return KeyEventResult.ignored;
        }
        // Let app-level shortcuts (save / open / close tab / new) bubble up.
        if (HardwareKeyboard.instance.isControlPressed &&
            _bubbleShortcutKeys.contains(event.logicalKey)) {
          return KeyEventResult.ignored;
        }
        _handleKey(event);
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        onTapDown: (details) {
          _focusNode.requestFocus();
          _breakCoalescing();
          double y = details.localPosition.dy + (_vScroll.hasClients ? _vScroll.offset : 0);
          double x = details.localPosition.dx + (_hScroll.hasClients ? _hScroll.offset : 0);
          
          final now = DateTime.now();
          if (_lastTapTime != null && now.difference(_lastTapTime!) < const Duration(milliseconds: 300)) {
            _tapCount = (_tapCount + 1) % 4;
          } else {
            _tapCount = 1;
          }
          _lastTapTime = now;

          setState(() {
            _cursorRow = (y / _rowHeight).floor().clamp(0, _visualLineCount - 1);
            int unboundedCol = math.max(0, ((x - _gutterWidth) / _charWidth).round());
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
          double y = details.localPosition.dy + (_vScroll.hasClients ? _vScroll.offset : 0);
          double x = details.localPosition.dx + (_hScroll.hasClients ? _hScroll.offset : 0);
          setState(() {
            _cursorRow = (y / _rowHeight).floor().clamp(0, _visualLineCount - 1);
            int unboundedCol = math.max(0, ((x - _gutterWidth) / _charWidth).round());
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
          double y = details.localPosition.dy + (_vScroll.hasClients ? _vScroll.offset : 0);
          double x = details.localPosition.dx + (_hScroll.hasClients ? _hScroll.offset : 0);
          setState(() {
            _cursorRow = (y / _rowHeight).floor().clamp(0, _visualLineCount - 1);
            int unboundedCol = math.max(0, ((x - _gutterWidth) / _charWidth).round());
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
                  visualLineCount: _visualLineCount,
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
                  textColor: Theme.of(context).brightness == Brightness.light ? Colors.black : Colors.white,
                  gutterWidth: _gutterWidth,
                  gutterBg: Theme.of(context).colorScheme.surfaceContainerHighest,
                  gutterFg: Theme.of(context).colorScheme.onSurface.withOpacity(0.45),
                  matches: widget.matches,
                  currentMatch: widget.currentMatch,
                ),
              ),
            ),
            
            // Invisible scrollbars to give us native scrolling & mouse wheel
            Scrollbar(
              controller: _hScroll,
              thumbVisibility: true,
              notificationPredicate: (notif) => notif.metrics.axis == Axis.horizontal,
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
                      child: SizedBox(
                        width: totalWidth,
                        height: totalHeight,
                      ),
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
  final double fontSize;

  /// Line-number gutter: width (0 = hidden) and its colors.
  final double gutterWidth;
  final Color gutterBg;
  final Color gutterFg;

  /// Matches visible in the current viewport. Painted beneath the text.
  final List<MatchSpan> matches;

  /// The match the find panel is currently on, accented above the rest.
  final MatchSpan? currentMatch;

  final Color matchColor;
  final Color currentMatchColor;

  double get rowHeight => fontSize * (20.0 / 14.0);
  double get charWidth => fontSize * (8.4 / 14.0);

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
    this.gutterWidth = 0,
    this.gutterBg = const Color(0xFF2A2A2A),
    this.gutterFg = const Color(0x80FFFFFF),
    this.matches = const [],
    this.currentMatch,
    this.matchColor = const Color(0x40FFD54F),
    this.currentMatchColor = const Color(0x80FF9800),
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    // Text layer is drawn in content space, shifted right by the gutter and
    // left by the horizontal scroll. Isolated in save/restore so the gutter can
    // be painted afterwards in fixed screen space, occluding scrolled text.
    canvas.save();
    canvas.translate(gutterWidth - scrollX, 0);

    final int firstVisibleRow = (scrollY / rowHeight).floor().clamp(0, visualLineCount);
    final int visibleRowCount = (size.height / rowHeight).ceil() + 1;
    final int lastVisibleRow = (firstVisibleRow + visibleRowCount).clamp(0, visualLineCount);
    
    // Match highlights sit under the selection and the text.
    void paintSpan(MatchSpan span, Color color) {
      final paint = Paint()..color = color;
      final startRow = span.startRow.toInt();
      final endRow = span.endRow.toInt();
      for (int r = startRow; r <= endRow; r++) {
        if (r < firstVisibleRow || r > lastVisibleRow) {
          continue;
        }
        final line = getLineText(r);
        final from = (r == startRow) ? span.startCol.toInt() : 0;
        final to = (r == endRow) ? span.endCol.toInt() : line.length;
        final y = (r * rowHeight) - scrollY;
        canvas.drawRect(
          Rect.fromLTWH(from * charWidth, y, (to - from) * charWidth, rowHeight),
          paint,
        );
      }
    }

    for (final m in matches) {
      paintSpan(m, matchColor);
    }
    if (currentMatch != null) {
      paintSpan(currentMatch!, currentMatchColor);
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
          int temp = r1; r1 = r2; r2 = temp;
          temp = c1; c1 = c2; c2 = temp;
        }
        final int startRow = math.max(r1, firstVisibleRow);
        final int endRow = math.min(r2, lastVisibleRow);
        for (int i = startRow; i <= endRow; i++) {
          String line = getLineText(i);
          double startX = (i == r1) ? c1 * charWidth : 0;
          double endX = (i == r2) ? c2 * charWidth : (line.length * charWidth + charWidth);
          double y = (i * rowHeight) - scrollY;
          canvas.drawRect(Rect.fromLTRB(startX, y, endX, y + rowHeight), selPaint);
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
          canvas.drawRect(Rect.fromLTRB(startX, y, endX, y + rowHeight), selPaint);
        }
      } else {
        int r1 = selStartRow!;
        int c1 = selStartCol!;
        int r2 = cursorRow;
        int c2 = cursorCol;
        
        if (r1 > r2 || (r1 == r2 && c1 > c2)) {
          int temp = r1; r1 = r2; r2 = temp;
          temp = c1; c1 = c2; c2 = temp;
        }
        
        final int startRow = math.max(r1, firstVisibleRow);
        final int endRow = math.min(r2, lastVisibleRow);
        for (int i = startRow; i <= endRow; i++) {
          String line = getLineText(i);
          
          double startX = (i == r1) ? c1 * charWidth : 0;
          double endX = (i == r2) ? c2 * charWidth : (line.length * charWidth + charWidth);
          double y = (i * rowHeight) - scrollY;
          
          canvas.drawRect(Rect.fromLTRB(startX, y, endX, y + rowHeight), selPaint);
        }
      }
    }

    final TextPainter textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (int i = firstVisibleRow; i < lastVisibleRow; i++) {
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
        double y = (i * rowHeight) - scrollY;
        canvas.drawRect(Rect.fromLTRB(startX, y, endX, y + rowHeight), trailingPaint);
      }

      textPainter.text = TextSpan(
        text: line,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: textColor,
        ),
      );
      
      textPainter.layout();
      textPainter.paint(canvas, Offset(0, (i * rowHeight) - scrollY));
    }

    // Draw cursor
    if (caretOn && cursorRow >= firstVisibleRow && cursorRow <= lastVisibleRow) {
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
      
      Paint cursorPaint = Paint()..color = (textColor == Colors.black ? const Color(0xFF00008B) : Colors.yellow)..strokeWidth = 2.0;
      double cursorYStart = (cursorRow * rowHeight) - scrollY + 2;
      double cursorYEnd = cursorYStart + rowHeight - 4;
      
      canvas.drawLine(Offset(cursorX, cursorYStart), Offset(cursorX, cursorYEnd), cursorPaint);
    }

    // Done with the text layer; drop its translate.
    canvas.restore();

    // Gutter (screen space): opaque strip + right border + right-aligned
    // numbers, occluding any text scrolled underneath it.
    if (gutterWidth > 0) {
      canvas.drawRect(Rect.fromLTWH(0, 0, gutterWidth, size.height), Paint()..color = gutterBg);
      canvas.drawLine(
        Offset(gutterWidth, 0),
        Offset(gutterWidth, size.height),
        Paint()
          ..color = gutterFg.withOpacity(0.25)
          ..strokeWidth = 1.0,
      );

      final int firstRow = (scrollY / rowHeight).floor().clamp(0, visualLineCount);
      final int rowsShown = (size.height / rowHeight).ceil() + 1;
      final int lastRow = (firstRow + rowsShown).clamp(0, visualLineCount);
      final TextPainter numPainter = TextPainter(textDirection: TextDirection.ltr);
      for (int i = firstRow; i < lastRow; i++) {
        numPainter.text = TextSpan(
          text: '${i + 1}',
          style: TextStyle(fontFamily: 'monospace', fontSize: fontSize, color: gutterFg),
        );
        numPainter.layout();
        final double x = gutterWidth - charWidth - numPainter.width;
        final double y = (i * rowHeight) - scrollY + (rowHeight - numPainter.height) / 2;
        numPainter.paint(canvas, Offset(x, y));
      }
    }
  }

  @override
  bool shouldRepaint(covariant EditorPainter oldDelegate) {
    return true; // For now, just repaint on any state change
  }
}
