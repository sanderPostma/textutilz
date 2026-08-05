import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/menu_ribbon.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

/// A ribbon entry that opens a docked tool BAR must be disabled when that bar
/// cannot render. Without the gate the click closed the ribbon and did nothing
/// visible, and the bar's own "Open a document in Edit mode to run MIME tools."
/// explanation was unreachable on exactly the path that needed it.
///
/// Both routes to a tool bar are covered: the menu table and the search box.
/// The search-results tiles previously applied NO enablement gate at all, so
/// even edit ops were clickable from there in Read mode.
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  Widget host({
    required bool editEnabled,
    required bool mimeEnabled,
    required void Function(String) onOpen,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MenuRibbon(
              editToolsEnabled: editEnabled,
              mimeToolsEnabled: mimeEnabled,
              onOpenToolBar: onOpen,
            ),
          ),
        ),
      );

  Future<void> pumpWide(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.pumpAndSettle();
  }

  testWidgets('menu-table edit entry does not open a bar when edit is disabled',
      (tester) async {
    final opened = <String>[];
    await pumpWide(
        tester,
        host(
            editEnabled: false,
            mimeEnabled: false,
            onOpen: opened.add));
    expect(find.text('Blank Operations'), findsOneWidget);
    await tester.tap(find.text('Blank Operations'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('menu-table edit entry opens a bar when edit is enabled',
      (tester) async {
    final opened = <String>[];
    await pumpWide(
        tester,
        host(editEnabled: true, mimeEnabled: true, onOpen: opened.add));
    await tester.tap(find.text('Blank Operations'));
    await tester.pumpAndSettle();
    expect(opened, ['edit.blank']);
  });

  /// The mime.* commands live only in the search results — no menu column
  /// lists them — so this is the ONLY route to a MIME bar from the ribbon.
  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField).first, query);
    await tester.pumpAndSettle();
  }

  /// Scoped to the results list: the query text also lives in the search
  /// field, so a bare find.text would match twice.
  Finder result(String label) => find.descendant(
        of: find.byType(ListView),
        matching: find.text(label),
      );

  testWidgets('search result does not open a MIME bar when mime is disabled',
      (tester) async {
    final opened = <String>[];
    await pumpWide(
        tester,
        host(editEnabled: false, mimeEnabled: false, onOpen: opened.add));
    await search(tester, 'Base64 Encode');
    expect(result('Base64 Encode'), findsOneWidget);
    await tester.tap(result('Base64 Encode'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('search result opens a MIME bar when mime is enabled',
      (tester) async {
    final opened = <String>[];
    await pumpWide(
        tester,
        host(editEnabled: true, mimeEnabled: true, onOpen: opened.add));
    await search(tester, 'Base64 Encode');
    await tester.tap(result('Base64 Encode'));
    await tester.pumpAndSettle();
    expect(opened, ['mime.base64.encode']);
  });

  testWidgets('search result does not open an edit bar when edit is disabled',
      (tester) async {
    final opened = <String>[];
    await pumpWide(
        tester,
        host(editEnabled: false, mimeEnabled: true, onOpen: opened.add));
    await search(tester, 'Blank Operations');
    expect(result('Blank Operations'), findsOneWidget);
    await tester.tap(result('Blank Operations'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });
}
