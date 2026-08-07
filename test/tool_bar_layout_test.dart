import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/docked_bar.dart';
import 'package:textutilz/tool_bar.dart';

void main() {
  Widget host(String panelId) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          ToolBar(
            panelId: panelId,
            editToolsEnabled: true,
            mimeToolsEnabled: true,
            mimeHasSelection: true,
            onRunEditOp: (_) {},
            onRunMimeOp: (_) {},
            onRunStructuredOp: (_) {},
            onClose: () {},
          ),
        ],
      ),
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

  testWidgets('handles() claims edit, MIME, and structured panels', (
    tester,
  ) async {
    expect(ToolBar.handles('edit.comment'), isTrue);
    expect(ToolBar.handles('mime.base64.encode'), isTrue);
    expect(ToolBar.handles('structured.yaml'), isTrue);
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

  testWidgets('every action button on every bar is styled identically', (
    tester,
  ) async {
    // Two rounds of "make the buttons consistent" missed this, because the
    // bars were compared by eye one at a time. MIME's Apply kept Material's
    // default FilledButton styling — `primary`, a light lavender — while the
    // edit and structured bars had moved to `secondaryContainer`. Resolving
    // the styles and comparing them is the check that does not depend on
    // noticing.
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final backgrounds = <String, Set<Color?>>{};
    final shapes = <String, Set<OutlinedBorder?>>{};
    for (final id in [
      'edit.blank',
      'edit.case',
      'structured.json',
      'structured.xml',
      'mime.base64.encode',
      'mime.url.decode',
      // The tabbed bar belongs here: its Apply was the last button still on
      // Material's defaults, which made it stadium-shaped next to the 6px
      // corners everywhere else.
      ToolBar.mimeAllId,
    ]) {
      await tester.pumpWidget(host(id));
      await tester.pumpAndSettle();
      final buttons = tester.widgetList<FilledButton>(
        find.byType(FilledButton),
      );
      backgrounds[id] = buttons
          .map((b) => b.style?.backgroundColor?.resolve(<WidgetState>{}))
          .toSet();
      shapes[id] = buttons
          .map((b) => b.style?.shape?.resolve(<WidgetState>{}))
          .toSet();
    }

    for (final entry in backgrounds.entries) {
      expect(
        entry.value,
        isNot(contains(null)),
        reason:
            '${entry.key} has a button on Material default styling; every '
            'action button must come from PanelStyles',
      );
    }
    expect(
      backgrounds.values.expand((s) => s).toSet(),
      hasLength(1),
      reason: 'all bars should agree on one action-button colour',
    );
    expect(
      shapes.values.expand((s) => s).toSet(),
      hasLength(1),
      reason: 'and on one corner radius — Material default is a stadium',
    );
  });

  testWidgets('the MIME title tab follows the Encode/Decode selector', (
    tester,
  ) async {
    // The bug: the panel owned the decode flag, so tapping Decode changed the
    // Apply label while the tab above still read "Base64 Encode".
    await tester.pumpWidget(host('mime.base64.encode'));
    expect(find.text('Base64 Encode'), findsOneWidget);

    await tester.tap(find.text('Decode'));
    await tester.pumpAndSettle();

    expect(find.text('Base64 Decode'), findsOneWidget);
    expect(
      find.text('Base64 Encode'),
      findsNothing,
      reason: 'the tab and the Apply button must name the same operation',
    );
  });

  testWidgets('and a decode choice does not carry to the next tool', (
    tester,
  ) async {
    // The bar is one widget reused across panel ids, so the flag has to be
    // dropped when the docked tool changes or URL Encode would open on Decode.
    await tester.pumpWidget(host('mime.base64.encode'));
    await tester.tap(find.text('Decode'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(host('mime.url.encode'));
    await tester.pumpAndSettle();

    expect(find.text('URL Encode'), findsOneWidget);
  });

  testWidgets('widest edit bar does not overflow across a width sweep', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    // Blank Operations has 8 long labels — the worst case.
    await sweep(tester, 'edit.blank');
  });

  testWidgets('mime bar does not overflow across a width sweep', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await sweep(tester, 'mime.base64.encode');
  });

  testWidgets('structured bar does not overflow across a width sweep', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await sweep(tester, 'structured.json');
  });

  testWidgets('close button stays reachable at 400px', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host('edit.blank'));
    expect(find.byTooltip('Close (Esc)'), findsOneWidget);
  });

  /// The whole point of the docked bars is that they are SHORTER than the
  /// ~190px ribbon panel they replaced. The width sweeps above only prove the
  /// bars do not overflow — a 235px "slim bar" once passed them, and four
  /// reviews, unnoticed. These ceilings are the missing guard.
  ///
  /// The numbers are MEASURED, not designed: each is the exact height the bar
  /// renders at 800px. That is now 180px BELOW the enforced minimum window
  /// width (980px, raised because the ribbon's menu columns need it), which
  /// only makes these stricter: a narrower viewport wraps more and renders
  /// taller, so every ceiling here is a conservative bound on what ships.
  /// Exact, with no slack, so that any
  /// regression in control density or label length fails immediately. If a
  /// deliberate design change moves one, re-measure and update it here with the
  /// new figure — do not just raise the number.
  ///
  /// Caveat worth knowing before reading these as pixels the user sees: the
  /// widget-test font is a fixed-width test font whose glyphs are ~1em wide
  /// (verified: 'Trim Trailing Space' measures 251.75px at fontSize 13, i.e.
  /// 13.25px/char). A real proportional UI font is roughly half that per
  /// character, so the shipped bars wrap less and render SHORTER than these
  /// figures. They are an upper bound, which is what a guard wants.
  ///
  /// The `mimeHasSelection: false` host is used deliberately: the
  /// "⚠️ Transforms the whole document." notice is the longer of the two.
  const heightCeilingsAt800 = <String, double>{
    'edit.case': 100,
    'edit.eol': 50,
    // 8 long labels; this one is still the worst case by a wide margin.
    'edit.blank': 125,
    'edit.comment': 100,
    'mime.base64.encode': 89,
    'mime.base64.decode': 89,
    'mime.qp.encode': 89,
    'mime.qp.decode': 89,
    'mime.url.encode': 121,
    // Decode hides the RFC1738/Extended/Full selector, so this is shorter
    // than url.encode.
    'mime.url.decode': 89,
    'mime.saml.decode': 91,
    // The tabbed bar: a tab row plus the selected category's option run. Its
    // Apply button was the last one on Material's own defaults — stadium
    // shaped, and a wrap run taller once it joined the shared style.
    'mime': 122,
    // Five operation buttons, the scope note, a divider, and the auto-validate
    // switch do not fit on one run at 800px. JSON is the tallest because it
    // also carries the JSON5 dialect switch. These were 86px when the bar held
    // only Pretty-print and Compact.
    //
    // These dropped twice on 2026-08-07. First when DockedBar's close button
    // went from Material's 40px square to 28px, which is what had been setting
    // every one-row bar's height. Then again, much further, when the edit bars'
    // ActionChips became the same FilledButton every other bar uses: chips
    // carry more horizontal padding than they look like they do, so eight of
    // them needed four wrap runs where eight buttons need two. `edit.blank`
    // went 161 to 93px on that change alone, and the one-row floor reached
    // 49px — under the spec's ~52px, which two rounds of chrome-tuning had not
    // managed.
    'structured.json': 129,
    'structured.yaml': 121,
    'structured.xml': 121,
  };

  Widget heightHost(String panelId) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          ToolBar(
            panelId: panelId,
            editToolsEnabled: true,
            mimeToolsEnabled: true,
            mimeHasSelection: false,
            onRunEditOp: (_) {},
            onRunMimeOp: (_) {},
            onRunStructuredOp: (_) {},
            onClose: () {},
          ),
        ],
      ),
    ),
  );

  for (final entry in heightCeilingsAt800.entries) {
    testWidgets('${entry.key} bar stays within ${entry.value}px at 800px', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(heightHost(entry.key));
      await tester.pump();
      final height = tester.getSize(find.byType(DockedBar)).height;
      expect(
        height,
        lessThanOrEqualTo(entry.value),
        reason:
            '${entry.key} grew to ${height}px at 800px; the docked bar '
            'exists to be slimmer than the ~190px ribbon panel it replaced',
      );
    });
  }

  Widget mimeHost({required bool enabled, required bool hasSelection}) =>
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ToolBar(
                panelId: 'mime.base64.encode',
                editToolsEnabled: true,
                mimeToolsEnabled: enabled,
                mimeHasSelection: hasSelection,
                onRunEditOp: (_) {},
                onRunMimeOp: (_) {},
                onRunStructuredOp: (_) {},
                onClose: () {},
              ),
            ],
          ),
        ),
      );

  testWidgets(
    'mime bar explains it transforms the selection when enabled with a selection',
    (tester) async {
      await tester.pumpWidget(mimeHost(enabled: true, hasSelection: true));
      expect(find.text('Transforms the selection.'), findsOneWidget);
    },
  );

  testWidgets(
    'mime bar explains it transforms the document when enabled with no selection',
    (tester) async {
      await tester.pumpWidget(mimeHost(enabled: true, hasSelection: false));
      expect(find.text('⚠️ Transforms the whole document.'), findsOneWidget);
    },
  );

  testWidgets('mime bar explains why it is disabled', (tester) async {
    await tester.pumpWidget(mimeHost(enabled: false, hasSelection: false));
    expect(
      find.text('Open a document in Edit mode to run MIME tools.'),
      findsOneWidget,
    );
  });
}
