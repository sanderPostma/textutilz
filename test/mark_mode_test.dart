import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/find_state.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  EditSession sessionWith(String content) {
    final path =
        '${Directory.systemTemp.path}/textutilz_mark_${DateTime.now().microsecondsSinceEpoch}.txt';
    return EditSession.createScratch(path: path, content: content);
  }

  test(
    'markAll populates markedSpans and markedLines when bookmarkLine is true',
    () async {
      final session = sessionWith('alpha\nbeta\nalpha gamma\nalpha\n');
      final c = FindController();
      c.attach(session, session.lineCount().toInt());
      c.query.text = 'alpha';
      c.bookmarkLine = true;

      final count = await c.markAll();
      expect(count, equals(3));
      expect(c.markedSpans.length, equals(3));
      expect(c.markedLines, containsAll([0, 2, 3]));
    },
  );

  test(
    'marking multiple words preserves existing marks with cycling colors',
    () async {
      final session = sessionWith('alpha beta gamma\nalpha delta\n');
      final c = FindController();
      c.attach(session, session.lineCount().toInt());

      c.query.text = 'alpha';
      await c.markAll();
      expect(c.markedSpans.length, equals(2));
      final firstColor = c.markedSpans.first.color;

      c.query.text = 'beta';
      await c.markAll();
      expect(c.markedSpans.length, equals(3));
      final nextColor = c.markedSpans.last.color;
      expect(nextColor, isNot(equals(firstColor)));

      expect(c.markedSpans[0].color, equals(firstColor));
      expect(c.markedSpans[1].color, equals(firstColor));
    },
  );

  test('clearMarks empties markedSpans and markedLines', () async {
    final session = sessionWith('foo\nbar\nfoo\n');
    final c = FindController();
    c.attach(session, session.lineCount().toInt());
    c.query.text = 'foo';
    c.bookmarkLine = true;

    await c.markAll();
    expect(c.markedSpans.length, equals(2));

    c.clearMarks();
    expect(c.markedSpans, isEmpty);
    expect(c.markedLines, isEmpty);
  });

  test('copyMarkedText returns joined text of marked spans', () async {
    final session = sessionWith('hello world\nhello flutter\nbye world\n');
    final c = FindController();
    c.attach(session, session.lineCount().toInt());
    c.query.text = 'hello';
    c.bookmarkLine = false;

    await c.markAll();
    final text = c.copyMarkedText();
    expect(text, equals('hello\nhello\n'));
  });

  test(
    'copyMarkedText returns bookmarked lines when bookmarkLine is true',
    () async {
      final session = sessionWith('first line\nsecond line\nfirst again\n');
      final c = FindController();
      c.attach(session, session.lineCount().toInt());
      c.query.text = 'first';
      c.bookmarkLine = true;

      await c.markAll();
      final text = c.copyMarkedText();
      expect(text, equals('first line\nfirst again\n'));
    },
  );
}
