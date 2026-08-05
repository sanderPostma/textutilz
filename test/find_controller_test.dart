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

  test('replaceAll honours the in-selection scope', () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    c.scope = SpanScope(
      startRow: BigInt.one,
      startCol: BigInt.zero,
      endRow: BigInt.two,
      endCol: BigInt.from(3),
    );
    c.inSelection = true;
    await c.refresh();
    c.replacement.text = 'X';
    final n = await c.replaceAll();
    expect(n, 2);
    expect(c.session!.line(vrow: BigInt.zero), 'hit',
        reason: 'outside the selection must be untouched');
  });

  test('replaceCurrent advances so repeated calls walk the document', () async {
    final c = await controllerOver('hit hit\n', 'hit');
    c.replacement.text = 'X';
    await c.replaceCurrent();
    await c.replaceCurrent();
    expect(c.session!.line(vrow: BigInt.zero), 'X X');
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

  // --- Fix round 1 regression tests ---------------------------------------

  test('stepForward does not apply state after a superseded generation',
      () async {
    // A single early match, plus many more unscanned rows past the first
    // window, so stepForward must await a further load before it can move.
    final filler = List.filled(5000, 'x').join('\n');
    final c = await controllerOver('hit\n$filler\n', 'hit');
    expect(c.loaded.length, 1);
    expect(c.currentIndex, 0);

    final stepFuture = c.stepForward(); // in flight: awaiting a further load

    // Clearing the query takes refresh()'s early-return path, which is
    // entirely synchronous (no await): generation bumps and matches reset
    // deterministically, with no race against the still-pending step.
    c.query.text = '';
    await c.refresh();
    expect(c.currentIndex, -1);
    expect(c.loaded, isEmpty);

    await stepFuture; // let the now-stale load resolve, whenever that is

    expect(c.currentIndex, -1,
        reason: "the stale stepForward must not touch the new generation's state");
    expect(c.loaded, isEmpty);
  });

  test('a step that pages a new window does not duplicate an in-flight prefetch',
      () async {
    // The window boundary is at row 4096 (kSearchWindowRows).
    //
    //   rows    0-4075 : filler, no matches
    //   rows 4076-4095 : 20 matches, the tail of window 0
    //   rows 4096-4100 :  5 matches, only reachable by paging window 1
    //
    // After refresh, `loaded` holds exactly the 20 matches of window 0, and
    // `_loadedTo` is 4096. `kPrefetchMargin` is 20, so the very FIRST step
    // already trips `_maybePrefetch` and puts a load of window 1 in flight.
    //
    // The steps are fired without awaiting, so later ones run while that
    // prefetch is still pending. Step 20 exhausts the loaded matches and has
    // to page a window itself: it reads `_loadedTo` (still 4096, the prefetch
    // hasn't written it back yet) and, unless it shares the prefetch's
    // in-flight guard, requests window 1 a SECOND time. Both results then get
    // appended — 25 matches become 30, five of them duplicates, F3 visits the
    // same line twice, and the counter can read "30 of 25".
    final rows = <String>[];
    for (var i = 0; i < 4076; i++) {
      rows.add('x');
    }
    for (var i = 0; i < 25; i++) {
      rows.add('hit'); // rows 4076-4100, straddling the window boundary
    }
    final content = '${rows.join('\n')}\n';
    final c = await controllerOver(content, 'hit');
    expect(c.loaded.length, 20, reason: 'only window 0 is loaded at first');

    final steps = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      steps.add(c.stepForward()); // deliberately not awaited in turn
    }
    await Future.wait(steps);
    // Let any prefetch still in flight resolve and append.
    await Future.delayed(const Duration(milliseconds: 300));

    final seen = <String>{};
    for (final m in c.loaded) {
      final key = '${m.startRow}-${m.startCol}-${m.endRow}-${m.endCol}';
      expect(seen.add(key), true, reason: 'duplicate match: $key');
    }
    expect(c.loaded.length, 25,
        reason: 'window 1 must be appended exactly once');
    // And the counter must not claim a position past the total.
    expect(c.currentIndex, lessThan(c.loaded.length));
  });

  test('only a deliberate move asks the host to scroll to the match', () async {
    // `revealTick` is what the panel watches to decide whether to scroll the
    // editor. If it moved on every notification, a background sweep
    // resolving, or the re-scan that follows a keystroke, would drag the
    // editor back to the current match and steal the caret while typing.
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    final afterSearch = c.revealTick;

    // The background count sweep resolving is not a move.
    await c.awaitSweep();
    expect(c.revealTick, afterSearch, reason: 'a sweep is not a move');

    // Nor is a re-scan anchored on the caret — that is what the host runs
    // after the document was edited under the panel.
    await c.refresh(anchorRow: 1, anchorCol: 0);
    expect(c.revealTick, afterSearch,
        reason: 'an anchored re-scan must not scroll the editor');

    // Stepping is.
    await c.stepForward();
    expect(c.revealTick, greaterThan(afterSearch));
    final afterStep = c.revealTick;
    await c.stepBackward();
    expect(c.revealTick, greaterThan(afterStep));

    // So is replacing, which advances past the text just written.
    final afterBack = c.revealTick;
    c.replacement.text = 'X';
    await c.replaceCurrent();
    expect(c.revealTick, greaterThan(afterBack));
  });

  test('disposing mid-scan does not notify a disposed controller', () async {
    // The panel can be closed (and the controller disposed) while a scan or
    // the background count sweep is still in flight. Every post-await
    // notification has to be guarded, or ChangeNotifier throws
    // "A FindController was used after being disposed".
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    // `refresh()` returns as soon as the first window is loaded; the count
    // sweep it started is still running and will notify when it resolves.
    expect(c.sweepRunning, true);
    c.dispose();
    await c.awaitSweep(); // the sweep's notify must not throw

    // Same for a scan that is still in flight when the panel closes.
    final c2 = FindController();
    final session = sessionWith('hit\nhit\nhit\n');
    c2.attach(session, session.lineCount().toInt());
    c2.query.text = 'hit';
    final pending = c2.refresh();
    c2.dispose();
    await pending;
    await c2.awaitSweep();
  });

  // --- Viewport highlighting ----------------------------------------------

  test('the painted viewport set honours "In selection"', () async {
    // The set the editor paints (`scanViewport`) and the set the counter
    // counts (`countMatches`, via `recount`) must agree. Before this was
    // routed through the controller's active scope, the viewport scan called
    // findInRows directly with no scope: with "In selection" on it painted
    // every match on screen while the counter counted only the selected ones,
    // and Replace All touched only the selected ones. The user saw
    // highlights that nothing else agreed with.
    final c = await controllerOver('hit\nhit\nhit\nhit\n', 'hit');

    // No scope: the whole viewport is painted, and that matches the count.
    var painted = await c.scanViewport(0, 4);
    expect(painted.length, 4);
    expect(await c.recount(), 4);

    // Restrict to rows 1-2 and turn "In selection" on.
    c.scope = SpanScope(
      startRow: BigInt.one,
      startCol: BigInt.zero,
      endRow: BigInt.two,
      endCol: BigInt.from(3),
    );
    c.inSelection = true;
    await c.refresh();

    painted = await c.scanViewport(0, 4);
    final counted = await c.recount();
    expect(counted, 2, reason: 'only rows 1 and 2 are in the selection');
    expect(painted.length, counted,
        reason: 'the painted set must not exceed what the counter counts');
    expect(painted.map((m) => m.startRow.toInt()).toList(), [1, 2]);
    // And it must agree with what stepping walks, too.
    expect(c.loaded.length, counted);
  });

  test('a viewport scan outside the selection paints nothing', () async {
    final c = await controllerOver('hit\nhit\nhit\nhit\n', 'hit');
    c.scope = SpanScope(
      startRow: BigInt.from(2),
      startCol: BigInt.zero,
      endRow: BigInt.from(3),
      endCol: BigInt.from(3),
    );
    c.inSelection = true;
    await c.refresh();
    final painted = await c.scanViewport(0, 2); // rows 0-1, all out of scope
    expect(painted, isEmpty);
  });

  test('sweepRunning does not leak when the query is cleared mid-sweep',
      () async {
    final c = await controllerOver('hit\nhit\nhit\n', 'hit');
    expect(c.sweepRunning, true,
        reason: 'refresh() starts a background sweep synchronously');

    c.query.text = '';
    await c.refresh(); // early return: must not leave the sweep orphaned
    await c.awaitSweep();

    expect(c.sweepRunning, false);
  });
}
