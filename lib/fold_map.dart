import 'src/rust/api/structured.dart';

/// The projection from document rows to the rows actually drawn on screen.
///
/// Folding is kept strictly to display. Document rows stay the coordinate
/// system everywhere else — the caret, selections, find spans and every
/// `EditSession` call still mean document rows — so collapsing a region cannot
/// change what an edit does. Only the painter, the hit-tests and vertical caret
/// movement go through this map.
///
/// Lookups are `O(log k)` in the number of collapsed regions, not `O(rows)`:
/// the hidden rows are held as merged intervals with a prefix sum, so a
/// million-row document with three folds costs three intervals.
class FoldMap {
  /// Rows in the document.
  final int docRowCount;

  /// Collapsed regions, merged and sorted, as inclusive `[first, last]` row
  /// ranges of *hidden* rows. A region's own start row stays visible.
  final List<({int first, int last})> _hidden;

  /// `_hiddenBefore[i]` is the number of hidden rows before `_hidden[i].first`.
  final List<int> _hiddenBefore;

  FoldMap._(this.docRowCount, this._hidden, this._hiddenBefore);

  /// Nothing collapsed: display rows and document rows are the same.
  factory FoldMap.identity(int docRowCount) =>
      FoldMap._(docRowCount, const [], const []);

  /// Build the map for a set of folds and the subset of them that is collapsed.
  ///
  /// `collapsed` holds fold *start rows*. A fold whose start row is itself
  /// hidden inside an outer collapsed region contributes nothing new, which is
  /// what makes nesting work without special handling: merging the intervals
  /// absorbs it.
  factory FoldMap.from({
    required int docRowCount,
    required List<StructuredFold> folds,
    required Set<int> collapsed,
  }) {
    if (collapsed.isEmpty || docRowCount <= 0) {
      return FoldMap.identity(docRowCount);
    }
    final ranges = <({int first, int last})>[];
    for (final fold in folds) {
      final start = fold.startRow;
      if (!collapsed.contains(start)) continue;
      final first = start + 1;
      final last = fold.endRow.clamp(0, docRowCount - 1);
      if (last >= first) ranges.add((first: first, last: last));
    }
    if (ranges.isEmpty) return FoldMap.identity(docRowCount);

    ranges.sort((a, b) => a.first.compareTo(b.first));
    final merged = <({int first, int last})>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.first <= merged.last.last + 1) {
        final previous = merged.removeLast();
        merged.add((
          first: previous.first,
          last: previous.last > range.last ? previous.last : range.last,
        ));
      } else {
        merged.add(range);
      }
    }

    final before = <int>[];
    var running = 0;
    for (final range in merged) {
      before.add(running);
      running += range.last - range.first + 1;
    }
    return FoldMap._(docRowCount, merged, before);
  }

  /// True when nothing is collapsed, so callers can skip the map entirely.
  bool get isIdentity => _hidden.isEmpty;

  /// Total hidden rows.
  int get hiddenRowCount => _hidden.isEmpty
      ? 0
      : _hiddenBefore.last + _hidden.last.last - _hidden.last.first + 1;

  /// Rows drawn on screen.
  int get displayRowCount => docRowCount - hiddenRowCount;

  /// Index of the interval containing `docRow`, or -1.
  int _intervalAt(int docRow) {
    var low = 0;
    var high = _hidden.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final range = _hidden[mid];
      if (docRow < range.first) {
        high = mid - 1;
      } else if (docRow > range.last) {
        low = mid + 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  bool isHidden(int docRow) => _intervalAt(docRow) >= 0;

  /// The display row a document row is drawn at.
  ///
  /// A hidden row maps to the display row of the collapsed region that swallowed
  /// it, so a caret left inside a fold still resolves to somewhere on screen
  /// rather than to a negative or out-of-range slot.
  int docToDisplay(int docRow) {
    if (isIdentity) return docRow.clamp(0, docRowCount);
    final row = docRow.clamp(0, docRowCount);
    // Hidden rows before `row`.
    var hidden = 0;
    var low = 0;
    var high = _hidden.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final range = _hidden[mid];
      if (range.first > row) {
        high = mid - 1;
      } else {
        // This interval starts at or before `row`; count what it hides up to it.
        final upTo = row <= range.last
            ? row - range.first
            : range.last - range.first + 1;
        hidden = _hiddenBefore[mid] + upTo;
        low = mid + 1;
      }
    }
    return row - hidden;
  }

  /// The document row drawn at a display row.
  int displayToDoc(int displayRow) {
    if (isIdentity) return displayRow.clamp(0, docRowCount);
    final slot = displayRow.clamp(0, displayRowCount);
    // Sum the lengths of every interval this slot sits past. The comparison has
    // to be against the original slot, not a running total: `_hiddenBefore`
    // already accounts for the earlier intervals, so mutating the row first
    // would double-count them.
    var offset = 0;
    for (var i = 0; i < _hidden.length; i++) {
      final visibleBefore = _hidden[i].first - _hiddenBefore[i];
      if (slot < visibleBefore) break;
      offset += _hidden[i].last - _hidden[i].first + 1;
    }
    return (slot + offset).clamp(0, docRowCount);
  }

  /// The next visible document row at or after `docRow`, or null past the end.
  int? nextVisible(int docRow) {
    var row = docRow;
    while (row < docRowCount) {
      final at = _intervalAt(row);
      if (at < 0) return row;
      row = _hidden[at].last + 1;
    }
    return null;
  }

  /// The previous visible document row at or before `docRow`, or null.
  int? previousVisible(int docRow) {
    var row = docRow;
    while (row >= 0) {
      final at = _intervalAt(row);
      if (at < 0) return row;
      row = _hidden[at].first - 1;
    }
    return null;
  }

  /// The start rows of every collapsed region hiding `docRow`.
  ///
  /// Used to expand a fold before an edit lands inside it: editing text the user
  /// cannot see is never what they meant.
  List<int> collapsedRegionsHiding({
    required int docRow,
    required List<StructuredFold> folds,
    required Set<int> collapsed,
  }) {
    return [
      for (final fold in folds)
        if (collapsed.contains(fold.startRow) &&
            docRow > fold.startRow &&
            docRow <= fold.endRow)
          fold.startRow,
    ];
  }
}
