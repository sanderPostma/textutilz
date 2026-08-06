import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/src/rust/api/structured.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

import 'app_shell.dart';

/// The status-bar format picker, from the shell.
///
/// `test/language_override_test.dart` covers the pin itself — the model, the
/// Rust precedence, the round trip through the store. This covers only what
/// that cannot reach: that the control is on screen, that its menu lists the
/// formats, and that choosing one pins the document and persists it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  const json = '{\n  "a": 1\n}';

  final picker = find.byKey(const ValueKey('status-document-type'));

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(picker);
    await tester.pumpAndSettle();
  }

  test('the auto-detect sentinel is not a language id', () {
    // The picker distinguishes "no pin" from a pinned format purely by this
    // id failing to resolve. If a format ever claimed it, Auto-detect would
    // silently start pinning instead of clearing.
    expect(structuredLanguageFromId(id: 'auto'), isNull);
    for (final language in structuredLanguages()) {
      expect(structuredLanguageId(language: language), isNot('auto'));
    }
  });

  testWidgets('the status bar shows the detected format', (tester) async {
    await AppShellHarness.pump(tester, documents: {'doc.json': json});
    await tester.pumpAndSettle();

    expect(picker, findsOneWidget);
    expect(
      find.descendant(of: picker, matching: find.text('JSON')),
      findsOneWidget,
    );
  });

  testWidgets('the menu offers auto-detect and every format', (tester) async {
    await AppShellHarness.pump(tester, documents: {'doc.json': json});
    await tester.pumpAndSettle();

    await openMenu(tester);

    expect(find.text('Auto-detect'), findsOneWidget);
    for (final label in ['Plain Text', 'JSON', 'JSON5', 'YAML', 'XML']) {
      expect(
        find.text(label),
        findsWidgets,
        reason: '$label should be offered',
      );
    }
  });

  testWidgets('picking a format pins the document and persists it', (
    tester,
  ) async {
    final harness = await AppShellHarness.pump(
      tester,
      documents: {'doc.json': json},
    );
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('YAML').last);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: picker, matching: find.text('YAML')),
      findsOneWidget,
      reason: 'the status bar should report the pinned format',
    );
    expect(
      harness.persistedSession().single.languageOverride,
      StructuredLanguage.yaml,
      reason: 'the pin should reach the store, not just the widget tree',
    );
  });

  testWidgets('choosing auto-detect clears an existing pin', (tester) async {
    final harness = await AppShellHarness.pump(
      tester,
      documents: {'doc.json': json},
    );
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('XML').last);
    await tester.pumpAndSettle();
    expect(harness.persistedSession().single.languageOverride,
        StructuredLanguage.xml);

    await openMenu(tester);
    await tester.tap(find.text('Auto-detect'));
    await tester.pumpAndSettle();

    expect(harness.persistedSession().single.languageOverride, isNull);
    expect(
      find.descendant(of: picker, matching: find.text('JSON')),
      findsOneWidget,
      reason: 'detection should take over again',
    );
  });

  testWidgets('a pinned plain-text document stops being coloured', (
    tester,
  ) async {
    await AppShellHarness.pump(tester, documents: {'doc.json': json});
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('Plain Text').last);
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: picker, matching: find.text('JSON')),
      findsNothing,
    );
  });
}
