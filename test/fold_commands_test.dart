import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/structured.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

/// The keyboard-driven fold commands: fold all, unfold all, fold to a nesting
/// level, and collapse/expand the region around the caret.
///
/// `test/fold_gutter_test.dart` covers the click path and the display-only
/// invariant; this file covers only what the commands add on top.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  final temps = <String>[];

  tearDownAll(() {
    for (final path in temps) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  });

  EditSession sessionFor(String content, String suffix) {
    final path =
        '${Directory.systemTemp.path}/textutilz_foldcmd_${temps.length}.$suffix';
    File(path).writeAsStringSync(content);
    temps.add(path);
    return EditSession.open(path: path);
  }

  /// Rows 0..6, two nested regions: `[0,6]` at level 0 and `[1,4]` at level 1.
  const json =
      '{\n'
      '  "a": {\n'
      '    "b": 1,\n'
      '    "c": 2\n'
      '  },\n'
      '  "d": 3\n'
      '}';

  Future<GlobalKey<CustomEditorState>> pumpEditor(
    WidgetTester tester,
    EditSession session,
    StructuredLanguage language,
  ) async {
    final key = GlobalKey<CustomEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: CustomEditor(
              key: key,
              session: session,
              fontSize: 14,
              showLineNumbers: true,
              markupLanguage: language,
            ),
          ),
        ),
      ),
    );
    // Folds are read after the first frame.
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('fold all hides everything but the outermost header', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;
    expect(state.displayRowCount, 7);

    state.foldAll();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 1);

    state.unfoldAll();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 7);
  });

  testWidgets('fold all leaves the document untouched', (tester) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final before = session.contentString();

    key.currentState!.foldAll();
    await tester.pumpAndSettle();

    expect(session.contentString(), before);
    expect(session.lineCount().toInt(), 7);
    expect(session.isDirty(), isFalse);
  });

  testWidgets('fold to level 2 collapses the inner region only', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.foldToLevel(2);
    await tester.pumpAndSettle();
    // Rows 2..4 hidden, the outer braces and row 5 still visible.
    expect(state.displayRowCount, 4);
  });

  testWidgets('fold to level 1 is fold all', (tester) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.foldToLevel(1);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 1);
  });

  testWidgets('fold to a level deeper than the document does nothing', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.foldToLevel(8);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 7);
  });

  testWidgets('fold to a level replaces the previous collapse set', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.foldToLevel(1);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 1);

    // Level 2 must open the outer region again rather than adding to it.
    state.foldToLevel(2);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4);
  });

  testWidgets('unfold level 1 opens the outer region and keeps the inner one', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.foldAll();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 1);

    state.unfoldLevel(1);
    await tester.pumpAndSettle();
    // The inner region stays collapsed underneath: rows 2..4 remain hidden.
    expect(state.displayRowCount, 4);

    state.unfoldLevel(2);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 7);
  });

  testWidgets('collapse at the caret takes the innermost enclosing region', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.gotoLine(3); // row 2, inside the inner object
    await tester.pumpAndSettle();

    state.collapseAtCursor();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4, reason: 'the inner region, not the outer');
    expect(state.cursorRow, 1, reason: 'the caret moved to the header');
  });

  testWidgets('collapse at the caret walks outwards when repeated', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.gotoLine(3);
    await tester.pumpAndSettle();

    state.collapseAtCursor();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4);

    // The caret now sits on row 1, whose innermost region is already closed,
    // so the next press has to take the one outside it.
    state.collapseAtCursor();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 1);

    state.collapseAtCursor();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 1, reason: 'nothing left to close');
  });

  testWidgets('expand at the caret opens the region under it', (tester) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.foldAll();
    await tester.pumpAndSettle();
    expect(state.cursorRow, 0);

    state.expandAtCursor();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4, reason: 'the outer region opened');

    state.gotoLine(2); // row 1, the inner header
    await tester.pumpAndSettle();
    state.expandAtCursor();
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 7);
  });

  testWidgets('the caret commands are no-ops outside any region', (
    tester,
  ) async {
    final session = sessionFor('one\ntwo\nthree', 'txt');
    final key = await pumpEditor(tester, session, StructuredLanguage.plainText);
    final state = key.currentState!;

    state.collapseAtCursor();
    state.expandAtCursor();
    state.foldAll();
    state.foldToLevel(1);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 3);
  });

  testWidgets('a restored collapse is applied on the first frame', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = GlobalKey<CustomEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: CustomEditor(
              key: key,
              session: session,
              fontSize: 14,
              markupLanguage: StructuredLanguage.json,
              initialCollapsedFolds: const {1},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.displayRowCount, 4);
  });

  testWidgets('a restored row that no longer starts a fold is dropped', (
    tester,
  ) async {
    // Row 5 is `"d": 3` — a real row, but not a fold header. A stale entry
    // must not hide anything, and must be reported gone so it is not
    // persisted again.
    final session = sessionFor(json, 'json');
    final key = GlobalKey<CustomEditorState>();
    Set<int>? reported;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: CustomEditor(
              key: key,
              session: session,
              fontSize: 14,
              markupLanguage: StructuredLanguage.json,
              initialCollapsedFolds: const {1, 5},
              onCollapsedFoldsChanged: (rows) => reported = rows,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(key.currentState!.displayRowCount, 4, reason: 'only row 1 folds');
    expect(reported, {1});
  });

  testWidgets('a fold change is reported to the host', (tester) async {
    final session = sessionFor(json, 'json');
    final key = GlobalKey<CustomEditorState>();
    Set<int>? reported;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: CustomEditor(
              key: key,
              session: session,
              fontSize: 14,
              markupLanguage: StructuredLanguage.json,
              onCollapsedFoldsChanged: (rows) => reported = rows,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    key.currentState!.foldAll();
    await tester.pumpAndSettle();
    expect(reported, {0, 1});

    key.currentState!.unfoldAll();
    await tester.pumpAndSettle();
    expect(reported, isEmpty);
  });

  testWidgets('an XML document folds to level', (tester) async {
    final session = sessionFor('<r>\n  <a>\n    <b/>\n  </a>\n</r>', 'xml');
    final key = await pumpEditor(tester, session, StructuredLanguage.xml);
    final state = key.currentState!;
    expect(state.displayRowCount, 5);

    state.foldToLevel(2);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 3, reason: '<a> closed, <r> still open');
  });
}
