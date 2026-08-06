import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/structured.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

/// End-to-end folding: the Rust lexer's fold regions, the editor's display
/// projection, and the gutter that toggles them.
///
/// The invariant under test is that folding is display-only — collapsing a
/// region changes what is drawn and how far the view scrolls, and never the
/// document itself.
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
        '${Directory.systemTemp.path}/textutilz_fold_${temps.length}.$suffix';
    File(path).writeAsStringSync(content);
    temps.add(path);
    return EditSession.open(path: path);
  }

  /// `{ "a": { "b": 1, "c": 2 }, "d": 3 }` spread over rows 0..6.
  const json = '{\n'
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

  testWidgets('the lexer finds the foldable regions of a JSON document', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final analysis = session.markupAnalysis(
      language: StructuredLanguage.json,
    );
    // Records are not Comparable, so sort on a key.
    final spans = analysis.folds.map((f) => [f.startRow, f.endRow]).toList()
      ..sort((a, b) => a.first.compareTo(b.first));
    expect(spans, [
      [0, 6],
      [1, 4],
    ]);
  });

  testWidgets('collapsing a region hides its rows and shortens the view', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    expect(state.displayRowCount, 7, reason: 'nothing collapsed yet');

    state.toggleFoldAt(1);
    await tester.pumpAndSettle();
    // Rows 2, 3 and 4 disappear; row 1 stays as the header.
    expect(state.displayRowCount, 4);

    state.toggleFoldAt(1);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 7);
  });

  testWidgets('collapsing never changes the document', (tester) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final before = session.contentString();

    key.currentState!.toggleFoldAt(1);
    await tester.pumpAndSettle();
    expect(session.contentString(), before);
    expect(session.lineCount().toInt(), 7);
    expect(session.isDirty(), isFalse);
  });

  testWidgets('a caret left inside a closing region moves to its header', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.gotoLine(4); // row 3, inside the inner object
    await tester.pumpAndSettle();
    expect(state.cursorRow, 3);

    state.toggleFoldAt(1);
    await tester.pumpAndSettle();
    expect(state.cursorRow, 1, reason: 'moved out of the hidden region');
  });

  testWidgets('revealing a row inside a collapsed region expands it', (
    tester,
  ) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.toggleFoldAt(1);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4);

    // Jumping to a hidden row has to open the fold, not scroll to nothing.
    state.gotoLine(4);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 7);
    expect(state.cursorRow, 3);
  });

  testWidgets('an XML document folds by element', (tester) async {
    final session = sessionFor(
      '<r>\n  <a>\n    <b/>\n  </a>\n</r>',
      'xml',
    );
    final key = await pumpEditor(tester, session, StructuredLanguage.xml);
    final state = key.currentState!;
    expect(state.displayRowCount, 5);

    state.toggleFoldAt(1); // <a> … </a>
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 3);
  });

  testWidgets('a plain-text document has nothing to fold', (tester) async {
    final session = sessionFor('one\ntwo\nthree', 'txt');
    final key = await pumpEditor(
      tester,
      session,
      StructuredLanguage.plainText,
    );
    final state = key.currentState!;
    expect(state.displayRowCount, 3);
    state.toggleFoldAt(0);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 3, reason: 'no regions, so no-op');
  });

  testWidgets('toggling a row with no fold does nothing', (tester) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;
    state.toggleFoldAt(3); // an interior row, not a fold header
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 7);
  });

  testWidgets('nested regions collapse independently', (tester) async {
    final session = sessionFor(json, 'json');
    final key = await pumpEditor(tester, session, StructuredLanguage.json);
    final state = key.currentState!;

    state.toggleFoldAt(1);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4);

    // The outer region swallows the inner one; the count is the outer's alone.
    state.toggleFoldAt(0);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 1);

    state.toggleFoldAt(0);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4, reason: 'the inner fold is still closed');
  });

  /// A realistic document: XML declaration, namespaced attributes, a comment,
  /// and self-closing children — the shape that was reported as showing no
  /// fold gutter at all.
  testWidgets('a real-world XML document exposes its fold regions', (
    tester,
  ) async {
    const doc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<form-definitions xmlns:v2r0="https://sphereon.com/forms/v2r0" model-version="2.0">\n'
        '  <form-layouts>\n'
        '    <layout id="valideren-met-autoval">\n'
        '      <layout-mode>vertical</layout-mode>\n'
        '      <initial-splitter-position>38</initial-splitter-position>\n'
        '      <field id="ERRORMSG" presentation-ref="errorbox"/>\n'
        '      <!-- a comment -->\n'
        '    </layout>\n'
        '  </form-layouts>\n'
        '</form-definitions>';
    final session = sessionFor(doc, 'xml');

    final analysis = session.markupAnalysis(language: StructuredLanguage.xml);
    expect(analysis.truncated, isFalse);
    expect(
      analysis.folds.map((f) => f.startRow).toList()..sort(),
      [1, 2, 3],
      reason: 'form-definitions, form-layouts and layout all nest',
    );

    final key = await pumpEditor(tester, session, StructuredLanguage.xml);
    final state = key.currentState!;
    expect(state.displayRowCount, 11);

    state.toggleFoldAt(3); // the <layout> element
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 6);
  });

  /// Folding must not depend on the line-number gutter being switched on.
  testWidgets('the fold column is present with line numbers off', (
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
              showLineNumbers: false,
              markupLanguage: StructuredLanguage.json,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = key.currentState!;
    expect(state.foldColumnWidth, greaterThan(0));

    state.toggleFoldAt(1);
    await tester.pumpAndSettle();
    expect(state.displayRowCount, 4);
  });

}
