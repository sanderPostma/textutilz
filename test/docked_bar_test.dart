import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/docked_bar.dart';

void main() {
  Widget host(Widget bar) => MaterialApp(home: Scaffold(body: Column(children: [bar])));

  testWidgets('shows the title tab when a title is given', (tester) async {
    await tester.pumpWidget(host(DockedBar(
      title: 'Comment/Uncomment',
      onClose: () {},
      child: const Text('content'),
    )));
    expect(find.text('Comment/Uncomment'), findsOneWidget);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('shows no tab when the title is null', (tester) async {
    await tester.pumpWidget(host(DockedBar(
      onClose: () {},
      child: const Text('content'),
    )));
    // Only the child's text is present — no title chrome at all.
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('close button invokes onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(host(DockedBar(
      title: 'Convert Case',
      onClose: () => closed = true,
      child: const Text('content'),
    )));
    await tester.tap(find.byTooltip('Close (Esc)'));
    expect(closed, isTrue);
  });

  testWidgets('does not overflow at a narrow width', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(DockedBar(
      title: 'Blank Operations',
      onClose: () {},
      child: Wrap(
        children: List.generate(
          8,
          (i) => Padding(
            padding: const EdgeInsets.all(2),
            child: Text('Operation number $i'),
          ),
        ),
      ),
    )));
    expect(tester.takeException(), isNull);
  });
}
