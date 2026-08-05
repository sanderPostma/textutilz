import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/edit_tools_panel.dart';

void main() {
  Widget host({required bool enabled, required ValueChanged<EditOp> onRun}) =>
      MaterialApp(
        home: Scaffold(
          body: EditToolsPanel(
            enabled: enabled,
            onRun: onRun,
            category: EditCategory.commentOps,
          ),
        ),
      );

  testWidgets('clicking an operation runs it immediately', (tester) async {
    EditOp? ran;
    await tester.pumpWidget(host(enabled: true, onRun: (op) => ran = op));
    await tester.tap(find.text('Block Comment'));
    await tester.pump();
    expect(ran, isNotNull);
    expect(ran!.opId, 'edit.comment.block_comment');
  });

  testWidgets('there is no Apply button', (tester) async {
    await tester.pumpWidget(host(enabled: true, onRun: (_) {}));
    expect(find.textContaining('Apply'), findsNothing);
  });

  testWidgets('operations do not run when disabled', (tester) async {
    var ran = false;
    await tester.pumpWidget(host(enabled: false, onRun: (_) => ran = true));
    // warnIfMissed: false below silences "no widget was hit", which would also
    // silence "the chip vanished entirely" — the test would then pass while
    // proving nothing. Assert the chip is actually there first.
    expect(find.text('Block Comment'), findsOneWidget);
    await tester.tap(find.text('Block Comment'), warnIfMissed: false);
    await tester.pump();
    expect(ran, isFalse);
  });
}
