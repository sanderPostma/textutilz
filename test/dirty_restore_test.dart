import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

import 'app_shell.dart';

/// That unsaved edits survive a restart.
///
/// The bug: only transient scratch documents carried their content in the
/// session store, so a real file was reopened from disk on restore. Quitting
/// with a dirty tab threw the edits away silently — no prompt on the way out,
/// and a clean tab on the way back that closed without asking.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  CustomEditorState editorOf(WidgetTester tester) =>
      tester.state<CustomEditorState>(find.byType(CustomEditor));

  testWidgets('a dirty document is persisted with its edits', (tester) async {
    final harness = await AppShellHarness.pump(
      tester,
      documents: {'notes.txt': 'original'},
    );
    await tester.pumpAndSettle();

    editorOf(tester).widget.session.replaceAll(text: 'edited, not saved');
    await tester.pumpAndSettle();
    // The shell persists on structural changes; ask for one.
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<String>),
        matching: find.text('Read'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      harness.persistedSession().single.scratchContent,
      'edited, not saved',
      reason: 'the unsaved text must reach the store, not just the session',
    );
  });

  testWidgets('a saved document stores no copy of itself', (tester) async {
    // The other half. A clean file must be read from disk on restore, or every
    // session write would carry a duplicate of every open document.
    final harness = await AppShellHarness.pump(
      tester,
      documents: {'notes.txt': 'original'},
    );
    await tester.pumpAndSettle();

    expect(harness.persistedSession().single.scratchContent, isNull);
  });

  testWidgets('and comes back dirty after a restart', (tester) async {
    // The whole point: not merely that the text returns, but that the tab
    // knows it is unsaved, so closing it still asks.
    final harness = await AppShellHarness.pump(
      tester,
      documents: {'notes.txt': 'original'},
      unsavedContent: {'notes.txt': 'edited, not saved'},
    );
    await tester.pumpAndSettle();

    final session = editorOf(tester).widget.session;
    expect(session.contentString(), 'edited, not saved');
    expect(
      session.isDirty(),
      isTrue,
      reason: 'a restored tab with unsaved edits must still be dirty',
    );
    expect(harness.storePath, isNotEmpty);
  });

  testWidgets('a scratch buffer comes back dirty too', (tester) async {
    // The report that reopened this: the tab was a scratch document ("new 14"),
    // not a real file. `createScratch` *writes* its content before opening, so
    // restoring one that way made the unsaved text the baseline and the tab
    // came back clean. Scratch buffers are the case most likely to hold
    // unsaved work, since they have nowhere else to live.
    await AppShellHarness.pump(
      tester,
      documents: {'new 14': ''},
      unsavedContent: {'new 14': 'typed but never saved'},
      transient: {'new 14'},
    );
    await tester.pumpAndSettle();

    final session = editorOf(tester).widget.session;
    expect(session.contentString(), 'typed but never saved');
    expect(
      session.isDirty(),
      isTrue,
      reason: 'the blue unsaved marker must survive the restart',
    );
  });

  testWidgets('an untouched scratch buffer does not come back dirty', (
    tester,
  ) async {
    // The guard: a scratch document created and never typed into is not
    // unsaved work, and must not prompt on close.
    await AppShellHarness.pump(
      tester,
      documents: {'new 15': ''},
      unsavedContent: {'new 15': ''},
      transient: {'new 15'},
    );
    await tester.pumpAndSettle();

    expect(editorOf(tester).widget.session.isDirty(), isFalse);
  });

  testWidgets('a clean restore leaves the document undirtied', (tester) async {
    // The guard on the reapply: rewriting content identical to the file would
    // mark a clean tab dirty and prompt on close for nothing.
    await AppShellHarness.pump(
      tester,
      documents: {'notes.txt': 'original'},
      unsavedContent: {'notes.txt': 'original'},
    );
    await tester.pumpAndSettle();

    expect(editorOf(tester).widget.session.isDirty(), isFalse);
  });
}
