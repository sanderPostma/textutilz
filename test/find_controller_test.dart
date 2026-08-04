import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/find_state.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/api/search.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  EditSession sessionWith(String content) {
    final path =
        '${Directory.systemTemp.path}/textutilz_find_${DateTime.now().microsecondsSinceEpoch}.txt';
    return EditSession.createScratch(path: path, content: content);
  }

  Future<FindController> controllerOver(String content, String pattern) async {
    final session = sessionWith(content);
    final c = FindController();
    c.attach(session, session.lineCount().toInt());
    c.query.text = pattern;
    await c.refresh();
    return c;
  }

  test('finds matches and reports the first as current', () async {
    final c = await controllerOver('hit\nmiss\nhit\n', 'hit');
    expect(c.loaded.length, 2);
    expect(c.currentIndex, 0);
    expect(c.currentMatch!.startRow.toInt(), 0);
  });

  test('stepForward advances through matches', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 1);
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 2);
  });

  test('stepBackward moves back through matches', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    await c.stepForward();
    await c.stepBackward();
    expect(c.currentMatch!.startRow.toInt(), 0);
  });

  test('wraps to the first match past the end when wrapAround is on', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.wrapAround = true;
    await c.stepForward();
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 0, reason: 'should wrap to start');
  });

  test('wraps to the last match before the start when wrapAround is on', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.wrapAround = true;
    await c.stepBackward();
    expect(c.currentMatch!.startRow.toInt(), 1, reason: 'should wrap to end');
  });

  test('stays on the last match when wrapAround is off', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.wrapAround = false;
    await c.stepForward();
    await c.stepForward();
    expect(c.currentMatch!.startRow.toInt(), 1);
  });

  test('pages in matches beyond the first window', () async {
    // More rows than one window, with a match only far past the first window.
    final filler = List.filled(5000, 'x').join('\n');
    final c = await controllerOver('$filler\nneedle\n', 'needle');
    expect(c.loaded.isNotEmpty, true,
        reason: 'must page past the first window to find it');
    expect(c.currentMatch!.startRow.toInt(), 5000);
  });

  test('counter shows a provisional total then resolves to exact', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    expect(c.counterLabel, contains('1 of 3'));
    await c.awaitSweep();
    expect(c.exactTotal, 3);
    expect(c.counterLabel, '1 of 3');
  });

  test('reports no results for a pattern that does not occur', () async {
    final c = await controllerOver('alpha\nbeta\n', 'gamma');
    expect(c.loaded, isEmpty);
    expect(c.currentMatch, isNull);
    expect(c.counterLabel, 'No results');
  });

  test('surfaces a regex error and does not scan', () async {
    final c = await controllerOver('alpha\n', 'alpha');
    c.searchMode = SearchMode.regex;
    c.query.text = 'a(';
    await c.refresh();
    expect(c.regexError, isNotNull);
    expect(c.loaded, isEmpty);
  });

  test('clears the regex error once the pattern becomes valid', () async {
    final c = await controllerOver('alpha\n', 'alpha');
    c.searchMode = SearchMode.regex;
    c.query.text = 'a(';
    await c.refresh();
    c.query.text = 'a.pha';
    await c.refresh();
    expect(c.regexError, isNull);
    expect(c.loaded.length, 1);
  });

  test('discards results from a superseded generation', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    final stale = c.refresh(); // in flight
    c.query.text = 'miss';
    await c.refresh();
    await stale;
    expect(c.loaded, isEmpty, reason: 'stale results must not be applied');
  });

  test('switching find to replace preserves the query text', () async {
    final c = await controllerOver('hit\n', 'hit');
    c.setMode(FindPanelMode.replace);
    expect(c.query.text, 'hit');
    expect(c.mode, FindPanelMode.replace);
  });

  test('replaceCurrent replaces only the current match', () async {
    final c = await controllerOver('hit hit\n', 'hit');
    c.replacement.text = 'X';
    final n = await c.replaceCurrent();
    expect(n, 1);
    expect(c.session!.line(vrow: BigInt.zero), 'X hit');
  });

  test('replaceAll replaces every match', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    c.replacement.text = 'X';
    final n = await c.replaceAll();
    expect(n, 2);
    expect(c.session!.line(vrow: BigInt.zero), 'X');
    expect(c.session!.line(vrow: BigInt.one), 'X');
  });

  test('recount resolves the exact total', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    final total = await c.recount();
    expect(total, 3);
    expect(c.counterLabel, '1 of 3');
  });

  test('anchoring picks the first match at or after the given position', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    await c.refresh(anchorRow: 1, anchorCol: 0);
    expect(c.currentMatch!.startRow.toInt(), 1);
  });

  test('anchoring past the last match falls back to the first', () async {
    final c = await controllerOver('hit\nhit\n', 'hit');
    await c.refresh(anchorRow: 99, anchorCol: 0);
    expect(c.currentMatch!.startRow.toInt(), 0);
  });

  test('matchCase off finds differently-cased text', () async {
    final c = await controllerOver('HIT\n', 'hit');
    expect(c.loaded, isEmpty);
    c.matchCase = false;
    await c.refresh();
    expect(c.loaded.length, 1);
  });
}
