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

  /// The menu's MIME entry must open the docked BAR, not the old in-ribbon
  /// panel. It shipped once pointing at the ribbon panel, so the docked MIME
  /// bar was unreachable from the menu entirely — search was its only route.
  testWidgets('menu MIME entry opens the tabbed bar when mime is enabled',
      (tester) async {
    final opened = <String>[];
    await pumpWide(
        tester,
        host(editEnabled: true, mimeEnabled: true, onOpen: opened.add));
    await tester.tap(find.text('MIME tools'));
    await tester.pumpAndSettle();
    expect(opened, ['mime']);
    // The bar is the host's job to render, so the ribbon must not have
    // opened a panel of its own instead.
    expect(find.text('Base64'), findsNothing);
  });

  testWidgets('menu MIME entry does not open a bar when mime is disabled',
      (tester) async {
    final opened = <String>[];
    await pumpWide(
        tester,
        host(editEnabled: true, mimeEnabled: false, onOpen: opened.add));
    await tester.tap(find.text('MIME tools'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

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
