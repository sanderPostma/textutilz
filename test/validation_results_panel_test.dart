import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/src/rust/api/structured.dart';
import 'package:textutilz/validation_results_panel.dart';

StructuredDiagnostic _diagnostic({
  int row = 0,
  int col = 0,
  String message = 'Something is wrong.',
  StructuredSeverity severity = StructuredSeverity.error,
}) {
  return StructuredDiagnostic(
    row: row,
    col: col,
    endRow: row,
    endCol: col + 1,
    severity: severity,
    message: message,
  );
}

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Column(children: [child])));

void main() {
  testWidgets('a clean document says so rather than showing an empty list', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ValidationResultsPanel(
          language: StructuredLanguage.json,
          diagnostics: [],
        ),
      ),
    );
    expect(find.text('JSON is valid — no problems found'), findsOneWidget);
    // The header says it all, so the panel shrinks to just that.
    expect(tester.getSize(find.byType(ValidationResultsPanel)).height, 33);
  });

  testWidgets('problems are listed with their position and message', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ValidationResultsPanel(
          language: StructuredLanguage.xml,
          diagnostics: [
            _diagnostic(row: 2, col: 4, message: 'Tag is never closed.'),
            _diagnostic(row: 9, col: 0, message: 'Unexpected token.'),
          ],
          contextLines: const ['  <a>', '  </b>'],
        ),
      ),
    );
    expect(find.text('XML: 2 problems'), findsOneWidget);
    // Rows are 1-based in the UI, 0-based in the data.
    expect(find.text('Line 3, Col 5'), findsOneWidget);
    expect(find.text('Line 10, Col 1'), findsOneWidget);
    expect(
      find.textContaining('Tag is never closed.'),
      findsOneWidget,
    );
  });

  testWidgets('one problem is described in the singular', (tester) async {
    await tester.pumpWidget(
      _host(
        ValidationResultsPanel(
          language: StructuredLanguage.yaml,
          diagnostics: [_diagnostic()],
        ),
      ),
    );
    expect(find.text('YAML: 1 problem'), findsOneWidget);
  });

  testWidgets('double-tapping a row reveals that diagnostic', (tester) async {
    StructuredDiagnostic? revealed;
    final target = _diagnostic(row: 4, col: 2, message: 'Bad.');
    await tester.pumpWidget(
      _host(
        ValidationResultsPanel(
          language: StructuredLanguage.json,
          diagnostics: [target],
          onSelect: (d) => revealed = d,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('validation-result-4-2')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('validation-result-4-2')));
    await tester.pumpAndSettle();

    expect(revealed, isNotNull);
    expect(revealed!.row, 4);
    expect(revealed!.col, 2);
  });

  /// A single tap must not navigate — the panel mirrors the find results panel,
  /// where selecting a row and jumping to it are separate gestures.
  testWidgets('a single tap does not reveal anything', (tester) async {
    var reveals = 0;
    await tester.pumpWidget(
      _host(
        ValidationResultsPanel(
          language: StructuredLanguage.json,
          diagnostics: [_diagnostic(row: 1, col: 1)],
          onSelect: (_) => reveals++,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('validation-result-1-1')));
    await tester.pumpAndSettle();
    expect(reveals, 0);
  });

  /// "Too large to check" must never read as "nothing wrong".
  testWidgets('a truncated analysis explains itself instead of claiming clean', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ValidationResultsPanel(
          language: StructuredLanguage.json,
          diagnostics: [],
          truncated: true,
        ),
      ),
    );
    expect(find.text('JSON: document too large to validate'), findsOneWidget);
    expect(find.textContaining('above the size limit'), findsOneWidget);
    // "Not checked" needs the explanation, so this one keeps its full height.
    expect(tester.getSize(find.byType(ValidationResultsPanel)).height, 180);
  });

  testWidgets('the close button is wired', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      _host(
        ValidationResultsPanel(
          language: StructuredLanguage.json,
          diagnostics: const [],
          onClose: () => closed = true,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('validation-close')));
    expect(closed, isTrue);
  });

  testWidgets('revalidating drops a selection that no longer applies', (
    tester,
  ) async {
    Widget panel(List<StructuredDiagnostic> diagnostics) => _host(
      ValidationResultsPanel(
        language: StructuredLanguage.json,
        diagnostics: diagnostics,
        onSelect: (_) {},
      ),
    );

    await tester.pumpWidget(panel([_diagnostic(row: 0, col: 0)]));
    await tester.tap(find.byKey(const ValueKey('validation-result-0-0')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('validation-result-0-0')));
    await tester.pumpAndSettle();

    final highlighted = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('validation-highlight-0')),
    );
    expect(highlighted.color, isNot(Colors.transparent));

    // A fresh list of problems must not inherit the old highlight.
    await tester.pumpWidget(panel([_diagnostic(row: 7, col: 3)]));
    await tester.pumpAndSettle();
    final refreshed = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('validation-highlight-0')),
    );
    expect(refreshed.color, Colors.transparent);
  });

  testWidgets('with problems it keeps the find panel\'s fixed height', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ValidationResultsPanel(
          language: StructuredLanguage.json,
          diagnostics: [for (var i = 0; i < 50; i++) _diagnostic(row: i)],
        ),
      ),
    );
    final size = tester.getSize(find.byType(ValidationResultsPanel));
    expect(size.height, 180);
  });
}
