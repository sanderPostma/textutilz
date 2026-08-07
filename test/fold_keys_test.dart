import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';
import 'package:textutilz/find_panel.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

import 'app_shell.dart';

/// That a fold *keypress* reaches its command.
///
/// `test/fold_commands_test.dart` covers what the commands do once called;
/// this covers the wiring in between — `_handleFoldShortcut` in the app shell
/// and the editor's `_bubbleAltDigits` guard, which has to let Alt+digit past
/// instead of swallowing it. Neither is reachable without pumping the shell,
/// which is why these were manual checks until now.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  /// Rows 0..6. Two nested regions: `[0,6]` at level 0, `[1,4]` at level 1.
  const json =
      '{\n'
      '  "a": {\n'
      '    "b": 1,\n'
      '    "c": 2\n'
      '  },\n'
      '  "d": 3\n'
      '}';

  /// The live editor of the active tab.
  CustomEditorState editorOf(WidgetTester tester) =>
      tester.state<CustomEditorState>(find.byType(CustomEditor));

  /// Press [key] with the given modifiers held, the way a user would — the
  /// handlers read `HardwareKeyboard.instance`, so the modifiers must really
  /// be down rather than passed as flags.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool alt = false,
    bool control = false,
    bool shift = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<CustomEditorState> openJson(WidgetTester tester) async {
    await AppShellHarness.pump(tester, documents: {'doc.json': json});
    await tester.pumpAndSettle();
    final editor = editorOf(tester);
    expect(
      editor.displayRowCount,
      7,
      reason: 'the document should start fully expanded',
    );
    return editor;
  }

  testWidgets('Alt+0 folds all and Alt+Shift+0 unfolds all', (tester) async {
    final editor = await openJson(tester);

    await press(tester, LogicalKeyboardKey.digit0, alt: true);
    expect(editor.displayRowCount, 1);

    await press(tester, LogicalKeyboardKey.digit0, alt: true, shift: true);
    expect(editor.displayRowCount, 7);
  });

  testWidgets('Alt+2 folds to the second nesting level', (tester) async {
    // Level 2 keeps the outer object open and closes the inner one, hiding its
    // body: rows 0, 1, 5 and 6 stay visible.
    final editor = await openJson(tester);

    await press(tester, LogicalKeyboardKey.digit2, alt: true);
    expect(editor.displayRowCount, 4);

    await press(tester, LogicalKeyboardKey.digit2, alt: true, shift: true);
    expect(editor.displayRowCount, 7);
  });

  testWidgets('Ctrl+Alt+F collapses the region around the caret', (
    tester,
  ) async {
    final editor = await openJson(tester);

    await press(tester, LogicalKeyboardKey.keyF, control: true, alt: true);
    // The caret starts on row 0, whose innermost open region is the whole
    // document.
    expect(editor.displayRowCount, 1);

    await press(
      tester,
      LogicalKeyboardKey.keyF,
      control: true,
      alt: true,
      shift: true,
    );
    expect(editor.displayRowCount, 7);
  });

  testWidgets('Ctrl+Alt+F does not fall through to Ctrl+F and open find', (
    tester,
  ) async {
    // The bug this guards: Alt+digit and Ctrl+Alt+F are matched before the
    // `isControlPressed` switch, so a fold binding must be reported handled
    // even when it does nothing — otherwise Ctrl+Alt+F reaches the Ctrl+F case.
    await openJson(tester);

    await press(tester, LogicalKeyboardKey.keyF, control: true, alt: true);

    expect(find.byType(FindPanel), findsNothing);
  });

  testWidgets('Alt+digit does not type into the document', (tester) async {
    // `_bubbleAltDigits` exists so the editor lets Alt+digit reach the shell
    // rather than inserting it. If that guard regresses the fold still fires,
    // so only the document text catches it.
    await AppShellHarness.pump(tester, documents: {'doc.json': json});
    await tester.pumpAndSettle();
    final editor = editorOf(tester);
    final before = editor.widget.session.contentString();

    await press(tester, LogicalKeyboardKey.digit0, alt: true);
    await press(tester, LogicalKeyboardKey.digit2, alt: true);

    expect(editor.widget.session.contentString(), before);
  });

  testWidgets('Fold All from the View menu closes the ribbon', (tester) async {
    // Fold All is a one-shot command, and leaving the ribbon open over the
    // result hid the only thing the user asked to see.
    final editor = await openJson(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.text('Fold All'), findsOneWidget);

    await tester.tap(find.text('Fold All'));
    await tester.pumpAndSettle();

    expect(editor.displayRowCount, 1, reason: 'the command should have run');
    expect(
      find.text('Fold All'),
      findsNothing,
      reason: 'the ribbon should have closed behind it',
    );
  });

  testWidgets('a plain document ignores the fold keys', (tester) async {
    await AppShellHarness.pump(
      tester,
      documents: {'notes.txt': 'just some notes\nnothing structured here'},
    );
    await tester.pumpAndSettle();
    final editor = editorOf(tester);
    expect(editor.hasFolds, isFalse);

    await press(tester, LogicalKeyboardKey.digit0, alt: true);

    expect(editor.displayRowCount, 2);
  });
}
