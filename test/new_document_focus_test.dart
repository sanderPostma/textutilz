import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/menu_ribbon.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

/// Opening the New document panel must land the caret in the name field with
/// the suggested name selected, so the very first keystroke names the document
/// instead of being swallowed by a panel with no focus owner.
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  Widget host() => const MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: MenuRibbon(autoOpenNew: true, newDocDefaultName: 'new 7'),
      ),
    ),
  );

  EditableText nameField(WidgetTester tester) {
    final field = find.ancestor(
      of: find.text('Document name'),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    return tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
  }

  testWidgets('New document panel focuses the name field on open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final editable = nameField(tester);
    expect(editable.focusNode.hasFocus, isTrue);
    expect(editable.controller.text, 'new 7');
    expect(
      editable.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
      reason: 'the suggested name should be selected so typing replaces it',
    );
  });
}
