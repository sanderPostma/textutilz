import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/fold_map.dart';
import 'package:textutilz/src/rust/api/structured.dart';

StructuredFold _fold(int start, int end, {int level = 0}) => StructuredFold(
  startRow: start,
  endRow: end,
  startCol: 0,
  kind: StructuredFoldKind.object,
  label: '{…}',
  level: level,
);

void main() {
  group('nothing collapsed', () {
    test('is the identity map', () {
      final map = FoldMap.from(
        docRowCount: 10,
        folds: [_fold(1, 5)],
        collapsed: const {},
      );
      expect(map.isIdentity, isTrue);
      expect(map.displayRowCount, 10);
      for (var i = 0; i < 10; i++) {
        expect(map.docToDisplay(i), i);
        expect(map.displayToDoc(i), i);
        expect(map.isHidden(i), isFalse);
      }
    });
  });

  group('one collapsed region', () {
    // Rows 0..9; fold on row 2 covering through row 5 hides 3, 4, 5.
    late FoldMap map;
    setUp(() {
      map = FoldMap.from(
        docRowCount: 10,
        folds: [_fold(2, 5)],
        collapsed: const {2},
      );
    });

    test('the fold start stays visible and its body is hidden', () {
      expect(map.isHidden(2), isFalse);
      for (final row in [3, 4, 5]) {
        expect(map.isHidden(row), isTrue, reason: 'row $row');
      }
      expect(map.isHidden(6), isFalse);
    });

    test('display row count drops by the hidden rows', () {
      expect(map.hiddenRowCount, 3);
      expect(map.displayRowCount, 7);
    });

    test('rows before the fold are unmoved, rows after shift up', () {
      expect(map.docToDisplay(0), 0);
      expect(map.docToDisplay(2), 2);
      expect(map.docToDisplay(6), 3);
      expect(map.docToDisplay(9), 6);
    });

    test('display rows resolve back to the right document rows', () {
      expect(map.displayToDoc(0), 0);
      expect(map.displayToDoc(2), 2);
      expect(map.displayToDoc(3), 6);
      expect(map.displayToDoc(6), 9);
    });

    /// The invariant the painter and hit-tests depend on.
    test('round-trips for every visible row', () {
      for (var row = 0; row < 10; row++) {
        if (map.isHidden(row)) continue;
        expect(map.displayToDoc(map.docToDisplay(row)), row, reason: 'row $row');
      }
      for (var slot = 0; slot < map.displayRowCount; slot++) {
        expect(map.docToDisplay(map.displayToDoc(slot)), slot, reason: '$slot');
      }
    });

    test('a hidden row resolves to its collapsed header, not off-screen', () {
      final display = map.docToDisplay(4);
      expect(display, 3);
      expect(display, lessThanOrEqualTo(map.displayRowCount));
    });

    test('visible-row stepping skips the collapsed body', () {
      expect(map.nextVisible(2), 2);
      expect(map.nextVisible(3), 6);
      expect(map.previousVisible(5), 2);
      expect(map.previousVisible(6), 6);
    });
  });

  group('nested and adjacent regions', () {
    test('an inner fold inside a collapsed outer adds nothing', () {
      final outer = FoldMap.from(
        docRowCount: 20,
        folds: [_fold(1, 10), _fold(3, 6)],
        collapsed: const {1, 3},
      );
      final outerOnly = FoldMap.from(
        docRowCount: 20,
        folds: [_fold(1, 10), _fold(3, 6)],
        collapsed: const {1},
      );
      expect(outer.hiddenRowCount, outerOnly.hiddenRowCount);
      expect(outer.displayRowCount, outerOnly.displayRowCount);
    });

    test('touching regions merge into one', () {
      // Hides 1..3 and 4..6 — contiguous.
      final map = FoldMap.from(
        docRowCount: 10,
        folds: [_fold(0, 3), _fold(3, 6)],
        collapsed: const {0, 3},
      );
      expect(map.hiddenRowCount, 6);
      expect(map.displayRowCount, 4);
      expect(map.displayToDoc(1), 7);
    });

    test('two separate regions both shift the rows after them', () {
      // Hides 2..3 and 7..8.
      final map = FoldMap.from(
        docRowCount: 12,
        folds: [_fold(1, 3), _fold(6, 8)],
        collapsed: const {1, 6},
      );
      expect(map.displayRowCount, 8);
      expect(map.docToDisplay(1), 1);
      expect(map.docToDisplay(4), 2);
      expect(map.docToDisplay(6), 4);
      expect(map.docToDisplay(9), 5);
      for (var slot = 0; slot < map.displayRowCount; slot++) {
        expect(map.docToDisplay(map.displayToDoc(slot)), slot, reason: '$slot');
      }
    });
  });

  group('edges', () {
    test('a fold running to the last row leaves its header visible', () {
      final map = FoldMap.from(
        docRowCount: 5,
        folds: [_fold(0, 4)],
        collapsed: const {0},
      );
      expect(map.displayRowCount, 1);
      expect(map.displayToDoc(0), 0);
      expect(map.nextVisible(1), isNull);
    });

    test('an end row past the document is clamped', () {
      final map = FoldMap.from(
        docRowCount: 4,
        folds: [_fold(0, 99)],
        collapsed: const {0},
      );
      expect(map.displayRowCount, 1);
    });

    test('a collapsed set naming a row with no fold changes nothing', () {
      final map = FoldMap.from(
        docRowCount: 5,
        folds: [_fold(1, 3)],
        collapsed: const {4},
      );
      expect(map.isIdentity, isTrue);
    });

    test('an empty document is handled', () {
      final map = FoldMap.from(
        docRowCount: 0,
        folds: const [],
        collapsed: const {},
      );
      expect(map.displayRowCount, 0);
      expect(map.displayToDoc(0), 0);
    });

    test('out-of-range lookups clamp rather than throw', () {
      final map = FoldMap.from(
        docRowCount: 5,
        folds: [_fold(1, 2)],
        collapsed: const {1},
      );
      expect(map.docToDisplay(-3), 0);
      expect(map.docToDisplay(99), lessThanOrEqualTo(map.displayRowCount));
      expect(map.displayToDoc(-3), 0);
      expect(map.displayToDoc(99), lessThanOrEqualTo(5));
    });
  });

  test('regions hiding a row are reported so they can be expanded', () {
    final folds = [_fold(1, 10), _fold(3, 6)];
    final map = FoldMap.from(
      docRowCount: 20,
      folds: folds,
      collapsed: const {1, 3},
    );
    expect(
      map.collapsedRegionsHiding(docRow: 5, folds: folds, collapsed: {1, 3}),
      [1, 3],
    );
    // The header row itself is not hidden by its own fold.
    expect(
      map.collapsedRegionsHiding(docRow: 1, folds: folds, collapsed: {1, 3}),
      isEmpty,
    );
    expect(
      map.collapsedRegionsHiding(docRow: 15, folds: folds, collapsed: {1, 3}),
      isEmpty,
    );
  });
}
