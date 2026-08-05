import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/tool_bar.dart';

void main() {
  Widget host(String panelId) => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ToolBar(
              panelId: panelId,
              editToolsEnabled: true,
              mimeToolsEnabled: true,
              mimeHasSelection: true,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onClose: () {},
            ),
          ]),
        ),
      );

  /// Pump the bar across a range of widths, asserting no overflow at any of
  /// them. Two hand-picked widths have twice failed to catch real overflow in
  /// this codebase; a sweep is what actually bites.
  Future<void> sweep(WidgetTester tester, String panelId) async {
    for (double w = 400; w <= 1600; w += 40) {
      tester.view.physicalSize = Size(w, 600);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(host(panelId));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
    }
  }

  testWidgets('handles() claims the mime/edit panels only', (tester) async {
    expect(ToolBar.handles('edit.comment'), isTrue);
    expect(ToolBar.handles('mime.base64.encode'), isTrue);
    expect(ToolBar.handles('new'), isFalse);
    expect(ToolBar.handles('autodelete'), isFalse);
  });

  testWidgets('edit bar shows its title tab', (tester) async {
    await tester.pumpWidget(host('edit.comment'));
    expect(find.text('Comment/Uncomment'), findsOneWidget);
  });

  testWidgets('mime bar shows its title tab', (tester) async {
    await tester.pumpWidget(host('mime.base64.encode'));
    expect(find.text('Base64 Encode'), findsOneWidget);
  });

  testWidgets('widest edit bar does not overflow across a width sweep',
      (tester) async {
    addTearDown(tester.view.reset);
    // Blank Operations has 8 long labels — the worst case.
    await sweep(tester, 'edit.blank');
  });

  testWidgets('mime bar does not overflow across a width sweep',
      (tester) async {
    addTearDown(tester.view.reset);
    await sweep(tester, 'mime.base64.encode');
  });

  testWidgets('close button stays reachable at 400px', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host('edit.blank'));
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);
  });

  Widget mimeHost({required bool enabled, required bool hasSelection}) =>
      MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ToolBar(
              panelId: 'mime.base64.encode',
              editToolsEnabled: true,
              mimeToolsEnabled: enabled,
              mimeHasSelection: hasSelection,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onClose: () {},
            ),
          ]),
        ),
      );

  testWidgets('mime bar explains it transforms the selection when enabled with a selection',
      (tester) async {
    await tester.pumpWidget(mimeHost(enabled: true, hasSelection: true));
    expect(find.text('Transforms the selection.'), findsOneWidget);
  });

  testWidgets('mime bar explains it transforms the document when enabled with no selection',
      (tester) async {
    await tester.pumpWidget(mimeHost(enabled: true, hasSelection: false));
    expect(find.text('⚠️ Transforms the whole document.'), findsOneWidget);
  });

  testWidgets('mime bar explains why it is disabled', (tester) async {
    await tester.pumpWidget(mimeHost(enabled: false, hasSelection: false));
    expect(find.text('Open a document in Edit mode to run MIME tools.'),
        findsOneWidget);
  });
}
