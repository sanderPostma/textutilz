import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';

void main() {
  const double charWidth = 8.4; // matches CustomEditor._charWidth
  // _scrollToCursor targets cursorX + this look-ahead when the caret is at the
  // right edge; the content must extend past that to avoid overscroll/bounce.
  const double caretLookAhead = 20.0;

  group('editorContentWidth', () {
    test('caret at end of a long line is reachable without overscroll', () {
      const int len = 300; // ~2520px caret, well past the old 2000px content
      final double caretEnd = len * charWidth + caretLookAhead;
      expect(
        editorContentWidth(len, charWidth),
        greaterThan(caretEnd),
        reason: 'content must extend past the caret-at-end look-ahead',
      );
    });

    test('regression: long line is wider than the old fixed 2000px', () {
      expect(editorContentWidth(300, charWidth), greaterThan(2000.0));
    });

    test('grows monotonically with line length', () {
      expect(
        editorContentWidth(500, charWidth),
        greaterThan(editorContentWidth(100, charWidth)),
      );
    });

    test('empty line yields a non-negative width', () {
      expect(editorContentWidth(0, charWidth), greaterThanOrEqualTo(0));
    });
  });
}
