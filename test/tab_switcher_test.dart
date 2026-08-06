import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textutilz/editor.dart';
import 'package:textutilz/src/rust/frb_generated.dart';

import 'app_shell.dart';

/// Ctrl+Tab switching and the tab strip's overflow affordances.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  final switcher = find.byKey(const ValueKey('tab-switcher'));

  /// The text of the document currently in the editor — the least indirect
  /// way to ask which tab is active.
  String activeDoc(WidgetTester tester) => tester
      .state<CustomEditorState>(find.byType(CustomEditor))
      .widget
      .session
      .contentString();

  /// Hold Ctrl, press Tab [times], release Ctrl — one whole switcher gesture.
  Future<void> ctrlTab(
    WidgetTester tester, {
    int times = 1,
    bool shift = false,
    bool release = true,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pumpAndSettle();
    if (release) {
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }
  }

  Future<void> releaseCtrl(WidgetTester tester) async {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  const docs = {'a.txt': 'alpha', 'b.txt': 'bravo', 'c.txt': 'charlie'};

  group('Ctrl+Tab', () {
    testWidgets('switches to the previously used tab', (tester) async {
      await AppShellHarness.pump(tester, documents: docs);
      await tester.pumpAndSettle();
      expect(activeDoc(tester), 'alpha');

      await ctrlTab(tester);

      expect(activeDoc(tester), 'bravo');
    });

    testWidgets('and back again, which is the point of MRU order', (
      tester,
    ) async {
      // In strip order a second Ctrl+Tab would land on c.txt. In MRU order it
      // returns to a.txt, so Ctrl+Tab toggles between two documents the way
      // every other editor does.
      await AppShellHarness.pump(tester, documents: docs);
      await tester.pumpAndSettle();

      await ctrlTab(tester);
      await ctrlTab(tester);

      expect(activeDoc(tester), 'alpha');
    });

    testWidgets('two presses in one hold are one switch, two places down', (
      tester,
    ) async {
      await AppShellHarness.pump(tester, documents: docs);
      await tester.pumpAndSettle();

      await ctrlTab(tester, times: 2);

      expect(activeDoc(tester), 'charlie');
    });

    testWidgets('Ctrl+Shift+Tab walks the other way', (tester) async {
      await AppShellHarness.pump(tester, documents: docs);
      await tester.pumpAndSettle();

      await ctrlTab(tester, shift: true);

      expect(activeDoc(tester), 'charlie');
    });

    testWidgets('the overlay is up only while Ctrl is held', (tester) async {
      await AppShellHarness.pump(tester, documents: docs);
      await tester.pumpAndSettle();
      expect(switcher, findsNothing);

      await ctrlTab(tester, release: false);
      expect(switcher, findsOneWidget);
      expect(find.text('b.txt'), findsWidgets);

      await releaseCtrl(tester);
      expect(switcher, findsNothing);
    });

    testWidgets('Escape abandons the walk and stays put', (tester) async {
      await AppShellHarness.pump(tester, documents: docs);
      await tester.pumpAndSettle();

      await ctrlTab(tester, times: 2, release: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await releaseCtrl(tester);

      expect(switcher, findsNothing);
      expect(activeDoc(tester), 'alpha');
    });

    testWidgets('a single tab has nothing to switch to', (tester) async {
      await AppShellHarness.pump(tester, documents: {'only.txt': 'one'});
      await tester.pumpAndSettle();

      await ctrlTab(tester, release: false);

      expect(switcher, findsNothing);
      await releaseCtrl(tester);
    });
  });

  group('the tab strip', () {
    /// Enough tabs, with long enough names, to overflow 1000px.
    Map<String, String> manyDocs() => {
      for (var i = 0; i < 24; i++)
        'a_rather_long_document_name_$i.txt': 'body $i',
    };

    testWidgets('shows no chevrons when every tab fits', (tester) async {
      await AppShellHarness.pump(tester, documents: docs);
      await tester.pumpAndSettle();

      expect(find.byTooltip('Scroll tabs left'), findsNothing);
      expect(find.byTooltip('Scroll tabs right'), findsNothing);
    });

    testWidgets('and grows chevrons when they do not', (tester) async {
      await AppShellHarness.pump(tester, documents: manyDocs());
      await tester.pumpAndSettle();

      expect(find.byTooltip('Scroll tabs left'), findsOneWidget);
      expect(find.byTooltip('Scroll tabs right'), findsOneWidget);
    });

    testWidgets('the chevron scrolls the strip', (tester) async {
      await AppShellHarness.pump(tester, documents: manyDocs());
      await tester.pumpAndSettle();
      final strip = tester.widget<ListView>(
        find.descendant(
          of: find.byType(NotificationListener<ScrollMetricsNotification>),
          matching: find.byType(ListView),
        ),
      );
      final before = strip.controller!.offset;

      await tester.tap(find.byTooltip('Scroll tabs right'));
      await tester.pumpAndSettle();

      expect(strip.controller!.offset, greaterThan(before));
    });

    testWidgets('switching tabs scrolls the new one into view', (tester) async {
      // The sharper half of the overflow problem: with the strip scrolled
      // away, a tab activated by keyboard used to stay off-screen.
      await AppShellHarness.pump(tester, documents: manyDocs());
      await tester.pumpAndSettle();
      final strip = tester.widget<ListView>(
        find.descendant(
          of: find.byType(NotificationListener<ScrollMetricsNotification>),
          matching: find.byType(ListView),
        ),
      );
      expect(strip.controller!.offset, 0, reason: 'starts at the first tab');

      // Walk to a tab far down the strip.
      await ctrlTab(tester, times: 20);

      expect(
        strip.controller!.offset,
        greaterThan(0),
        reason: 'the strip should have followed the active tab',
      );
    });
  });
}
