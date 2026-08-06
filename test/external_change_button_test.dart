import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/external_change_button.dart';

void main() {
  Widget host({required bool dirty, required VoidCallback onReload}) {
    return MaterialApp(
      home: Scaffold(
        body: ExternalChangeButton(
          hasUnsavedChanges: dirty,
          onReload: onReload,
        ),
      ),
    );
  }

  testWidgets('clean external change shows amber reload action', (
    tester,
  ) async {
    var reloads = 0;
    await tester.pumpWidget(host(dirty: false, onReload: () => reloads++));

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      Colors.amber.shade600,
    );
    await tester.tap(find.text('Reload'));
    expect(reloads, 1);
  });

  testWidgets('dirty external change shows red warning action', (tester) async {
    await tester.pumpWidget(host(dirty: true, onReload: () {}));

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      Colors.red.shade700,
    );
  });
}
