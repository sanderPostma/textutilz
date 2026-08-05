import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/docked_bar.dart';
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

  /// The whole point of the docked bars is that they are SHORTER than the
  /// ~190px ribbon panel they replaced. The width sweeps above only prove the
  /// bars do not overflow — a 235px "slim bar" once passed them, and four
  /// reviews, unnoticed. These ceilings are the missing guard.
  ///
  /// The numbers are MEASURED, not designed: each is the exact height the bar
  /// renders at 800px (the app's enforced minimum window width AND its default
  /// width) after the tap-target/density fix. Exact, with no slack, so that any
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
    'edit.case': 129,
    'edit.eol': 71,
    // 8 long labels; this one is still the worst case by a wide margin.
    'edit.blank': 163,
    'edit.comment': 129,
    'mime.base64.encode': 86,
    'mime.base64.decode': 86,
    'mime.qp.encode': 86,
    'mime.qp.decode': 86,
    'mime.url.encode': 118,
    'mime.url.decode': 118,
    'mime.saml.decode': 88,
  };

  Widget heightHost(String panelId) => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ToolBar(
              panelId: panelId,
              editToolsEnabled: true,
              mimeToolsEnabled: true,
              mimeHasSelection: false,
              onRunEditOp: (_) {},
              onRunMimeOp: (_) {},
              onClose: () {},
            ),
          ]),
        ),
      );

  for (final entry in heightCeilingsAt800.entries) {
    testWidgets('${entry.key} bar stays within ${entry.value}px at 800px',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(heightHost(entry.key));
      await tester.pump();
      final height = tester.getSize(find.byType(DockedBar)).height;
      expect(height, lessThanOrEqualTo(entry.value),
          reason: '${entry.key} grew to ${height}px at 800px; the docked bar '
              'exists to be slimmer than the ~190px ribbon panel it replaced');
    });
  }

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
