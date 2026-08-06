import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';

/// Covers the selection normalization used by `CustomEditorState.selectionScope`
/// to back the find/replace panel's "In selection" option.
///
/// `selectionScope` itself is a getter on `CustomEditorState`, which requires
/// live view state (scroll controllers, focus node, gesture-driven selection)
/// that isn't practical to drive through a widget test just to exercise pure
/// normalization logic. The normalization was extracted into the top-level
/// `normalizeSelection` helper in lib/editor.dart, which both `selectionScope`
/// and this test call directly.
void main() {
  group('normalizeSelection', () {
    test('forward selection (anchor before cursor) stays as-is', () {
      final (sr, sc, er, ec) = normalizeSelection(1, 2, 3, 4);
      expect(sr, 1);
      expect(sc, 2);
      expect(er, 3);
      expect(ec, 4);
    });

    test(
      'backward selection (anchor after cursor) normalizes to the same span',
      () {
        // User dragged upward/leftward: anchor is after the cursor (head).
        final (sr, sc, er, ec) = normalizeSelection(3, 4, 1, 2);
        expect(sr, 1);
        expect(sc, 2);
        expect(er, 3);
        expect(ec, 4);
      },
    );

    test('single-row selection normalizes by column when forward', () {
      final (sr, sc, er, ec) = normalizeSelection(5, 2, 5, 9);
      expect(sr, 5);
      expect(sc, 2);
      expect(er, 5);
      expect(ec, 9);
    });

    test('single-row selection normalizes by column when backward', () {
      final (sr, sc, er, ec) = normalizeSelection(5, 9, 5, 2);
      expect(sr, 5);
      expect(sc, 2);
      expect(er, 5);
      expect(ec, 9);
    });
  });
}
