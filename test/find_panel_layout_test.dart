import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/find_panel.dart';
import 'package:textutilz/find_state.dart';
import 'package:textutilz/src/rust/api/edit_session.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

/// Regression test for the narrow-window overflow: the panel's controls used
/// to sit in a single fixed-width `Row`, which throws a `RenderFlex
/// overflowed` exception once the window is narrower than the row's
/// intrinsic width. Task 7's test dodged this by widening the test viewport
/// to 1400x800 instead of fixing the layout. This test pumps the real panel
/// at a deliberately narrow width (500x600) and would fail — via
/// `tester.takeException()` surfacing the overflow assertion — if the Row
/// overflow regressed, in either find or replace mode.
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  // `c.refresh()` makes a real async call across the flutter_rust_bridge
  // isolate boundary. `testWidgets` runs its body inside a `FakeAsync` zone
  // that virtualizes time and cannot observe a completion arriving from that
  // native thread, so awaiting it directly here hangs forever (confirmed by
  // reproduction: it timed out at the framework's 10-minute cap rather than
  // failing fast). `tester.runAsync` steps outside the fake zone for the
  // duration of the call, which is exactly what real async I/O needs.
  Future<FindController> controllerOver(
    WidgetTester tester,
    String content,
  ) async {
    final path =
        '${Directory.systemTemp.path}/textutilz_find_layout_${DateTime.now().microsecondsSinceEpoch}.txt';
    final session = EditSession.createScratch(path: path, content: content);
    final c = FindController();
    c.attach(session, session.lineCount().toInt());
    c.query.text = 'hit';
    // `refresh()` also kicks off a background count sweep it doesn't await
    // (see FindController._startSweep). Wait for that too, so it can't fire
    // a notifyListeners after the test disposes the controller.
    await tester.runAsync(() async {
      await c.refresh();
      await c.awaitSweep();
    });
    return c;
  }

  Future<void> pumpNarrow(
    WidgetTester tester,
    FindController controller,
  ) async {
    tester.view.physicalSize = const Size(500, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FindPanel(
            controller: controller,
            onClose: () {},
            onReveal: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Asserts the controls the brief calls out as most important — the query
  /// field, the step arrows, and the close button — are all actually present
  /// and findable, not merely that nothing threw. A layout that avoided the
  /// overflow by clipping or hiding those controls would pass a bare
  /// `takeException() == null` check but fail this.
  void expectCoreControlsUsable(WidgetTester tester) {
    expect(
      tester.takeException(),
      isNull,
      reason: 'the panel must not throw a RenderFlex overflow at 500px',
    );
    expect(
      find.byTooltip('Find what'),
      findsOneWidget,
      reason: 'the query field must still be present and reachable',
    );
    expect(
      find.byTooltip('Previous match (Shift+F3)'),
      findsOneWidget,
      reason: 'the ▲ step arrow must still be present and reachable',
    );
    expect(
      find.byTooltip('Next match (F3)'),
      findsOneWidget,
      reason: 'the ▼ step arrow must still be present and reachable',
    );
    expect(
      find.byTooltip('Close (Esc)'),
      findsOneWidget,
      reason: 'the close button must still be present and reachable',
    );
  }

  testWidgets('find panel does not overflow a narrow window', (tester) async {
    final controller = await controllerOver(tester, 'hit\nhit\n');
    addTearDown(controller.dispose);

    await pumpNarrow(tester, controller);

    expectCoreControlsUsable(tester);
  });

  testWidgets('replace panel does not overflow a narrow window', (
    tester,
  ) async {
    final controller = await controllerOver(tester, 'hit\nhit\n');
    addTearDown(controller.dispose);
    controller.setMode(FindPanelMode.replace);

    await pumpNarrow(tester, controller);

    expectCoreControlsUsable(tester);
  });

  // --- Width sweep -----------------------------------------------------
  //
  // Two hand-picked widths (500px above) is exactly how a threshold-based
  // layout slipped through review twice: once because the fixed 260px
  // query field only fails past some width nobody tried, and again because
  // a tuned "wide enough" threshold was measured against a short test
  // counter label ("1 of 2") rather than a realistic one ("1 of 20000").
  // This sweeps a wide range of widths, in both modes, against a document
  // large enough to produce a genuinely wide counter label, so there is no
  // single width or content shape doing all the proving.

  /// A document with a five-digit match count, so `counterLabel` renders
  /// something like "1 of 20000" rather than the short "1 of 2" used
  /// elsewhere in this file — the actual shape of content that broke the
  /// threshold-based layout in an earlier round of this task.
  Future<FindController> controllerOverManyMatches(WidgetTester tester) async {
    final content = List.filled(20000, 'hit').join('\n');
    return controllerOver(tester, content);
  }

  /// Pumps the real panel once, then resizes it across [minWidth]..[maxWidth]
  /// in [step] increments, asserting no exception at any width. Reuses one
  /// pumped widget tree across the sweep rather than re-pumping from scratch
  /// at every step, so a ~60-step sweep stays fast.
  Future<void> sweepWidths(
    WidgetTester tester,
    FindController controller, {
    double minWidth = 400,
    double maxWidth = 1600,
    double step = 40,
  }) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FindPanel(
            controller: controller,
            onClose: () {},
            onReveal: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    for (double w = minWidth; w <= maxWidth; w += step) {
      tester.view.physicalSize = Size(w, 600);
      await tester.pump();
      final ex = tester.takeException();
      expect(
        ex,
        isNull,
        reason: 'panel overflowed at width $w with a wide counter label: $ex',
      );
    }
  }

  testWidgets(
    'find panel does not overflow across a width sweep with a wide counter label',
    (tester) async {
      final controller = await controllerOverManyMatches(tester);
      addTearDown(controller.dispose);

      await sweepWidths(tester, controller);
    },
  );

  testWidgets(
    'replace panel does not overflow across a width sweep with a wide counter label',
    (tester) async {
      final controller = await controllerOverManyMatches(tester);
      addTearDown(controller.dispose);
      controller.setMode(FindPanelMode.replace);

      await sweepWidths(tester, controller);
    },
  );
}
