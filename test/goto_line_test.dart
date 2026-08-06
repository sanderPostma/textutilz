import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/docked_bar.dart';
import 'package:textutilz/goto_line_panel.dart';
import 'package:textutilz/tool_bar.dart';

void main() {
  testWidgets('ToolBar.handles claims search.goto', (tester) async {
    expect(ToolBar.handles('search.goto'), isTrue);
  });

  testWidgets('ToolBar renders Go to Line title and GotoLinePanel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolBar(
            panelId: 'search.goto',
            editToolsEnabled: true,
            mimeToolsEnabled: true,
            mimeHasSelection: false,
            onRunEditOp: (_) {},
            onRunMimeOp: (_) {},
            onRunStructuredOp: (_) {},
            onClose: () {},
            lineCount: 100,
            currentLine: 1,
          ),
        ),
      ),
    );

    expect(find.text('Go to Line'), findsOneWidget);
    expect(find.text('Line number (1 – 100):'), findsOneWidget);
    expect(find.text('Go'), findsOneWidget);
  });

  testWidgets('GotoLinePanel submits parsed line number on Go press', (
    tester,
  ) async {
    int? requestedLine;
    bool closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DockedBar(
            title: 'Go to Line',
            onClose: () => closed = true,
            child: GotoLinePanel(
              lineCount: 500,
              currentLine: 10,
              onGotoLine: (val) => requestedLine = val,
              onClose: () => closed = true,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    final textField = find.byType(TextField);
    expect(textField, findsOneWidget);

    await tester.enterText(textField, '250');
    await tester.tap(find.text('Go'));
    await tester.pump();

    expect(requestedLine, equals(250));
    expect(closed, isTrue);
  });

  testWidgets('GotoLinePanel submits on TextField Enter key', (tester) async {
    int? requestedLine;
    bool closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DockedBar(
            title: 'Go to Line',
            onClose: () => closed = true,
            child: GotoLinePanel(
              lineCount: 100,
              currentLine: 1,
              onGotoLine: (val) => requestedLine = val,
              onClose: () => closed = true,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.enterText(find.byType(TextField), '42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(requestedLine, equals(42));
    expect(closed, isTrue);
  });
}
