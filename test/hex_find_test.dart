import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/hex_find_panel.dart';
import 'package:textutilz/hex_find_state.dart';
import 'package:textutilz/src/rust/api/hex_session.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async => RustLib.init());

  File tempWith(List<int> bytes) {
    final file = File(
      '${Directory.systemTemp.path}/textutilz_hex_find_${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    file.writeAsBytesSync(bytes);
    return file;
  }

  test('hex query finds exact bytes and navigation wraps', () async {
    final file = tempWith([0xDE, 0xAD, 0, 0xDE, 0xAD]);
    final controller = HexFindController()
      ..attach(HexSession.open(path: file.path));
    controller.query.text = 'DE AD';
    await controller.refresh();

    expect(controller.matches.map((m) => m.offset), [0, 3]);
    expect(controller.currentMatch?.offset, 0);
    controller.stepForward();
    expect(controller.currentMatch?.offset, 3);
    controller.stepForward();
    expect(controller.currentMatch?.offset, 0);
    controller.stepBackward();
    expect(controller.currentMatch?.offset, 3);

    controller.dispose();
    file.deleteSync();
  });

  test(
    'text query uses UTF-8 and invalid hex reports a useful error',
    () async {
      final file = tempWith(utf8.encode('A € A'));
      final controller = HexFindController()
        ..attach(HexSession.open(path: file.path))
        ..setFormat(HexQueryFormat.text);
      controller.query.text = 'A';
      await controller.refresh();
      expect(controller.matches.map((m) => m.offset), [0, 6]);

      controller.setFormat(HexQueryFormat.hex);
      controller.query.text = 'ABC';
      await controller.refresh();
      expect(controller.matches, isEmpty);
      expect(controller.error, contains('pairs'));

      controller.dispose();
      file.deleteSync();
    },
  );

  test(
    'replace current and replace all update matches and share one undo',
    () async {
      final file = tempWith('one one one'.codeUnits);
      final session = HexSession.open(path: file.path);
      final controller = HexFindController()
        ..attach(session)
        ..setFormat(HexQueryFormat.text);
      controller.query.text = 'one';
      controller.replacement.text = '1';
      await controller.refresh();

      expect(await controller.replaceCurrent(), true);
      expect(
        String.fromCharCodes(
          session.readWindow(offset: BigInt.zero, len: session.len()),
        ),
        '1 one one',
      );
      expect(await controller.replaceAll(), 2);
      expect(
        String.fromCharCodes(
          session.readWindow(offset: BigInt.zero, len: session.len()),
        ),
        '1 1 1',
      );
      session.undo();
      expect(
        String.fromCharCodes(
          session.readWindow(offset: BigInt.zero, len: session.len()),
        ),
        '1 one one',
      );

      controller.dispose();
      file.deleteSync();
    },
  );

  testWidgets('hex panel adapts controls between find and replace', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 600);
    addTearDown(tester.view.reset);
    final file = tempWith([0xAA, 0xBB, 0xAA]);
    final controller = HexFindController()
      ..attach(HexSession.open(path: file.path));
    controller.query.text = 'AA';
    await tester.runAsync(controller.refresh);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HexFindPanel(
            controller: controller,
            onClose: () {},
            onReveal: (_) {},
            onContentChanged: () {},
          ),
        ),
      ),
    );
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.byKey(const Key('hex-replace-query')), findsNothing);

    await tester.tap(find.byTooltip('Switch to Replace'));
    await tester.pump();
    expect(find.byKey(const Key('hex-replace-query')), findsOneWidget);
    expect(find.text('Regex'), findsNothing);
    expect(find.text('Whole word'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    file.deleteSync();
  });
}
