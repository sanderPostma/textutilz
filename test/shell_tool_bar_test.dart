import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/document_state.dart';
import 'package:textutilz/goto_line_panel.dart';
import 'package:textutilz/src/rust/frb_generated.dart';
import 'package:textutilz/tool_bar.dart';

import 'app_shell.dart';

/// The three docked-tool-bar behaviours that had no automated test because
/// they live on the private `_TextEditorState`: `_openToolBar`'s early return,
/// the view-mode retarget, and the live selection marker.
///
/// All three are driven the way a user drives them — a keystroke or a tap —
/// rather than by calling the method. Calling the method would prove only that
/// the method works, and the wiring is where the bugs have been.
///
/// Each group is a pair, and **only the second test of each pair bites** —
/// checked by deleting the three lines they cover and re-running:
///
/// * `_barsMayShow` also guards the *render*, so refusing to store the id is
///   invisible until the tab becomes editable again.
/// * likewise for the retarget: dropping the id and merely failing to render
///   look identical until the mode changes back.
/// * and the forward selection flip is delivered by some other rebuild
///   anyway; only the return trip isolates the change-detector.
///
/// The first of each pair is kept because it is the behaviour a user would
/// describe, and because without it the second could pass with the feature
/// entirely absent. Neither is worth much alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  const text = 'alpha\nbeta\ngamma';

  final goto = find.byType(GotoLinePanel);
  final scopeSelection = find.byKey(const ValueKey('panel-scope-selection'));
  final scopeDocument = find.byKey(const ValueKey('panel-scope-document'));

  Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// Switch the active tab's view mode through the segmented button, which is
  /// the only path that runs the retarget.
  Future<void> switchMode(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<String>),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  group("_openToolBar's early return", () {
    testWidgets('Ctrl+G in Read mode opens nothing', (tester) async {
      await AppShellHarness.pump(
        tester,
        documents: {'notes.txt': text},
        viewMode: ViewMode.read,
      );
      await tester.pumpAndSettle();

      await pressCtrl(tester, LogicalKeyboardKey.keyG);

      expect(goto, findsNothing);
    });

    testWidgets('and the refused id does not surface on the way back to Edit', (
      tester,
    ) async {
      // The bug the early return exists for: storing the id anyway made the
      // click a silent no-op *and* left it behind, so the bar appeared unbidden
      // the moment the tab became editable.
      await AppShellHarness.pump(
        tester,
        documents: {'notes.txt': text},
        viewMode: ViewMode.read,
      );
      await tester.pumpAndSettle();

      await pressCtrl(tester, LogicalKeyboardKey.keyG);
      await switchMode(tester, 'Edit');

      expect(goto, findsNothing);
    });

    testWidgets('while Ctrl+G in Edit mode does open the bar', (tester) async {
      // The control for the two above: without it they would pass just as
      // happily if Ctrl+G were unbound.
      await AppShellHarness.pump(tester, documents: {'notes.txt': text});
      await tester.pumpAndSettle();

      await pressCtrl(tester, LogicalKeyboardKey.keyG);

      expect(goto, findsOneWidget);
    });
  });

  group('the view-mode retarget', () {
    testWidgets('leaving Edit mode drops the docked bar', (tester) async {
      await AppShellHarness.pump(tester, documents: {'notes.txt': text});
      await tester.pumpAndSettle();
      await pressCtrl(tester, LogicalKeyboardKey.keyG);
      expect(goto, findsOneWidget);

      await switchMode(tester, 'Read');

      expect(goto, findsNothing);
    });

    testWidgets('and returning to Edit does not bring it back', (tester) async {
      // Dropping the bar has to clear the id, not just fail the render guard.
      await AppShellHarness.pump(tester, documents: {'notes.txt': text});
      await tester.pumpAndSettle();
      await pressCtrl(tester, LogicalKeyboardKey.keyG);

      await switchMode(tester, 'Read');
      await switchMode(tester, 'Edit');

      expect(goto, findsNothing);
    });
  });

  group('the live selection marker', () {
    /// Open a MIME bar from the ribbon, which is where its scope note is
    /// rendered.
    ///
    /// Reached through the ribbon's search field rather than the Tools column:
    /// the menu table is a plain `Row` of intrinsic-width cards that runs to
    /// ~1130px, so at the app's own 1000px default the Tools column sits off
    /// the right edge and cannot be tapped at all. The search results are a
    /// full-width list, and are the path a keyboard user takes anyway.
    Future<void> openMimeBar(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Base64 Encode');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Base64 Encode').last);
      await tester.pumpAndSettle();
      expect(find.byType(ToolBar), findsOneWidget);
    }

    testWidgets('with no selection the bar warns about the whole document', (
      tester,
    ) async {
      await AppShellHarness.pump(tester, documents: {'notes.txt': text});
      await tester.pumpAndSettle();

      await openMimeBar(tester);

      expect(scopeDocument, findsOneWidget);
      expect(scopeSelection, findsNothing);
    });

    testWidgets('selecting text flips the marker with no other interaction', (
      tester,
    ) async {
      // The bug: selecting wrote only the status-bar ValueNotifier, so the
      // host never rebuilt and the note stayed on "whole document" while a
      // selection was plainly visible.
      await AppShellHarness.pump(tester, documents: {'notes.txt': text});
      await tester.pumpAndSettle();
      await openMimeBar(tester);
      expect(scopeDocument, findsOneWidget);

      await pressCtrl(tester, LogicalKeyboardKey.keyA);

      expect(scopeSelection, findsOneWidget);
      expect(scopeDocument, findsNothing);
    });

    testWidgets('and clearing the selection flips it back', (tester) async {
      // Stale in both directions was the original complaint, so the return
      // trip needs its own assertion.
      await AppShellHarness.pump(tester, documents: {'notes.txt': text});
      await tester.pumpAndSettle();
      await openMimeBar(tester);
      await pressCtrl(tester, LogicalKeyboardKey.keyA);
      expect(scopeSelection, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(scopeDocument, findsOneWidget);
      expect(scopeSelection, findsNothing);
    });
  });
}
