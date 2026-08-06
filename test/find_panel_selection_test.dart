import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';
import 'package:textutilz/find_panel.dart';
import 'package:textutilz/find_state.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

/// Regression test for the Finding-2 fix: opening the find panel from a
/// tab with a live selection must carry that selection into
/// `FindController.scope` immediately, so "In selection" is enabled on the
/// very first Ctrl+F — not only after switching tabs away and back (the
/// only path that previously set `scope`, via `_retargetFind`).
///
/// This drives the real `CustomEditor` and `FindPanel` widgets together in a
/// small harness rather than the full app (`TextEditor`/`_TextEditorState`),
/// whose `_openFind` is private and whose `initState` brings up
/// window_manager and the SQLite session store — not practical to pump in a
/// widget test. The harness's "open find" action reproduces the fixed
/// `_openFind` ordering exactly: `controller.scope = editor.selectionScope`
/// before `controller.attach(...)`.
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('selecting text then opening find enables "In selection"', (
    tester,
  ) async {
    // The panel's Row is wide enough to overflow the default 800x600 test
    // surface (it isn't wrapped in a scroll/flex-shrink container); give the
    // harness a wider viewport so that's not what this test is about.
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path =
        '${Directory.systemTemp.path}/textutilz_find_panel_${DateTime.now().microsecondsSinceEpoch}.txt';
    final session = EditSession.createScratch(
      path: path,
      content: 'hello world\n',
    );
    addTearDown(() {
      try {
        File(path).deleteSync();
      } catch (_) {}
    });

    final editorKey = GlobalKey<CustomEditorState>();
    final controller = FindController();
    addTearDown(controller.dispose);
    bool findVisible = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: [
                  if (findVisible)
                    FindPanel(
                      controller: controller,
                      onClose: () => setState(() => findVisible = false),
                      onReveal: (span) =>
                          editorKey.currentState?.revealSpan(span),
                    ),
                  Expanded(
                    child: CustomEditor(key: editorKey, session: session),
                  ),
                  ElevatedButton(
                    // Stand-in for the app's Ctrl+F handler: after the
                    // Finding-2 fix, _openFind reads the editor's current
                    // selection into the controller's scope before attach.
                    onPressed: () {
                      controller.scope = editorKey.currentState?.selectionScope;
                      controller.attach(session, session.lineCount().toInt());
                      setState(() => findVisible = true);
                    },
                    child: const Text('open find'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // Select "hello" (5 chars) via Shift+Right, relying on the editor's
    // autofocus to already hold keyboard focus.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(
      editorKey.currentState!.selectionScope,
      isNotNull,
      reason: 'setup: expected a live selection before opening find',
    );
    expect(controller.scope, isNull, reason: 'setup: panel not opened yet');

    await tester.tap(find.text('open find'));
    await tester.pump();

    expect(
      controller.scope,
      isNotNull,
      reason: 'opening find should have carried the selection into scope',
    );

    final inSelectionInkWell = find.descendant(
      of: find.byTooltip('In selection'),
      matching: find.byType(InkWell),
    );
    expect(inSelectionInkWell, findsOneWidget);
    final inkWell = tester.widget<InkWell>(inSelectionInkWell);
    expect(
      inkWell.onTap,
      isNotNull,
      reason: '"In selection" should be enabled when scope is non-null',
    );
  });
}
